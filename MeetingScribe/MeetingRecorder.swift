import Foundation
import AVFoundation
import Speech
import CoreAudio

class MeetingRecorder: NSObject, ObservableObject {
    // Two independent engines — one per audio side
    private var remoteEngine: AVAudioEngine?
    private var localEngine: AVAudioEngine?

    // Two recognizers to allow parallel tasks
    private var remoteSpeechRecognizer: SFSpeechRecognizer?
    private var localSpeechRecognizer: SFSpeechRecognizer?

    // Two recognition streams
    private var remoteRequest: SFSpeechAudioBufferRecognitionRequest?
    private var localRequest: SFSpeechAudioBufferRecognitionRequest?
    private var remoteTask: SFSpeechRecognitionTask?
    private var localTask: SFSpeechRecognitionTask?

    // Session rotation timers (SFSpeechRecognizer has ~60s hard limit)
    private var remoteRotationTimer: Timer?
    private var localRotationTimer: Timer?

    // Accumulated text across rotation sessions
    private var remoteAccumulated = ""
    private var localAccumulated = ""

    @Published var isRecording = false
    @Published var mergedTranscription = ""
    @Published var errorMessage: String?
    @Published var availableDevices: [AVCaptureDevice] = []
    @Published var remoteDeviceID: String? = nil  // BlackHole / Teams audio
    @Published var localDeviceID: String? = nil   // Microphone / your voice

    // Keep transcription as alias for ContentView compatibility
    var transcription: String { mergedTranscription }

    private var logFile: URL?

    override init() {
        super.init()
        setupSpeechRecognizers()
        setupLogFile()
        refreshAvailableDevices()
    }

    private func setupSpeechRecognizers() {
        let locale = Locale(identifier: "es-ES")
        remoteSpeechRecognizer = SFSpeechRecognizer(locale: locale)
        localSpeechRecognizer = SFSpeechRecognizer(locale: locale)
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
        mergedTranscription = ""
        remoteAccumulated = ""
        localAccumulated = ""
        errorMessage = nil
        log("Start recording requested")

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            errorMessage = "Speech recognition not authorized"
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            errorMessage = "Microphone not authorized"
            return
        }

