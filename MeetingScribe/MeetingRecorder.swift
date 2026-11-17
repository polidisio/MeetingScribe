import Foundation
import AVFoundation
import Speech
import CoreAudio
import ScreenCaptureKit
import Accelerate
import os

private let logger = Logger(subsystem: "com.saraiba.meetingscribe", category: "recorder")

enum CaptureMode: String, CaseIterable, Identifiable {
    case microphone, app
    var id: String { rawValue }
    var title: String { self == .microphone ? "Micrófono" : "App de reunión" }
}

@MainActor
final class MeetingRecorder: NSObject, ObservableObject {
    static let languages: [(id: String, name: String)] = [
        ("es-ES", "Español (España)"),
        ("es-MX", "Español (México)"),
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
    ]

    @Published private(set) var isRecording = false
    @Published private(set) var entries: [TranscriptEntry] = []
    @Published private(set) var partial: TranscriptEntry?
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var startDate: Date?
    @Published private(set) var endDate: Date?
    @Published private(set) var lastSavedURL: URL?
    @Published var errorMessage: String?
    @Published var errorSettingsURL: URL?
    @Published var availableDevices: [AVCaptureDevice] = []
    @Published var selectedDeviceID: String?
    @Published var captureMode: CaptureMode {
        didSet { UserDefaults.standard.set(captureMode.rawValue, forKey: "captureMode") }
    }
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }

    let screenCapture = ScreenCaptureManager()

    // ONE recognition task per process: on-device SFSpeechRecognizer kills the older task when a second starts (1110).
    private var stream: RecognitionStream?
    private var mixer: SourceMixer?
    private var audioEngine: AVAudioEngine?
    private var micSession: AVCaptureSession?
    private var micDelegate: SampleBufferForwarder?
    private var ticker: Timer?
    private var sessionSource = ""

    /// Plain-text transcript (copy / Aria).
    var transcription: String { transcript.plainText }

    var transcript: Transcript {
        Transcript(entries: entries, start: startDate ?? Date(), end: endDate ?? Date(),
                   sourceName: sessionSource, language: language)
    }

    var languageName: String {
        Self.languages.first { $0.id == language }?.name ?? language
    }

    override init() {
        let defaults = UserDefaults.standard
        captureMode = CaptureMode(rawValue: defaults.string(forKey: "captureMode") ?? "") ?? .app
        language = defaults.string(forKey: "language") ?? "es-ES"
        super.init()
        refreshAvailableDevices()
    }

    func refreshAvailableDevices() {
        availableDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }

    // MARK: - Start / Stop

    func toggle() async {
        if isRecording { await stop() } else { await start() }
    }

    func start() async {
        guard !isRecording else { return }
        errorMessage = nil
        errorSettingsURL = nil

        guard await Self.speechAuthorized() else {
            return fail("Permiso de reconocimiento de voz denegado.", pane: "Privacy_SpeechRecognition")
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            return fail("Permiso de micrófono denegado.", pane: "Privacy_Microphone")
        }
        guard let probe = SFSpeechRecognizer(locale: Locale(identifier: language)), probe.isAvailable else {
            return fail("El reconocimiento de voz para \(languageName) no está disponible ahora mismo.")
        }
        // Privacy promise: audio never leaves the Mac. No on-device model → refuse rather than fall back to Apple's servers.
        guard probe.supportsOnDeviceRecognition else {
            return fail("Falta el modelo local de \(languageName). Descárgalo en Ajustes del Sistema › Teclado › Dictado.",
                        settingsURL: URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"))
        }

        reset()
        startDate = Date()
        do {
            switch captureMode {
            case .microphone: try startMicrophoneMode()
            case .app: try await startAppMode()
            }
            isRecording = true
            ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            logger.info("Recording started (\(self.captureMode.rawValue, privacy: .public))")
        } catch {
            logger.error("Start failed: \(error.localizedDescription, privacy: .public)")
            await tearDownAudio()
            stream = nil
            mixer = nil
            startDate = nil
            if errorMessage == nil { fail(error.localizedDescription) }
        }
    }

    func stop() async {
        guard isRecording else { return }
        ticker?.invalidate(); ticker = nil
        await tearDownAudio()
        stream?.stop()
        stream = nil
        mixer = nil
        // Whatever was still in flight becomes a regular entry — nothing is dropped on stop.
        partial.map(insert)
        partial = nil
        audioLevel = 0
        endDate = Date()
        isRecording = false
        if !entries.isEmpty {
            do { lastSavedURL = try TranscriptStore.save(transcript) }
            catch { fail("No se pudo guardar automáticamente: \(error.localizedDescription)") }
        }
        logger.info("Recording stopped, \(self.entries.count) entries")
    }

    func reset() {
        entries = []
        partial = nil
        startDate = nil
        endDate = nil
        lastSavedURL = nil
        errorMessage = nil
        errorSettingsURL = nil
    }

    private func fail(_ message: String, pane: String? = nil, settingsURL: URL? = nil) {
        errorMessage = message
        errorSettingsURL = settingsURL
            ?? pane.flatMap { URL(string: "x-apple.systempreferences:com.apple.preference.security?\($0)") }
    }

    private static func speechAuthorized() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    // MARK: - Streams

    private func makeStream(source: @escaping () -> TranscriptEntry.Source,
                            onOpen: @escaping () -> Void = {}) throws -> RecognitionStream {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            throw RecorderError("No se pudo crear el reconocedor de voz.")
        }
        let stream = RecognitionStream(recognizer: recognizer, source: source, onOpen: onOpen)
        stream.onPartial = { [weak self] entry in
            MainActor.assumeIsolated { self?.partial = entry }
        }
        stream.onFinal = { [weak self] entry in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.partial?.id == entry.id { self.partial = nil }
                self.insert(entry)
            }
        }
        self.stream = stream
        stream.start()
        return stream
    }

    private func insert(_ entry: TranscriptEntry) {
        guard !entry.text.isEmpty, !entries.contains(where: { $0.id == entry.id }) else { return }
        let index = entries.lastIndex { $0.date <= entry.date }.map { $0 + 1 } ?? 0
        entries.insert(entry, at: index)
    }

    private func tick() {
        stream?.segmentIfPaused()
    }

    private nonisolated func reportLevel(_ buffer: AVAudioPCMBuffer) {
        let level = Self.level(of: buffer)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                self.audioLevel = max(level, self.audioLevel * 0.85)  // fast attack, slow decay
            }
        }
    }

    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        let n = vDSP_Length(buffer.frameLength)
        guard n > 0 else { return 0 }
        var meanSquare: Float = 0
        if let f = buffer.floatChannelData {
            vDSP_measqv(f[0], 1, &meanSquare, n)
        } else if let i = buffer.int16ChannelData {
            var floats = [Float](repeating: 0, count: Int(n))
            vDSP_vflt16(i[0], 1, &floats, 1, n)
            vDSP_measqv(floats, 1, &meanSquare, n)
            meanSquare /= Float(Int16.max) * Float(Int16.max)
        }
        let db = 10 * log10(meanSquare + 1e-10)
        // ponytail: maps -55…-5 dBFS to 0…1; tune if the meter sits too low/high on your mic
        return max(0, min(1, (db + 55) / 50))
    }

    // MARK: - Microphone mode (one AVAudioEngine, one device)

    private func startMicrophoneMode() throws {
        let stream = try makeStream(source: { .room })
        let engine = AVAudioEngine()
        audioEngine = engine

        // Priority: user selection → "MeetingScribe Capture" aggregate → legacy "Meeting" aggregate → BlackHole → default
        let deviceUID = selectedDeviceID
            ?? findDeviceUID(containing: "Capture")
            ?? findDeviceUID(containing: "Meeting")
            ?? findDeviceUID(containing: "BlackHole")
        if let uid = deviceUID { setInputDevice(uid, engine: engine) }
        sessionSource = availableDevices.first { $0.uniqueID == deviceUID }?.localizedName
            ?? AVCaptureDevice.default(for: .audio)?.localizedName ?? "Micrófono"

        let hwFormat = engine.inputNode.inputFormat(forBus: 0)
        logger.info("HW format: \(hwFormat.channelCount) ch, \(hwFormat.sampleRate) Hz")
        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            throw RecorderError("El dispositivo de audio no está disponible. Prueba con otro.")
        }

        // Mixer downmixes ALL aggregate channels (mic + BlackHole) to mono; a direct tap can drop non-first channels.
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        engine.connect(engine.inputNode, to: mixer, format: hwFormat)
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hwFormat.sampleRate,
                                 channels: 1, interleaved: false)!
        mixer.installTap(onBus: 0, bufferSize: 4096, format: mono) { [weak self] buf, _ in
            stream.append(buf)
            self?.reportLevel(buf)
        }
        engine.prepare()
        try engine.start()
    }

    // MARK: - App mode (ScreenCaptureKit app audio = Remoto, microphone = Tú)

    private func startAppMode() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            fail("Concede «Grabación de pantalla y audio del sistema» a MeetingScribe y vuelve a abrir la app.",
                 pane: "Privacy_ScreenCapture")
            throw RecorderError("Permiso de grabación de pantalla denegado.")
        }
        let app = screenCapture.selectedApp  // nil = all system audio
        sessionSource = "\(app?.applicationName ?? "Audio del sistema") + micrófono"

        // Meeting audio is the clock; the mic is mixed into it so a single recognition task hears both.
        let mixer = SourceMixer()
        self.mixer = mixer
        let stream = try makeStream(source: { mixer.dominantSource() }, onOpen: { mixer.resetEnergy() })
        var buffers = 0
        screenCapture.onAudioBuffer = { [weak self] buffer in
            buffers += 1
            if buffers == 1 || buffers % 500 == 0 {
                logger.info("App audio buffers: \(buffers), level \(Self.level(of: buffer))")
            }
            guard let mixed = mixer.mix(remote: buffer) else { return }
            stream.append(mixed)
            self?.reportLevel(mixed)
        }
        try await screenCapture.startCapture(app: app)

        do { try startMicSession(into: mixer) }
        catch { logger.error("Mic unavailable, meeting audio only: \(error.localizedDescription, privacy: .public)") }
    }

    // AVCaptureSession (not a second AVAudioEngine): two engines conflict in CoreAudio.
    private func startMicSession(into mixer: SourceMixer) throws {
        let device = selectedDeviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw RecorderError("No se encontró ningún micrófono.") }
        logger.info("Mic: \(device.localizedName, privacy: .public)")

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureAudioDataOutput()
        let forwarder = SampleBufferForwarder { mixer.pushMic($0) }
        output.setSampleBufferDelegate(forwarder, queue: DispatchQueue(label: "com.meetingscribe.mic"))
        if session.canAddOutput(output) { session.addOutput(output) }
        micDelegate = forwarder
        micSession = session
        session.startRunning()
    }

    private func tearDownAudio() async {
        audioEngine?.stop()
        audioEngine = nil
        micSession?.stopRunning()
        micSession = nil
        micDelegate = nil
        screenCapture.onAudioBuffer = nil
        await screenCapture.stopCapture()
    }

    // MARK: - CoreAudio device selection

    private func findDeviceUID(containing name: String) -> String? {
        availableDevices.first { $0.localizedName.contains(name) }?.uniqueID
    }

    private func setInputDevice(_ uid: String, engine: AVAudioEngine) {
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &deviceID)
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            logger.error("Could not resolve device UID, using default")
            return
        }
        let result = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                          0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        if result != noErr { logger.error("Failed to set input device: \(result)") }
    }
}

