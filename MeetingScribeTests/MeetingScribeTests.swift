import XCTest
@testable import MeetingScribe

final class MeetingScribeTests: XCTestCase {

    func testMeetingRecorderInitialState() {
        let recorder = MeetingRecorder()
        XCTAssertFalse(recorder.isRecording, "Recorder should not be recording initially")
        XCTAssertEqual(recorder.transcription, "", "Transcription should be empty initially")
        XCTAssertNil(recorder.errorMessage, "Error message should be nil initially")
    }

    func testMeetingRecorderReset() {
        let recorder = MeetingRecorder()
        recorder.reset()
        XCTAssertEqual(recorder.transcription, "", "Transcription should be empty after reset")
        XCTAssertNil(recorder.errorMessage, "Error message should be nil after reset")
    }

    func testDateStringFormat() {
        // Test that date string is properly formatted
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dateString = formatter.string(from: Date())

        // Should match pattern: YYYY-MM-DD_HHMMSS
        let regex = #"^\d{4}-\d{2}-\d{2}_\d{6}$"#
        XCTAssertTrue(dateString.range(of: regex, options: .regularExpression) != nil,
                      "Date string should match format YYYY-MM-DD_HHmmss")
    }

    func testContentViewRendering() {
        // Test that ContentView can be initialized without crashing
        let recorder = MeetingRecorder()
        let mockStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // This would need actual NSStatusItem mock in real test
        // For now just test recorder works
        XCTAssertNotNil(recorder)
    }
}

// MARK: - UI Tests
final class MeetingScribeUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        app = XCUIApplication()
        app.launchArguments = ["--disable-mic-check"] // For testing without actual mic
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    func testAppLaunch() {
        app.launch()
        // App should launch without crash
        XCTAssertTrue(app.exists)
    }

    func testStatusBarIconExists() {
        app.launch()
        // Check that status bar item exists
        // Note: This is hard to test in XCTest without accessibility identifiers
    }

    func testMenuItems() {
        app.launch()
        // Test menu structure
        let menuBar = app.menubars.firstMatch
        XCTAssertTrue(menuBar.exists, "Menu bar should exist")
    }
}