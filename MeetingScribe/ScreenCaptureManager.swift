import Foundation
import ScreenCaptureKit
import AVFoundation
import Speech

@available(macOS 12.3, *)
class ScreenCaptureManager: NSObject, ObservableObject {
    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?

    @Published var isCapturing = false
    @Published var availableApps: [SCRunningApplication] = []
    @Published var selectedApp: SCRunningApplication?
    @Published var errorMessage: String?

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    override init() {
        super.init()
    }

    func refreshApps() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let apps = content.applications.filter { app in
                let bundleID = app.bundleIdentifier ?? ""
                // Filter to meeting apps and system audio
                let meetingApps = ["com.microsoft.teams", "us.zoom.xos", "com.google.Chrome", "com.apple.Safari", "com.microsoft.teams2"]
                let excluded = ["com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.SystemUIServer"]
                return !excluded.contains(bundleID) && !bundleID.isEmpty
            }
            await MainActor.run {
                self.availableApps = apps
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to get apps: \(error.localizedDescription)"
            }
        }
    }

    func selectApp(byBundleID bundleID: String) {
        selectedApp = availableApps.first { $0.bundleIdentifier == bundleID }
    }

    func startCapture(app: SCRunningApplication) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Find the app's windows
        let appWindows = content.windows.filter { $0.owningApplication?.processID == app.processID }
        print("[ScreenCaptureManager] Found \(appWindows.count) windows for \(app.applicationName) (pid: \(app.processID))")

        guard let window = appWindows.first else {
            throw NSError(domain: "ScreenCaptureManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "No windows found for app"])
        }

        print("[ScreenCaptureManager] Using window: \(window.windowID), title: \(window.title ?? "nil")")

        let filter = SCContentFilter(desktopIndependentWindow: window)
        print("[ScreenCaptureManager] SCContentFilter created")

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 44100
        config.channelCount = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps max (we only need audio)
        config.queueDepth = 5
        print("[ScreenCaptureManager] SCStreamConfiguration: sampleRate=44100, channels=2")

        streamOutput = AudioStreamOutput()
        stream = SCStream(filter: filter, configuration: config, delegate: nil)

        try stream?.addStreamOutput(streamOutput!, type: .audio, sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive))

        streamOutput?.onAudioBuffer = { [weak self] buffer in
            self?.onAudioBuffer?(buffer)
        }

        print("[ScreenCaptureManager] Starting SCStream capture...")
        try await stream?.startCapture()
        print("[ScreenCaptureManager] SCStream capture started successfully")
        await MainActor.run {
            self.selectedApp = app
            self.isCapturing = true
        }
    }

    func stopCapture() async {
        do {
            try await stream?.stopCapture()
        } catch {
            print("Error stopping capture: \(error)")
        }
        stream = nil
        streamOutput = nil
        await MainActor.run {
            self.isCapturing = false
            self.selectedApp = nil
        }
    }
}

@available(macOS 12.3, *)
private class AudioStreamOutput: NSObject, SCStreamOutput {
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    var bufferCount = 0
    var lastLogTime = Date()

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        bufferCount += 1
        let now = Date()
        if now.timeIntervalSince(lastLogTime) > 5.0 {
            print("[ScreenCaptureManager] Audio buffer #\(bufferCount), \(sampleBuffer)")
            lastLogTime = now
        }

        guard let audioBuffer = sampleBuffer.toAVAudioPCMBuffer() else {
            return
        }

        onAudioBuffer?(audioBuffer)
    }
}
