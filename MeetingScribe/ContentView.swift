import SwiftUI
import AVFoundation
import Speech

struct ContentView: View {
    @ObservedObject var recorder: MeetingRecorder
    var statusItem: NSStatusItem

    @State private var showingAlert = false
    @State private var alertMessage = ""

    var body: some View {
        VStack(spacing: 16) {
            // Status indicator
            HStack {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.gray)
                    .frame(width: 12, height: 12)
                Text(recorder.isRecording ? "Recording..." : "Idle")
                    .font(.headline)
                Spacer()
                Text(recorder.transcription.count > 0 ? "\(recorder.transcription.count) chars" : "")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            // Record/Stop button
            Button(action: {
                if recorder.isRecording {
                    recorder.stopRecording()
                } else {
                    requestPermissionsAndStart()
                }
                updateStatusIcon()
            }) {
                HStack {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 40))
                    Text(recorder.isRecording ? "Stop" : "Start Recording")
                        .font(.title3)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(recorder.isRecording ? .red : .blue)

            // Action buttons (when not recording)
            if !recorder.isRecording && !recorder.transcription.isEmpty {
                Divider()

                Button(action: copyToClipboard) {
                    HStack {
                        Image(systemName: "doc.on.doc")
                        Text("Copy Transcription")
                    }
                }
                .buttonStyle(.bordered)

                Button(action: saveToFile) {
                    HStack {
                        Image(systemName: "folder")
                        Text("Save to File")
                    }
                }
                .buttonStyle(.bordered)

                Button(action: sendToAria) {
                    HStack {
                        Image(systemName: "paperplane")
                        Text("Send to Aria")
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()

            // Error message if any
            if let error = recorder.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding()
            }
        }
        .padding()
        .frame(width: 300, height: 220)
        .alert(alertMessage, isPresented: $showingAlert) {
            Button("OK", role: .cancel) { }
        }
    }

    private func requestPermissionsAndStart() {
        // Request microphone permission on macOS
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if granted {
                    // Request speech recognition permission
                    SFSpeechRecognizer.requestAuthorization { status in
                        DispatchQueue.main.async {
                            if status == .authorized {
                                recorder.startRecording()
                            } else {
                                alertMessage = "Speech recognition permission denied"
                                showingAlert = true
                            }
                        }
                    }
                } else {
                    alertMessage = "Microphone permission denied"
                    showingAlert = true
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
    }

    private func saveToFile() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "transcription_\(dateString()).txt"

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    try recorder.transcription.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    alertMessage = "Failed to save: \(error.localizedDescription)"
                    showingAlert = true
                }
            }
        }
    }

    private func sendToAria() {
        // Copy to clipboard for easy paste to Telegram
        copyToClipboard()
        alertMessage = "Transcription copied! Paste it in Telegram to send to Aria."
        showingAlert = true

        // Reset for next recording
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