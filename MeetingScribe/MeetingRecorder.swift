import Foundation
import AVFoundation
import Speech
import CoreAudio

class MeetingRecorder: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var rotationTimer: Timer?
    private var accumulatedText = ""

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

    var mergedTranscription: String { transcription }

    private var logFile: URL?

    override init() {
        super.init()
        setupSpeechRecognizer()
        setupLogFile()
        refreshAvailableDevices()
    }

    private func setupSpeechRecognizer() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
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

        let format = engine.inputNode.outputFormat(forBus: 0)
        log("Audio tap format: \(format), device: \(deviceID ?? "default (system)")")

        var bufferCount = 0
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            self?.recognitionRequest?.append(buf)
            bufferCount += 1
            // Log audio level every ~4s to verify audio is flowing
            if bufferCount % 25 == 0, let ch = buf.floatChannelData?[0] {
                let rms = (0..<Int(buf.frameLength)).map { ch[$0] * ch[$0] }.reduce(0, +) / Float(buf.frameLength)
                self?.log("Audio RMS: \(String(format: "%.6f", rms)) (\(deviceID ?? "default"))")
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
        audioEngine?.inputNode.removeTap(onBus: 0)
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
        errorMessage = nil
        log("Reset called")
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
                    DispatchQueue.main.async { self.transcription = self.accumulatedText.trimmingCharacters(in: .whitespaces) }
                } else {
                    DispatchQueue.main.async { self.transcription = (self.accumulatedText + partial).trimmingCharacters(in: .whitespaces) }
                }
            }
            if let error = error as NSError?, error.code != 301 {
                self.log("Recognition error: \(error.localizedDescription) (\(error.code))")
            }
        }
    }

    // MARK: - Session rotation (before the ~60s SFSpeechRecognizer hard limit)

    private func scheduleRotation() {
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            self?.rotateSession()
        }
    }

    private func rotateSession() {
        log("Rotating recognition session")
        let newRequest = makeRequest()
        let oldRequest = recognitionRequest
        let oldTask = recognitionTask
        recognitionRequest = newRequest
        startRecognitionTask()
        oldRequest?.endAudio()
        oldTask?.cancel()
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
