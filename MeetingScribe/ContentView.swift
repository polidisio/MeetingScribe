import SwiftUI
import AVFoundation
import Speech
import ScreenCaptureKit

struct ContentView: View {
    @ObservedObject var recorder: MeetingRecorder
    @StateObject private var screenCapture = ScreenCaptureManager()
    var statusItem: NSStatusItem

    @State private var captureMode: CaptureMode = .microphone
    @State private var showingAlert = false
    @State private var alertMessage = ""

    enum CaptureMode: String, CaseIterable {
        case microphone = "Micrófono"
        case app = "App de Reunión"
    }

    var body: some View {
        VStack(spacing: 12) {
            headerView
            Divider()
            captureModePicker
            inputSection
            Divider()
            statusView
            transcriptionView
            recordButton
            actionButtons
            errorView
            Spacer(minLength: 0)
        }
        .padding()
        .frame(width: 350, height: 450)
        .alert(alertMessage, isPresented: $showingAlert) {
            Button("OK", role: .cancel) { }
        }
        .onAppear {
            recorder.refreshAvailableDevices()
        }
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "waveform")
                .foregroundColor(.blue)
            Text("MeetingScribe")
                .font(.headline)
            Spacer()
        }
    }

    private var captureModePicker: some View {
        Picker("Modo", selection: $captureMode) {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(recorder.isRecording)
    }

    @ViewBuilder
    private var inputSection: some View {
        if captureMode == .app {
            appPickerSection
        } else {
            devicePickerSection
        }
    }

    private var appPickerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("App de Reunión")
                .font(.caption)
                .foregroundColor(.secondary)
            if screenCapture.availableApps.isEmpty {
                Button("Buscar apps") {
                    Task {
                        await screenCapture.refreshApps()
                    }
                }
                .disabled(recorder.isRecording)
            } else {
                appPicker
            }
        }
    }

    private var appPicker: some View {
        let binding = appSelectionBinding
        return Picker("", selection: binding) {
            Text("Seleccionar app").tag("")
            ForEach(screenCapture.availableApps, id: \.bundleIdentifier) { app in
                Text(app.applicationName).tag(app.bundleIdentifier ?? "")
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .disabled(recorder.isRecording)
    }

    private var appSelectionBinding: Binding<String> {
        Binding(
            get: { screenCapture.selectedApp?.bundleIdentifier ?? "" },
            set: { newValue in
                if newValue.isEmpty {
                    screenCapture.selectedApp = nil
                } else {
                    screenCapture.selectedApp = screenCapture.availableApps.first { $0.bundleIdentifier == newValue }
                }
            }
        )
    }

    private var devicePickerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Dispositivo de audio")
                .font(.caption)
                .foregroundColor(.secondary)
            devicePicker
        }
    }

    private var devicePicker: some View {
        let binding = deviceBinding
        return Picker("", selection: binding) {
            Text("Auto-detectar").tag("")
            ForEach(recorder.availableDevices, id: \.uniqueID) { d in
                Text(d.localizedName).tag(d.uniqueID)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .disabled(recorder.isRecording)
    }

    private var deviceBinding: Binding<String> {
        Binding(
            get: { recorder.selectedDeviceID ?? "" },
            set: { newValue in
                recorder.selectedDeviceID = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private var statusView: some View {
        HStack {
            Circle()
                .fill(recorder.isRecording ? Color.red : Color.gray)
                .frame(width: 10, height: 10)
            Text(recorder.isRecording ? "Recording" : "Ready")
                .font(.subheadline)
                .fontWeight(.medium)
            Spacer()
            if recorder.transcription.count > 0 {
                Text("\(recorder.transcription.count) chars")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var transcriptionView: some View {
        ScrollView {
            if recorder.transcription.isEmpty {
                Text("Transcription will appear here...")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
            } else {
                Text(recorder.transcription)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: 150)
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    private var recordButton: some View {
        Button(action: recordButtonAction) {
            HStack {
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.title2)
                Text(recorder.isRecording ? "Stop Recording" : "Start Recording")
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(recorder.isRecording ? .red : .blue)
    }

    private func recordButtonAction() {
        if recorder.isRecording {
            if captureMode == .app {
                Task {
                    await recorder.stopScreenCapture(manager: screenCapture)
                    updateStatusIcon()
                }
            } else {
                recorder.stopRecording()
                updateStatusIcon()
            }
        } else {
            requestPermissionsAndStart()
            updateStatusIcon()
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if !recorder.isRecording && !recorder.transcription.isEmpty {
            HStack(spacing: 8) {
                Button(action: copyToClipboard) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: saveToFile) {
                    Label("Save", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: sendToAria) {
                    Label("Aria", systemImage: "paperplane")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Button(action: { recorder.reset() }) {
                Text("New Recording")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var errorView: some View {
        if let error = recorder.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
                .padding(8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
        }
    }

    private func requestPermissionsAndStart() {
        if captureMode == .app {
            Task {
                // Request speech recognition permission first
                let speechStatus = SFSpeechRecognizer.authorizationStatus()
                if speechStatus != .authorized {
                    SFSpeechRecognizer.requestAuthorization { status in
                        DispatchQueue.main.async {
                            if status == .authorized {
                                self.startAppCapture()
                            } else {
                                alertMessage = "Speech recognition permission denied"
                                showingAlert = true
                            }
                        }
                    }
                } else {
                    self.startAppCapture()
                }
            }
        } else {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        SFSpeechRecognizer.requestAuthorization { status in
                            DispatchQueue.main.async {
                                if status == .authorized {
                                    self.recorder.startRecording()
                                } else {
                                    alertMessage = "Speech recognition permission denied"
                                    self.showingAlert = true
                                }
                            }
                        }
                    } else {
                        alertMessage = "Microphone permission denied"
                        self.showingAlert = true
                    }
                }
            }
        }
    }

    private func startAppCapture() {
        Task {
            if #available(macOS 12.3, *) {
                if !CGPreflightScreenCaptureAccess() {
                    let granted = CGRequestScreenCaptureAccess()
                    if !granted {
                        await MainActor.run {
                            alertMessage = "Screen Recording permission denied. Enable it in System Settings > Privacy & Security > Screen Recording."
                            showingAlert = true
                        }
                        return
                    }
                }
                do {
                    try await recorder.startScreenCapture(with: screenCapture)
                } catch {
                    await MainActor.run {
                        alertMessage = "Screen capture failed: \(error.localizedDescription)"
                        showingAlert = true
                    }
                }
            } else {
                await MainActor.run {
                    alertMessage = "Screen capture requires macOS 12.3 or later"
                    showingAlert = true
                }
            }
        }
    }

    private func updateStatusIcon() {
        statusItem.button?.image = NSImage(
            systemSymbolName: recorder.isRecording ? "stop.fill" : "mic.fill",
            accessibilityDescription: recorder.isRecording ? "Stop Recording" : "Start Recording"
        )
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(recorder.transcription, forType: .string)
        alertMessage = "Copied to clipboard!"
        showingAlert = true
    }

    private func saveToFile() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "transcription_\(dateString()).txt"

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    try self.recorder.transcription.write(to: url, atomically: true, encoding: .utf8)
                    self.alertMessage = "Saved to \(url.lastPathComponent)"
                    self.showingAlert = true
                } catch {
                    self.alertMessage = "Failed to save: \(error.localizedDescription)"
                    self.showingAlert = true
                }
            }
        }
    }

    private func sendToAria() {
        copyToClipboard()
        alertMessage = "Copied! Paste in Telegram to send to Aria."
        showingAlert = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.recorder.reset()
        }
    }

    private func dateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: Date())
    }
}
