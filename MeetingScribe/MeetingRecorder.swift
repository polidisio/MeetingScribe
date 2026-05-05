import Foundation
import AVFoundation
import Speech

class MeetingRecorder: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    @Published var isRecording = false
    @Published var transcription = ""
    @Published var errorMessage: String?

    private var fullTranscription = ""

    override init() {
        super.init()
        setupSpeechRecognizer()
    }

    private func setupSpeechRecognizer() {
        // Use system locale for Spanish
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    }

    static func requestPermissions(completion: @escaping (Bool, Bool) -> Void) {
        var micGranted = false
        var speechGranted = false

        // Check microphone permission on macOS
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micGranted = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                micGranted = granted
            }
        default:
            micGranted = false
        }

        // Check speech recognition permission
        SFSpeechRecognizer.requestAuthorization { status in
            speechGranted = (status == .authorized)

            DispatchQueue.main.async {
                completion(micGranted, speechGranted)
            }
        }
    }

    func checkPermissions(completion: @escaping (Bool, Bool) -> Void) {
        var micGranted = false
        var speechGranted = false

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micGranted = true
        default:
            micGranted = false
        }

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        speechGranted = (speechStatus == .authorized)

        completion(micGranted, speechGranted)
    }

    func startRecording() {
        // Reset state
        transcription = ""
        fullTranscription = ""
        errorMessage = nil

        // Check speech recognition authorization
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            errorMessage = "Speech recognition not authorized"
            return
        }

        // Check microphone permission
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            errorMessage = "Microphone not authorized"
            return
        }

        do {
            try startAudioEngine()
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            isRecording = false
        }
    }

    private func startAudioEngine() throws {
        audioEngine = AVAudioEngine()

        guard let audioEngine = audioEngine else {
            throw NSError(domain: "MeetingRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audio engine not available"])
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw NSError(domain: "MeetingRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to create recognition request"])
        }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true // Use on-device recognition for privacy

        // Start recognition task
        if let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable {
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self = self else { return }

                var isFinal = false

                if let result = result {
                    self.transcription = result.bestTranscription.formattedString
                    isFinal = result.isFinal
                }

                if error != nil || isFinal {
                    // If error or final, stop recording
                    self.stopRecording()
                }
            }
        }

        // Install tap on input node
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()

        DispatchQueue.main.async {
            self.isRecording = true
        }
    }

    func stopRecording() {
        recognitionRequest?.endAudio()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        DispatchQueue.main.async {
            self.isRecording = false
            // Final transcription is already in self.transcription
        }
    }

    func reset() {
        transcription = ""
        fullTranscription = ""
        errorMessage = nil
    }
}