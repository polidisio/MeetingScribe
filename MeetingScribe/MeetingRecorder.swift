import Foundation
import AVFoundation
import Speech
import CoreAudio
import ScreenCaptureKit

class MeetingRecorder: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var mixerNode: AVAudioMixerNode?
    private var speechRecognizer: SFSpeechRecognizer?
    private var micSpeechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var rotationTimer: Timer?
    private var accumulatedText = ""

    // Separate recognizer and session for mic audio
    private var micRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var micRecognitionTask: SFSpeechRecognitionTask?
    private var micCaptureSession: AVCaptureSession?
    private var micAudioInput: AVCaptureInput?

    @Published var isRecording = false
    @Published var transcription = ""
    @Published var errorMessage: String?
    @Published var availableDevices: [AVCaptureDevice] = []
    @Published var selectedDeviceID: String? = nil

    // Keep dual-picker API for UI compatibility — merged into one stream
    var remoteDeviceID: String? {
        get { selectedDeviceID }
        set { selectedDeviceID = newValue }
    }
    var localDeviceID: String? = nil  // reserved for future use

    var mergedTranscription: String { formatSpeakerOutput() }

    private var logFile: URL?

    // Speaker diarization
    private var speakerTranscripts: [Int: String] = [:]
    private var allSegments: [SFTranscriptionSegment] = []

    override init() {
        super.init()
        setupSpeechRecognizer()
        setupLogFile()
        refreshAvailableDevices()
    }

    private func setupSpeechRecognizer() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
        micSpeechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    }

    private func setupLogFile() {
        let desktopPath = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        logFile = desktopPath.appendingPathComponent("MeetingScribe_log.txt")
        log("=== MeetingScribe started ===")
    }

    func refreshAvailableDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        DispatchQueue.main.async {
            self.availableDevices = session.devices
            self.log("Refreshed available devices: \(session.devices.map { $0.localizedName })")
        }
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"
        if let logFile = logFile {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                if let data = logLine.data(using: .utf8) { handle.write(data) }
                handle.closeFile()
            } else {
                try? logLine.write(to: logFile, atomically: true, encoding: .utf8)
            }
        }
        print(logLine, terminator: "")
    }

    // MARK: - Start / Stop

    func startRecording() {
        transcription = ""
        accumulatedText = ""
        errorMessage = nil
        log("Start recording requested")

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            errorMessage = "Speech recognition not authorized"; return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            errorMessage = "Microphone not authorized"; return
        }

        do {
            try startCapture()
            DispatchQueue.main.async { self.isRecording = true }
        } catch {
            log("ERROR starting: \(error.localizedDescription)")
            errorMessage = "Failed to start: \(error.localizedDescription)"
            stopRecording()
        }
    }

    private func startCapture() throws {
        let engine = AVAudioEngine()
        audioEngine = engine

        // Device priority: user selection → Aggregate containing all sources → BlackHole → default
        // ONE engine reads from ONE device — CoreAudio does not support two simultaneous engines well
        let deviceID = selectedDeviceID
            ?? findDeviceID(containing: "Capture")   // "MeetingScribe Capture" aggregate
            ?? findDeviceID(containing: "Meeting")   // legacy "Meeting" aggregate
            ?? findDeviceID(containing: "BlackHole") // BlackHole standalone fallback
        if let id = deviceID {
            setEngineInputDevice(id, engine: engine)
        }

        // Create recognition request BEFORE installing tap
        let request = makeRequest()
        recognitionRequest = request

        let hwFormat = engine.inputNode.inputFormat(forBus: 0)
        let outFormat = engine.inputNode.outputFormat(forBus: 0)
        log("HW format: \(hwFormat.channelCount) ch, \(hwFormat.sampleRate) Hz | Tap format: \(outFormat.channelCount) ch, \(outFormat.sampleRate) Hz | device: \(deviceID ?? "default")")

        // Guard against invalid format (0 channels = device not properly open)
        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            log("ERROR: Invalid audio format (channels=\(hwFormat.channelCount), sampleRate=\(hwFormat.sampleRate))")
            throw NSError(domain: "MeetingRecorder", code: 10, userInfo: [NSLocalizedDescriptionKey: "Audio device not available. Try selecting a different device in settings."])
        }

        // Use a mixer node to properly downmix ALL Aggregate channels (AirPods + BlackHole)
        // to mono. A direct tap on inputNode with outputFormat may silently drop non-first channels.
        let mixer = AVAudioMixerNode()
        mixerNode = mixer
        engine.attach(mixer)
        engine.connect(engine.inputNode, to: mixer, format: hwFormat)

        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        var bufferCount = 0
        mixer.installTap(onBus: 0, bufferSize: 4096, format: monoFormat) { [weak self] buf, _ in
            self?.recognitionRequest?.append(buf)
            bufferCount += 1
            // Log per-channel RMS every ~4s via hwFormat buffer (mixer input has all channels)
            if bufferCount % 25 == 0, let ch = buf.floatChannelData?[0] {
                let rms = (0..<Int(buf.frameLength)).map { ch[$0] * ch[$0] }.reduce(0, +) / Float(buf.frameLength)
                self?.log("Mono RMS: \(String(format: "%.6f", rms)) (\(deviceID ?? "default"))")
            }
        }

        startRecognitionTask()
        engine.prepare()
        try engine.start()
        scheduleRotation()
        log("Capture started on device: \(deviceID ?? "default")")
    }

    func stopRecording() {
        log("Stop recording called")
        rotationTimer?.invalidate(); rotationTimer = nil
        mixerNode?.removeTap(onBus: 0)
        mixerNode = nil
        audioEngine?.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
        log("Recording stopped, transcription length: \(transcription.count)")
        DispatchQueue.main.async { self.isRecording = false }
    }

    func reset() {
        transcription = ""
        accumulatedText = ""
        speakerTranscripts = [:]
        allSegments = []
        errorMessage = nil
        log("Reset called")
    }

    // MARK: - Speaker Output Formatting

    private func formatSpeakerOutput() -> String {
        guard !speakerTranscripts.isEmpty else { return transcription }
        var lines: [String] = []
        for speaker in speakerTranscripts.keys.sorted() {
            let text = speakerTranscripts[speaker]?.trimmingCharacters(in: .whitespaces) ?? ""
            if !text.isEmpty {
                lines.append("Person \(speaker): \(text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Recognition

    private func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = false
        return req
    }

    private func startRecognitionTask() {
        guard let recognizer = speechRecognizer, let request = recognitionRequest else { return }
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let partial = result.bestTranscription.formattedString
                if result.isFinal {
                    self.accumulatedText += partial + " "
                    self.log("Final segment: \(partial)")
                    self.processSegments(result.bestTranscription.segments)
                    DispatchQueue.main.async { self.transcription = self.formatSpeakerOutput() }
                } else {
                    DispatchQueue.main.async { self.transcription = self.formatSpeakerOutput() + "\n[Partial: \(partial)]" }
                }
            }
            if let error = error as NSError?, error.code != 301 {
                self.log("Recognition error: \(error.localizedDescription) (\(error.code))")
            }
        }
    }

    private func processSegments(_ segments: [SFTranscriptionSegment], source: String = "screen") {
        // Screen capture audio = Person 2 (remote participants)
        // Microphone audio = Person 1 (local speaker)
        let baseSpeaker = (source == "mic") ? 1 : 2
        var currentSpeaker = baseSpeaker
        var lastTimestamp: TimeInterval = 0
        let pauseThreshold: TimeInterval = 2.0

        for segment in segments {
            if !allSegments.contains(where: { $0.timestamp == segment.timestamp && $0.substring == segment.substring && $0.timestamp > lastTimestamp - 0.1 }) {
                allSegments.append(segment)

                let pause = segment.timestamp - lastTimestamp
                if pause > pauseThreshold && lastTimestamp > 0 {
                    currentSpeaker += 2  // Skip to next pair to separate screen vs mic
                    if currentSpeaker > 4 { currentSpeaker = baseSpeaker }
                }
                lastTimestamp = segment.timestamp

                let existing = speakerTranscripts[currentSpeaker] ?? ""
                speakerTranscripts[currentSpeaker] = existing + segment.substring + " "
            }
        }
        log("Diarization [\(source)]: \(speakerTranscripts.count) speaker(s), \(allSegments.count) total segments")
    }

    // MARK: - Session rotation (before the ~60s SFSpeechRecognizer hard limit)

    private func scheduleRotation() {
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            self?.rotateSession()
        }
    }

    private func rotateSession() {
        log("Rotating session | Speakers: \(speakerTranscripts.keys.sorted()) | Segments: \(allSegments.count)")
        let newRequest = makeRequest()
        let oldRequest = recognitionRequest
        let oldTask = recognitionTask
        recognitionRequest = newRequest
        startRecognitionTask()
        oldRequest?.endAudio()
        oldTask?.cancel()
    }

    // MARK: - ScreenCaptureKit integration

    @available(macOS 12.3, *)
    func startScreenCapture(with manager: ScreenCaptureManager) async throws {
        guard let app = manager.selectedApp else {
            throw NSError(domain: "MeetingRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No app selected"])
        }

        transcription = ""
        accumulatedText = ""
        speakerTranscripts = [:]
        allSegments = []
        errorMessage = nil
        log("Start screen capture requested for: \(app.applicationName)")

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw NSError(domain: "MeetingRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognition not authorized"])
        }

        // Create requests for BOTH audio sources
        let screenRequest = makeRequest()
        let micRequest = makeRequest()
        recognitionRequest = screenRequest
        micRecognitionRequest = micRequest

        // Setup screen capture audio
        var screenBufferCount = 0
        manager.onAudioBuffer = { [weak self] buffer in
            screenBufferCount += 1
            if screenBufferCount % 25 == 0 {
                self?.log("SCREAM: appending buffer #\(screenBufferCount), \(buffer.frameLength) frames, \(buffer.format.channelCount) ch")
            }
            self?.recognitionRequest?.append(buffer)
        }

        try await manager.startCapture(app: app)
        startRecognitionTask()
        scheduleRotation()

        // Start mic capture after a delay to let ScreenCaptureKit stabilize audio resources
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            do {
                try self.startMicCaptureSession(request: micRequest)
                self.log("Mic capture started after delay")
            } catch {
                self.log("Mic capture failed after delay: \(error)")
            }
        }

        await MainActor.run {
            self.isRecording = true
        }
        log("Screen + Mic capture started for: \(app.applicationName)")
    }

    private func startMicCaptureSession(request: SFSpeechAudioBufferRecognitionRequest) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw NSError(domain: "MeetingRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Microphone not authorized"])
        }

        let session = AVCaptureSession()
        micCaptureSession = session

        guard let mic = AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "MeetingRecorder", code: 4, userInfo: [NSLocalizedDescriptionKey: "No microphone found"])
        }

        log("Using microphone: \(mic.localizedName)")

        let input = try AVCaptureDeviceInput(device: mic)
        micAudioInput = input

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureAudioDataOutput()
        let outputQueue = DispatchQueue(label: "com.meetingscribe.micaudio")

        output.setSampleBufferDelegate(MicAudioDelegate(request: request, recorder: self), queue: outputQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.startRunning()

        // Start recognition task for mic audio with SEPARATE recognizer
        if let recognizer = micSpeechRecognizer {
            micRecognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self else { return }
                if let result = result {
                    if result.isFinal {
                        self.processSegments(result.bestTranscription.segments, source: "mic")
                        DispatchQueue.main.async { self.transcription = self.formatSpeakerOutput() }
                    }
                }
                if let error = error as NSError?, error.code != 301 {
                    self.log("Mic recognition error: \(error.localizedDescription) (\(error.code))")
                }
            }
            log("Mic recognition task started with separate recognizer")
        }

        session.startRunning()
        log("Mic AVCaptureSession started")
    }

    @available(macOS 12.3, *)
    func stopScreenCapture(manager: ScreenCaptureManager) async {
        log("Stop screen capture called")
        rotationTimer?.invalidate(); rotationTimer = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        micRecognitionRequest?.endAudio()
        micRecognitionTask?.cancel()
        micRecognitionRequest = nil
        micRecognitionTask = nil
        mixerNode?.removeTap(onBus: 0)
        mixerNode = nil
        audioEngine?.stop()
        audioEngine = nil
        micCaptureSession?.stopRunning()
        micCaptureSession = nil
        micAudioInput = nil
        await manager.stopCapture()
        await MainActor.run {
            self.isRecording = false
        }
        log("Screen capture stopped, transcription length: \(transcription.count)")
    }

    // MARK: - CoreAudio device selection

    private func findDeviceID(containing name: String) -> String? {
        availableDevices.first(where: { $0.localizedName.contains(name) })?.uniqueID
    }

    private func setEngineInputDevice(_ uniqueID: String, engine: AVAudioEngine) {
        guard let audioUnit = engine.inputNode.audioUnit else { return }

        var deviceID = kAudioObjectUnknown
        let uidPtr = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        uidPtr.pointee = uniqueID as CFString
        defer { uidPtr.deallocate() }

        var translation = AudioValueTranslation(
            mInputData: UnsafeMutableRawPointer(uidPtr),
            mInputDataSize: UInt32(MemoryLayout<CFString>.size),
            mOutputData: &deviceID,
            mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &translation)

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            log("Could not resolve UID \(uniqueID), using default")
            return
        }

        var devID = deviceID
        let result = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
        log(result == noErr
            ? "Engine input set to AudioDeviceID \(deviceID)"
            : "Failed to set device, status: \(result)")
    }
}

