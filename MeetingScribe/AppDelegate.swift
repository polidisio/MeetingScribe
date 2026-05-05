import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var recorder: MeetingRecorder!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        recorder = MeetingRecorder()

        // Setup status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "MeetingScribe")
            button.action = #selector(toggleRecording)
            button.target = self
        }

        // Build popover content
        let contentView = ContentView(recorder: recorder, statusItem: statusItem)
        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 200)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)

        setupMenu()
    }

    @objc func toggleRecording() {
        if recorder.isRecording {
            recorder.stopRecording()
        } else {
            recorder.startRecording()
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: recorder.isRecording ? "stop.fill" : "mic.fill",
            accessibilityDescription: recorder.isRecording ? "Stop Recording" : "Start Recording"
        )
    }

    @objc func showPopover() {
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func setupMenu() {
        let menu = NSMenu()

        let recordItem = NSMenuItem(title: recorder.isRecording ? "Stop Recording" : "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        menu.addItem(recordItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About MeetingScribe", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}