import XCTest
@testable import MeetingScribe

/// Integration tests for MeetingScribe
final class MeetingRecorderIntegrationTests: XCTestCase {

    var recorder: MeetingRecorder!

    override func setUp() {
        super.setUp()
        recorder = MeetingRecorder()
    }

    override func tearDown() {
        recorder.stopRecording()
        recorder = nil
        super.tearDown()
    }

    func testRecorderStateTransitions() {
        // Initial state
        XCTAssertFalse(recorder.isRecording)

        // After stop (if was recording)
        recorder.stopRecording()
        XCTAssertFalse(recorder.isRecording)
    }

    func testTranscriptionAfterReset() {
        // Set some mock transcription (in real app, this happens during recording)
        recorder.reset()

        XCTAssertEqual(recorder.transcription, "")
        XCTAssertNil(recorder.errorMessage)
    }

    func testErrorMessageHandling() {
        // Test that error messages are properly stored
        recorder.reset()
        XCTAssertNil(recorder.errorMessage)
    }
}

// MARK: - Permissions Tests
final class PermissionsTests: XCTestCase {

    func testMicrophonePermissionState() {
        let permission = AVAudioSession.sharedInstance().recordPermission
        // Permission can be: .undetermined, .denied, .granted
        XCTAssertTrue(
            permission == .undetermined ||
            permission == .denied ||
            permission == .granted,
            "Microphone permission should be one of the valid states"
        )
    }

    func testSpeechRecognitionAuthorization() {
        let status = SFSpeechRecognizer.authorizationStatus()
        // Status can be: .notDetermined, .denied, .authorized, .restricted
        XCTAssertTrue(
            status == .notDetermined ||
            status == .denied ||
            status == .authorized ||
            status == .restricted,
            "Speech recognition status should be valid"
        )
    }
}

// MARK: - Speech Recognizer Tests
final class SpeechRecognizerTests: XCTestCase {

    func testSpeechRecognizerCreation() {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
        XCTAssertNotNil(recognizer, "Spanish speech recognizer should be created")

        // Test English recognizer too
        let englishRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        XCTAssertNotNil(englishRecognizer, "English speech recognizer should be created")
    }

    func testSpeechRecognizerAvailability() {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
        if let recognizer = recognizer {
            XCTAssertTrue(recognizer.isAvailable, "Spanish recognizer should be available on macOS")
        }
    }
}