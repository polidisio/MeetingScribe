import Foundation
import AVFoundation
import Speech

class MeetingRecorder: NSObject, ObservableObject {
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
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
            deviceTypes: [.builtInMicrophone, .external],
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
        log("Creating AVCaptureSession...")

        captureSession = AVCaptureSession()

        guard let captureSession = captureSession else {
            throw NSError(domain: "MeetingRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create capture session"])
        }

        let device: AVCaptureDevice
        if let id = selectedDeviceID, let found = AVCaptureDevice(uniqueID: id) {
            device = found
            log("Using selected device: \(found.localizedName) (\(id))")
        } else {
            let discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInMicrophone, .external],
                mediaType: .audio,
                position: .unspecified
            )
            let preferred = discoverySession.devices.first(where: { $0.localizedName.contains("BlackHole") })
                ?? discoverySession.devices.first(where: { $0.localizedName == "Meeting" })
                ?? AVCaptureDevice.default(for: .audio)
            guard let resolved = preferred else {
                throw NSError(domain: "MeetingRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio device found"])
            }
            device = resolved
            log("Auto-selected device: \(device.localizedName)")
            DispatchQueue.main.async { self.selectedDeviceID = device.uniqueID }
        }

        let audioDevice = device

        // Add audio input
        let inputError: NSError?
        do {
            try captureSession.addInput(AVCaptureDeviceInput(device: audioDevice))
        } catch let error as NSError {
            if error.code == -5803 {
                // Device already has input, try to remove and re-add
                captureSession.inputs.forEach { input in
                    captureSession.removeInput(input)
                }
                try captureSession.addInput(AVCaptureDeviceInput(device: audioDevice))
            } else {
                throw error
            }
        }

        // Create audio output
        audioOutput = AVCaptureAudioDataOutput()
        guard let audioOutput = audioOutput else {
            throw NSError(domain: "MeetingRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create audio output"])
        }

        // Set delegate to receive audio buffers
        audioOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "audioQueue"))

        if captureSession.canAddOutput(audioOutput) {
            captureSession.addOutput(audioOutput)
        } else {
            throw NSError(domain: "MeetingRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add audio output"])
        }

        // Configure audio format for speech recognition (mono 16kHz)
        let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

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

        log("Starting capture session...")
        captureSession.startRunning()

        DispatchQueue.main.async {
            self.isRecording = true
            self.log("Recording started successfully")
        }
    }

    private func processAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Convert to PCM buffer for speech recognition
        guard let pcmBuffer = createPCMBuffer(from: sampleBuffer) else {
            return
        }

        recognitionRequest?.append(pcmBuffer)
    }

    private func createPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) as CMAudioFormatDescription?,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let sampleRate = asbd.pointee.mSampleRate
        let channelCount = asbd.pointee.mChannelsPerFrame
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)

        // Target format: mono 16kHz
        let targetSampleRate: Double = 16000

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false) else {
            return nil
        }

        // Calculate output frame count
        let ratio = targetSampleRate / sampleRate
        let outputFrames = Int(Double(frames) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(outputFrames)) else {
            return nil
        }

        // Get audio data from sample buffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer else {
            return nil
        }

        // Copy data (simple approach - for multi-channel, would need mixing)
        let floatCount = length / MemoryLayout<Float>.size
        let floatPointer = UnsafeMutablePointer<Float>.allocate(capacity: floatCount)
        memcpy(floatPointer, data, length)

        // If mono, copy directly. If multi-channel, mix to mono
        if channelCount == 1 {
            for i in 0..<min(frames, outputFrames) {
                outputBuffer.floatChannelData?[0][i] = floatPointer[i]
            }
        } else {
            // Mix channels
            for i in 0..<min(frames, outputFrames) {
                var sum: Float = 0
                for ch in 0..<Int(channelCount) {
                    sum += floatPointer[i * Int(channelCount) + ch]
                }
                outputBuffer.floatChannelData?[0][i] = sum / Float(channelCount)
            }
        }

        floatPointer.deallocate()
        outputBuffer.frameLength = AVAudioFrameCount(outputFrames)

        return outputBuffer
    }

    func stopRecording() {
        log("Stop recording called")

        captureSession?.stopRunning()
        captureSession = nil

        recognitionRequest?.endAudio()

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioOutput = nil

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

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate
extension MeetingRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        processAudioBuffer(sampleBuffer)
    }
}