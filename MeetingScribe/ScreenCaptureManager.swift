import Foundation
import ScreenCaptureKit
import AVFoundation
import os

private let logger = Logger(subsystem: "com.saraiba.meetingscribe", category: "screencapture")

/// Captures one app's audio via ScreenCaptureKit.
final class ScreenCaptureManager: NSObject, ObservableObject {
    static let meetingApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.google.Chrome",
        "com.apple.Safari", "com.apple.FaceTime", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "company.thebrowser.Browser", "org.mozilla.firefox", "com.cisco.webexmeetingsapp", "com.microsoft.edgemac",
    ]

    @Published var availableApps: [SCRunningApplication] = []
    @Published var selectedApp: SCRunningApplication?

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var stream: SCStream?
    private let output = AudioStreamOutput()

    func refreshApps() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        let ownID = Bundle.main.bundleIdentifier
        let apps = content.applications
            .filter { !$0.bundleIdentifier.isEmpty && $0.bundleIdentifier != ownID && !$0.applicationName.isEmpty }
            .sorted {
                let (a, b) = (Self.meetingApps.contains($0.bundleIdentifier), Self.meetingApps.contains($1.bundleIdentifier))
                return a != b ? a : $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending
            }
        await MainActor.run {
            availableApps = apps
            // Keep the previous choice if the app is still running, else preselect the first meeting app.
            selectedApp = apps.first { $0.bundleIdentifier == selectedApp?.bundleIdentifier }
                ?? apps.first { Self.meetingApps.contains($0.bundleIdentifier) }
        }
    }

    func startCapture(app: SCRunningApplication) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first,
              let target = content.applications.first(where: { $0.processID == app.processID }) else {
            throw RecorderError("\(app.applicationName) ya no está abierta.")
        }
        // App-level filter: audio keeps flowing even if the meeting window is minimised or on another Space.
        let filter = SCContentFilter(display: display, including: [target], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        config.width = 2; config.height = 2  // we only want audio
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        output.onAudioBuffer = { [weak self] in self?.onAudioBuffer?($0) }
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.meetingscribe.appaudio"))
        try await stream.startCapture()
        self.stream = stream
        logger.info("Capturing audio from \(app.applicationName, privacy: .public)")
    }

    func stopCapture() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }
}

private final class AudioStreamOutput: NSObject, SCStreamOutput {
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buffer = sampleBuffer.toPCMBuffer() else { return }
        onAudioBuffer?(buffer)
    }
}
