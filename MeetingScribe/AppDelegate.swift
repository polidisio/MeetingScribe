import AppKit
import SwiftUI
import AVFoundation
import Speech

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var recorder: MeetingRecorder!
    private var popover: NSPopover!
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        recorder = MeetingRecorder()

        // Setup status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "MeetingScribe")
            button.action = #selector(showPopoverAndMenu)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Build popover content
        let contentView = ContentView(recorder: recorder, statusItem: statusItem)
        popover = NSPopover()
        popover.contentSize = NSSize(width: 350, height: 450)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)

        // Monitor for clicks outside to close popover
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if self?.popover.isShown == true {
                self?.popover.performClose(nil)
            }
        }
    }

    @objc func showPopoverAndMenu(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!

        if event.type == .rightMouseUp {
            // Right click - show menu
            showMenu()
        } else {
            // Left click - toggle popover
            if popover.isShown {
                popover.performClose(nil)
            } else {
                showPopover()
            }
        }
    }

    @objc func showPopover() {
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func showMenu() {
        let menu = NSMenu()

        let recordTitle = recorder.isRecording ? "Stop Recording" : "Start Recording"
        let recordItem = NSMenuItem(title: recordTitle, action: #selector(toggleRecording), keyEquivalent: "r")
        recordItem.target = self
        menu.addItem(recordItem)

        menu.addItem(NSMenuItem.separator())

        let openUIItem = NSMenuItem(title: "Open UI", action: #selector(showPopover), keyEquivalent: "")
        openUIItem.target = self
        menu.addItem(openUIItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About MeetingScribe", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func toggleRecording() {
        if recorder.isRecording {
            recorder.stopRecording()
            statusItem.button?.image = NSImage(
                systemSymbolName: "mic.fill",
                accessibilityDescription: "Start Recording"
            )
        } else {
            requestPermissionsAndStartRecording()
        }
    }

    private func requestPermissionsAndStartRecording() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if granted {
                    SFSpeechRecognizer.requestAuthorization { status in
                        DispatchQueue.main.async {
                            if status == .authorized {
                                self.recorder.startRecording()
                                self.statusItem.button?.image = NSImage(
                                    systemSymbolName: "stop.fill",
                                    accessibilityDescription: "Stop Recording"
                                )
                            } else {
                                self.showAlert(title: "Permission Denied", message: "Speech recognition permission denied")
                            }
                        }
                    }
                } else {
                    self.showAlert(title: "Permission Denied", message: "Microphone permission denied")
                }
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}