struct RecorderError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - One recognition stream per audio source

/// Wraps SFSpeechRecognizer request/task pairs for a single audio source.
/// Each utterance gets its own request; a new one opens when the speaker pauses, after 50 s,
/// or when the recognizer gives up. The previous request is ended (not cancelled) so its final text still arrives.
/// Recognition callbacks arrive on the main queue (SFSpeechRecognizer.queue default); `append` is called from audio threads.
private final class RecognitionStream {
    var onPartial: (TranscriptEntry) -> Void = { _ in }
    var onFinal: (TranscriptEntry) -> Void = { _ in }

    private let recognizer: SFSpeechRecognizer
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var running = false
    private var currentText = ""
    private var openedAt = Date()
    private var lastChange = Date()
    private var appended = 0      // buffers in current request (guarded by lock)
    private var loggedFormat = false

    // ponytail: pause/length thresholds are guesses; tune if entries split mid-sentence or run too long
    private let pauseToSegment: TimeInterval = 1.6
    private let maxUtterance: TimeInterval = 50

    private let source: () -> TranscriptEntry.Source   // resolved per result (app mode: who was louder)
    private let onOpen: () -> Void

    init(recognizer: SFSpeechRecognizer, source: @escaping () -> TranscriptEntry.Source, onOpen: @escaping () -> Void) {
        self.recognizer = recognizer
        self.source = source
        self.onOpen = onOpen
    }

