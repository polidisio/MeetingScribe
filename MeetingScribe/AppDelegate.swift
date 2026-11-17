import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = MeetingRecorder()
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var recordingObserver: AnyCancellable?
    private var clock: Timer?
    private var hotKey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        // Fixed size: if the hosting controller drives the size, the popover resizes after it is shown
        // and AppKit places it partly above the screen.
        let host = NSHostingController(rootView: ContentView(recorder: recorder))
        host.sizingOptions = []
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 400, height: 560)

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.popover.isShown == true { self?.popover.performClose(nil) }
            }
        }

        // Single source of truth: the icon follows the recorder, whoever started/stopped it.
        recordingObserver = recorder.$isRecording.receive(on: RunLoop.main).sink { [weak self] recording in
            self?.recordingChanged(recording)
        }
        registerHotKey()
    }

    // MARK: - Status item

    private func recordingChanged(_ recording: Bool) {
        clock?.invalidate(); clock = nil
        if recording {
            clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatusItem() }
            }
        }
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        if recorder.isRecording, let start = recorder.startDate {
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Grabando")
            button.contentTintColor = .systemRed
            button.title = " " + Transcript.duration(Date().timeIntervalSince(start))
        } else {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MeetingScribe")
            button.contentTintColor = nil
            button.title = ""
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    @objc private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showMenu() {
        let menu = NSMenu()
        let record = NSMenuItem(title: recorder.isRecording ? "Detener grabación" : "Empezar a grabar",
                                action: #selector(toggleRecording), keyEquivalent: "r")
        record.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(record)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Abrir MeetingScribe", action: #selector(showPopover), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Carpeta de transcripciones", action: #selector(openTranscriptsFolder), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Acerca de MeetingScribe", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.filter { $0.action != #selector(NSApplication.terminate(_:)) }.forEach { $0.target = self }

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleRecording() {
        Task { await recorder.toggle() }
    }

    @objc private func openTranscriptsFolder() {
        NSWorkspace.shared.open(TranscriptStore.directory)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: - Global shortcut ⌥⌘R (Carbon hot key: works without Accessibility permission)

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { delegate.toggleRecording() } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | optionKey),
                            EventHotKeyID(signature: OSType(0x4D534352), id: 1),  // 'MSCR'
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
