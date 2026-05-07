import Foundation
import AVFoundation
import Speech
import CoreAudio

class MeetingRecorder: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    @Published var isRecording = false
    @Published var transcription = ""
    @Published var errorMessage: String?
    @Published var availableDevices: [AVCaptureDevice] = []
    @Published var selectedDeviceID: String? = nil

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
                if let data = logLine.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            } else {
                try? logLine.write(to: logFile, atomically: true, encoding: .utf8)
            }
        }
        print(logLine)
    }

    func startRecording() {
        transcription = ""
        errorMessage = nil

        log("Start recording requested")

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            log("ERROR: Speech recognition not authorized")
            errorMessage = "Speech recognition not authorized"
            return
        }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            log("ERROR: Microphone not authorized")
            errorMessage = "Microphone not authorized"
            return
        }

        do {
            try startAudioCapture()
        } catch {
            log("ERROR: Failed to start: \(error.localizedDescription)")
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            isRecording = false
        }
    }

    private func startAudioCapture() throws {
        log("Creating AVAudioEngine...")

        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw NSError(domain: "MeetingRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create audio engine"])
        }

        // Select input device if specified
        if let id = selectedDeviceID {
            do {
                try setEngineInputDevice(id)
            } catch {
                log("Warning: Could not set selected device, using default: \(error.localizedDescription)")
            }
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        log("Setting up audio tap with format: \(recordingFormat)")

        // Install tap - AVAudioEngine automatically converts to requested format
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw NSError(domain: "MeetingRecorder", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to create recognition request"])
        }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            throw NSError(domain: "MeetingRecorder", code: 5, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer not available"])
        }

        log("Starting recognition task...")
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                self.log("Transcription: \(text)")
                self.transcription = text
            }

            if let error = error as NSError? {
                self.log("ERROR: Recognition error: \(error.localizedDescription) | Code: \(error.code)")
                DispatchQueue.main.async {
                    self.errorMessage = "Recognition error: \(error.localizedDescription)"
                }
            }
        }

        log("Starting audio engine...")
        audioEngine.prepare()
        try audioEngine.start()

        DispatchQueue.main.async {
            self.isRecording = true
            self.log("Recording started successfully with AVAudioEngine")
        }
    }

    private func setEngineInputDevice(_ uniqueID: String) throws {
        guard let audioEngine = audioEngine, let audioUnit = audioEngine.inputNode.audioUnit else {
            log("Audio engine or input node not available")
            return
        }

        // Resolve device UID to AudioDeviceID using CoreAudio
        var deviceID = kAudioObjectUnknown
        let uidPointer: UnsafeMutablePointer<CFString?> = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        uidPointer.pointee = uniqueID as CFString
        defer { uidPointer.deallocate() }

        var translation = AudioValueTranslation(
            mInputData: UnsafeMutableRawPointer(uidPointer),
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

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &translation
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            log("Could not resolve device UID \(uniqueID), using default")
            return
        }

        // Set the device on the audio unit
        var deviceIDValue = deviceID
        let result = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDValue,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if result == noErr {
            log("Set input device to AudioDeviceID \(deviceID) (UID: \(uniqueID))")
        } else {
            log("Warning: Failed to set input device, status: \(result)")
        }
    }

    func stopRecording() {
        log("Stop recording called")

        if let audioEngine = audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine = nil

        log("Recording stopped, final transcription: \(transcription)")

        DispatchQueue.main.async {
            self.isRecording = false
        }
    }

    func reset() {
        transcription = ""
        errorMessage = nil
        log("Reset called")
    }
}