    func start() {
        running = true
        openRequest()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let r = request
        appended += 1
        let logFormat = !loggedFormat
        loggedFormat = true
        lock.unlock()
        if logFormat { logger.info("[\("stream", privacy: .public)] first buffer: \(buffer.format.description, privacy: .public), \(buffer.frameLength) frames") }
        r?.append(buffer)
    }

    func segmentIfPaused() {
        guard running else { return }
        let now = Date()
        if (!currentText.isEmpty && now.timeIntervalSince(lastChange) > pauseToSegment)
            || now.timeIntervalSince(openedAt) > maxUtterance {
            openRequest()
        }
    }

    func stop() {
        running = false
        generation += 1  // ignore late callbacks; caller commits the last partial itself
        lock.lock(); let r = request; request = nil; lock.unlock()
        r?.endAudio()
        task?.cancel()
        task = nil
    }

    private func openRequest() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.addsPunctuation = true
        lock.lock(); let old = request; request = req; let oldCount = appended; appended = 0; lock.unlock()
        old?.endAudio()  // let the old task deliver its final result
        logger.debug("[\("stream", privacy: .public)] open request gen \(self.generation + 1), previous had \(oldCount) buffers")

        generation += 1
        let gen = generation
        let entryID = UUID()
        var startedAt: Date?
        var lastText = ""
        currentText = ""
        onOpen()
        openedAt = Date()
        lastChange = Date()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            let isCurrent = gen == self.generation
            if let result {
                let text = result.bestTranscription.formattedString
                if startedAt == nil, !text.isEmpty { startedAt = Date() }
                lastText = text
                let entry = TranscriptEntry(id: entryID, source: self.source(), date: startedAt ?? Date(), text: text)
                if result.isFinal {
                    logger.debug("[\("stream", privacy: .public)] final gen \(gen): \(text.count) chars")
                    self.onFinal(entry)
                    if isCurrent && self.running { self.openRequest() }
                } else if isCurrent {
                    if text != self.currentText { self.currentText = text; self.lastChange = Date() }
                    self.onPartial(entry)
                }
            } else if let error = error as NSError? {
                // Task ended without a final (e.g. 1110 "no speech detected"): keep any partial, reopen.
                if !lastText.isEmpty {
                    self.onFinal(TranscriptEntry(id: entryID, source: self.source(), date: startedAt ?? Date(), text: lastText))
                }
                logger.info("[\("stream", privacy: .public)] gen \(gen) ended (current: \(isCurrent)): \(error.domain, privacy: .public) \(error.code) \(error.localizedDescription, privacy: .public)")
                guard isCurrent, self.running else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.running, gen == self.generation else { return }
                    self.openRequest()
                }
            }
        }
    }
}

