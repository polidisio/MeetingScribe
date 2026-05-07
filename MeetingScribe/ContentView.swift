import SwiftUI
import AVFoundation
import Speech

struct ContentView: View {
    @ObservedObject var recorder: MeetingRecorder
    var statusItem: NSStatusItem

    @State private var showingAlert = false
    @State private var alertMessage = ""

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "waveform")
                    .foregroundColor(.blue)
                Text("MeetingScribe")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Audio Source Picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio Source")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("", selection: Binding(
                    get: { recorder.selectedDeviceID ?? "" },
                    set: { recorder.selectedDeviceID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Auto-detect").tag("")
                    ForEach(recorder.availableDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(recorder.isRecording)
            }

            Divider()

            // Status
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

            // Transcription area
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

            // Record button
            Button(action: {
                if recorder.isRecording {
                    recorder.stopRecording()
                } else {
                    requestPermissionsAndStart()
                }
                updateStatusIcon()
            }) {
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

            // Action buttons (only when not recording and has transcription)
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

                Button(action: {
                    recorder.reset()
                }) {
                    Text("New Recording")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            // Error display
            if let error = recorder.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
            }

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

    private func requestPermissionsAndStart() {
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

    private func updateStatusIcon() {
        DispatchQueue.main.async {
            statusItem.button?.image = NSImage(
                systemSymbolName: recorder.isRecording ? "stop.fill" : "mic.fill",
                accessibilityDescription: recorder.isRecording ? "Stop Recording" : "Start Recording"
            )
        }
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