        do {
            try startRemoteStream()
            try startLocalStream()
            DispatchQueue.main.async { self.isRecording = true }
        } catch {
            log("ERROR starting: \(error.localizedDescription)")
            errorMessage = "Failed to start: \(error.localizedDescription)"
            stopRecording()
        }
    }

    private func startRemoteStream() throws {
        let engine = AVAudioEngine()
        remoteEngine = engine

        // Prefer: user selection → Aggregate containing BlackHole → BlackHole direct
        // Reading from the Aggregate avoids clock conflicts when BlackHole is owned by it
        let deviceID = remoteDeviceID
            ?? findDeviceID(containing: "Capture")   // "MeetingScribe Capture" aggregate
            ?? findDeviceID(containing: "Meeting")   // legacy "Meeting" aggregate
            ?? findDeviceID(containing: "BlackHole") // BlackHole direct fallback
        if let id = deviceID {
            setEngineInputDevice(id, engine: engine)
        }

        // Create request BEFORE installing tap
        let request = makeRequest()
        remoteRequest = request

        let format = engine.inputNode.outputFormat(forBus: 0)
        log("Remote tap format: \(format), device: \(deviceID ?? "default")")
        var remoteLevelCounter = 0
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            self?.remoteRequest?.append(buf)
            remoteLevelCounter += 1
            if remoteLevelCounter % 50 == 0, let ch = buf.floatChannelData?[0] {
                let rms = (0..<Int(buf.frameLength)).map { ch[$0] * ch[$0] }.reduce(0, +) / Float(buf.frameLength)
                self?.log("Remote audio RMS: \(String(format: "%.6f", rms)) (\(buf.frameLength) frames)")
            }
        }

        startRemoteTask()
        engine.prepare()
        try engine.start()
        scheduleRotation(remote: true)
        log("Remote stream started (device: \(deviceID ?? "default"))")
    }

    private func startLocalStream() throws {
        let engine = AVAudioEngine()
        localEngine = engine

        if let id = localDeviceID {
            setEngineInputDevice(id, engine: engine)
        }

        // Create request BEFORE installing tap
        let request = makeRequest()
        localRequest = request

        let format = engine.inputNode.outputFormat(forBus: 0)
        log("Local tap format: \(format)")
        var localLevelCounter = 0
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            self?.localRequest?.append(buf)
            localLevelCounter += 1
            if localLevelCounter % 50 == 0, let ch = buf.floatChannelData?[0] {
                let rms = (0..<Int(buf.frameLength)).map { ch[$0] * ch[$0] }.reduce(0, +) / Float(buf.frameLength)
                self?.log("Local audio RMS: \(String(format: "%.6f", rms)) (\(buf.frameLength) frames)")
            }
        }

        startLocalTask()
        engine.prepare()
        try engine.start()
        scheduleRotation(remote: false)
        log("Local stream started (device: \(localDeviceID ?? "default"))")
    }

    func stopRecording() {
        log("Stop recording called")

        remoteRotationTimer?.invalidate(); remoteRotationTimer = nil
        localRotationTimer?.invalidate(); localRotationTimer = nil

        remoteEngine?.inputNode.removeTap(onBus: 0)
        remoteEngine?.stop()
        localEngine?.inputNode.removeTap(onBus: 0)
        localEngine?.stop()

        remoteRequest?.endAudio()
        localRequest?.endAudio()
        remoteTask?.cancel()
        localTask?.cancel()

        remoteRequest = nil; localRequest = nil
        remoteTask = nil; localTask = nil
        remoteEngine = nil; localEngine = nil

        log("Recording stopped")
        DispatchQueue.main.async { self.isRecording = false }
    }

    func reset() {
        mergedTranscription = ""
        remoteAccumulated = ""
        localAccumulated = ""
        errorMessage = nil
        log("Reset called")
    }

    // MARK: - Recognition tasks

    private func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = false
        return req
    }

    private func startRemoteTask() {
        guard let recognizer = remoteSpeechRecognizer, let request = remoteRequest else { return }
        remoteTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                if result.isFinal {
                    self.remoteAccumulated += result.bestTranscription.formattedString + " "
                    self.log("Remote (final): \(result.bestTranscription.formattedString)")
                    self.rebuildTranscription(remotePartial: "")
                } else {
                    self.rebuildTranscription(remotePartial: result.bestTranscription.formattedString)
                }
            }
            if let error = error as NSError?, error.code != 301 {
                self.log("Remote recognition error: \(error.localizedDescription) (\(error.code))")
            }
        }
    }

    private func startLocalTask() {
        guard let recognizer = localSpeechRecognizer, let request = localRequest else { return }
        localTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                if result.isFinal {
                    self.localAccumulated += result.bestTranscription.formattedString + " "
                    self.log("Local (final): \(result.bestTranscription.formattedString)")
                    self.rebuildTranscription(localPartial: "")
                } else {
                    self.rebuildTranscription(localPartial: result.bestTranscription.formattedString)
                }
            }
            if let error = error as NSError?, error.code != 301 {
                self.log("Local recognition error: \(error.localizedDescription) (\(error.code))")
            }
        }
    }

    private var lastRemotePartial = ""
    private var lastLocalPartial = ""

    private func rebuildTranscription(remotePartial: String? = nil, localPartial: String? = nil) {
        if let r = remotePartial { lastRemotePartial = r }
        if let l = localPartial { lastLocalPartial = l }

        let remoteText = (remoteAccumulated + lastRemotePartial).trimmingCharacters(in: .whitespaces)
        let localText = (localAccumulated + lastLocalPartial).trimmingCharacters(in: .whitespaces)

        var parts: [String] = []
        if !remoteText.isEmpty { parts.append("Remoto: \(remoteText)") }
        if !localText.isEmpty { parts.append("Tú: \(localText)") }

        DispatchQueue.main.async {
            self.mergedTranscription = parts.joined(separator: "\n\n")
        }
    }

    // MARK: - Session rotation (before the ~60s SFSpeechRecognizer hard limit)

    private func scheduleRotation(remote: Bool) {
        let timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            self?.rotateSession(remote: remote)
        }
        if remote { remoteRotationTimer = timer } else { localRotationTimer = timer }
    }

    private func rotateSession(remote: Bool) {
        log("Rotating \(remote ? "remote" : "local") recognition session")
        let newRequest = makeRequest()

        if remote {
            let old = (remoteRequest, remoteTask)
            remoteRequest = newRequest
            startRemoteTask()
            old.0?.endAudio()
            old.1?.cancel()
        } else {
            let old = (localRequest, localTask)
            localRequest = newRequest
            startLocalTask()
            old.0?.endAudio()
            old.1?.cancel()
        }
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
            log("Could not resolve device UID \(uniqueID)")
            return
        }

        var devID = deviceID
        let result = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
        if result == noErr {
            log("Engine input set to AudioDeviceID \(deviceID)")
        } else {
            log("Failed to set device, status: \(result)")
        }
    }
}