// MARK: - Audio plumbing

/// Mixes the microphone into the meeting-audio stream (meeting audio drives the clock) and tracks
/// per-utterance energy of each source to label the text "Tú" or "Remoto".
private final class SourceMixer {
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var micFIFO: [Float] = []
    private var micEnergy: Float = 0
    private var remoteEnergy: Float = 0
    private var micConverter: AVAudioConverter?
    private var remoteConverter: AVAudioConverter?

    func pushMic(_ buffer: AVAudioPCMBuffer) {
        guard let mono = convert(buffer, using: &micConverter), let data = mono.floatChannelData?[0] else { return }
        lock.lock(); defer { lock.unlock() }
        micFIFO.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(mono.frameLength)))
        // ponytail: clocks drift; keep at most 0.5 s of mic backlog
        if micFIFO.count > 24000 { micFIFO.removeFirst(micFIFO.count - 24000) }
    }

    func mix(remote: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = convert(remote, using: &remoteConverter), let data = out.floatChannelData?[0] else { return nil }
        let n = Int(out.frameLength)
        lock.lock(); defer { lock.unlock() }
        var r: Float = 0
        vDSP_svesq(data, 1, &r, vDSP_Length(n))
        remoteEnergy += r
        let take = min(n, micFIFO.count)
        if take > 0 {
            micFIFO.withUnsafeBufferPointer { mic in
                var m: Float = 0
                vDSP_svesq(mic.baseAddress!, 1, &m, vDSP_Length(take))
                micEnergy += m
                vDSP_vadd(data, 1, mic.baseAddress!, 1, data, 1, vDSP_Length(take))
            }
            micFIFO.removeFirst(take)
        }
        return out
    }

    func resetEnergy() {
        lock.lock(); micEnergy = 0; remoteEnergy = 0; lock.unlock()
    }

    // ponytail: louder source wins; without headphones the mic also hears the meeting, which can mislabel lines
    func dominantSource() -> TranscriptEntry.Source {
        lock.lock(); defer { lock.unlock() }
        return micEnergy > remoteEnergy ? .me : .remote
    }

    private func convert(_ buffer: AVAudioPCMBuffer, using converter: inout AVAudioConverter?) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        let status = converter.convert(to: out, error: nil) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true; inputStatus.pointee = .haveData; return buffer
        }
        return status == .error ? nil : out
    }
}

private final class SampleBufferForwarder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let handler: (AVAudioPCMBuffer) -> Void
    init(_ handler: @escaping (AVAudioPCMBuffer) -> Void) { self.handler = handler }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        sampleBuffer.toPCMBuffer().map(handler)
    }
}

extension CMSampleBuffer {
    /// Handles interleaved and non-interleaved, float and int formats (ScreenCaptureKit delivers non-interleaved float).
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let desc = formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(self, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