// MARK: - Mic Audio Delegate

private class MicAudioDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let request: SFSpeechAudioBufferRecognitionRequest
    weak var recorder: MeetingRecorder?

    init(request: SFSpeechAudioBufferRecognitionRequest, recorder: MeetingRecorder) {
        self.request = request
        self.recorder = recorder
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let audioBuffer = sampleBuffer.toAVAudioPCMBuffer() else { return }
        request.append(audioBuffer)
    }
}

// MARK: - CMSampleBuffer extension

extension CMSampleBuffer {
    func toAVAudioPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard frameCount > 0 else { return nil }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(streamDescription: asbd)!,
                                               frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(self) else { return nil }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer else { return nil }

        if let channelData = pcmBuffer.floatChannelData {
            let bytesPerFrame = Int(asbd.pointee.mBytesPerFrame)
            for channel in 0..<Int(asbd.pointee.mChannelsPerFrame) {
                let channelPtr = channelData[channel]
                for frame in 0..<frameCount {
                    let offset = frame * bytesPerFrame + channel * MemoryLayout<Float>.size
                    if offset + MemoryLayout<Float>.size <= length {
                        channelPtr[frame] = data.advanced(by: offset).withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee }
                    }
                }
            }
        }

        return pcmBuffer
    }
}
