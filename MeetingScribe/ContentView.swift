import SwiftUI
import AVFoundation
import Speech
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject private var screenCapture: ScreenCaptureManager
    @State private var showingHistory = false
    @State private var toast: String?

    init(recorder: MeetingRecorder) {
        self.recorder = recorder
        self.screenCapture = recorder.screenCapture
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showingHistory {
                HistoryView(onClose: { showingHistory = false }, showToast: showToast)
            } else {
                sourceBar
                TranscriptView(recorder: recorder)
                if let error = recorder.errorMessage { errorBanner(error) }
                if !recorder.isRecording && !recorder.entries.isEmpty { actionBar }
                Divider()
                footer
            }
        }
        .frame(width: 400, height: 560)
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: toast)
        .animation(.easeInOut(duration: 0.2), value: showingHistory)
        .onAppear { recorder.refreshAvailableDevices() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            AppBadge(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("MeetingScribe").font(.headline)
                Label("100% en tu Mac · \(recorder.languageName)", systemImage: "lock.fill")
                    .font(.caption2).foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }
            Spacer()
            if recorder.isRecording { RecordingPill(start: recorder.startDate ?? Date()) }
            IconButton(systemName: showingHistory ? "xmark" : "clock.arrow.circlepath",
                       help: showingHistory ? "Cerrar historial" : "Historial") { showingHistory.toggle() }
            settingsMenu
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Idioma", selection: $recorder.language) {
                ForEach(MeetingRecorder.languages, id: \.id) { Text($0.name).tag($0.id) }
            }
            .disabled(recorder.isRecording)
            Divider()
            Button("Carpeta de transcripciones") { NSWorkspace.shared.open(TranscriptStore.directory) }
            Divider()
            Button("Salir de MeetingScribe") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape").font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 26)
        .help("Ajustes")
    }

    // MARK: - Source

    private var sourceBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $recorder.captureMode) {
                ForEach(CaptureMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if recorder.captureMode == .app {
                Picker("", selection: appBinding) {
                    Text("Todo el audio del sistema").tag("")
                    Divider()
                    ForEach(screenCapture.availableApps, id: \.bundleIdentifier) {
                        Text($0.applicationName).tag($0.bundleIdentifier)
                    }
                }
                .labelsHidden()
                IconButton(systemName: "arrow.clockwise", help: "Buscar apps") {
                    Task { await screenCapture.refreshApps() }
                }
            } else {
                Picker("", selection: deviceBinding) {
                    Text("Auto-detectar").tag("")
                    ForEach(recorder.availableDevices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                .labelsHidden()
            }
        }
        .controlSize(.small)
        .disabled(recorder.isRecording)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .task(id: recorder.captureMode) {
            if recorder.captureMode == .app { await screenCapture.refreshApps() }
        }
    }

    private var appBinding: Binding<String> {
        Binding(
            get: { screenCapture.selectedApp?.bundleIdentifier ?? "" },
            set: { id in screenCapture.selectedApp = screenCapture.availableApps.first { $0.bundleIdentifier == id } }
        )
    }

    private var deviceBinding: Binding<String> {
        Binding(get: { recorder.selectedDeviceID ?? "" },
                set: { recorder.selectedDeviceID = $0.isEmpty ? nil : $0 })
    }

    // MARK: - Error / actions

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let url = recorder.errorSettingsURL {
                    Button("Abrir Ajustes del Sistema") { NSWorkspace.shared.open(url) }
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            IconButton(systemName: "xmark", help: "Cerrar") { recorder.errorMessage = nil }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            ActionButton(title: "Copiar", systemName: "doc.on.doc") {
                copy(recorder.transcription); showToast("Copiado")
            }
            ActionButton(title: "Guardar", systemName: "square.and.arrow.down", action: saveToFile)
            if let url = recorder.lastSavedURL {
                ActionButton(title: "Ver", systemName: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            // System share sheet: Mail, Mensajes, Notas, Telegram, apps de IA (ChatGPT, Claude…), AirDrop
            ShareLink(item: recorder.transcript.markdown, subject: Text("Transcripción de reunión")) {
                ActionLabel(title: "Compartir", systemName: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .tint(.purple)
            .help("Compartir con otra app")
            ActionButton(title: "Nueva", systemName: "plus") { recorder.reset() }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            LevelMeter(level: recorder.audioLevel, active: recorder.isRecording)
                .frame(width: 100, height: 26)
            Spacer()
            RecordButton(isRecording: recorder.isRecording) { Task { await recorder.toggle() } }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(recorder.transcript.wordCount) palabras")
                Text(recorder.isRecording ? "⌥⌘R para detener" : "⌥⌘R para grabar").foregroundStyle(.tertiary)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if toast == message { toast = nil }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.nameFieldStringValue = "reunion_\(Transcript.fileStamp.string(from: recorder.startDate ?? Date())).md"
        let transcript = recorder.transcript
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let body = url.pathExtension == "md" ? transcript.markdown : transcript.plainText
            do {
                try body.write(to: url, atomically: true, encoding: .utf8)
                showToast("Guardado")
            } catch {
                recorder.errorMessage = "No se pudo guardar: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Transcript

private struct TranscriptView: View {
    @ObservedObject var recorder: MeetingRecorder

    private var partialIDs: Set<UUID> { Set([recorder.partial?.id].compactMap { $0 }) }
    private var rows: [TranscriptEntry] {
        recorder.entries + [recorder.partial].compactMap { $0 }
    }

    var body: some View {
        let rows = rows
        ScrollViewReader { proxy in
            ScrollView {
                if rows.isEmpty {
                    emptyState.frame(maxWidth: .infinity).padding(.top, 50)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(rows) { EntryRow(entry: $0, isPartial: partialIDs.contains($0.id)) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
            .onChange(of: rows.last?.text) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyState: some View {
        if recorder.isRecording {
            VStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.red.gradient)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text("Escuchando…").font(.title3.weight(.medium))
                Text("El texto aparecerá aquí en cuanto alguien hable.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 12) {
                AppBadge(size: 56)
                Text("Listo para transcribir").font(.title3.weight(.semibold))
                Text(recorder.captureMode == .app
                     ? "Pulsa grabar: se captura el audio de la reunión y tu micrófono por separado.\nUsa auriculares para no duplicar voces."
                     : "Pulsa el botón rojo o usa ⌥⌘R desde cualquier app.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                PermissionsCard(needsScreen: recorder.captureMode == .app).padding(.top, 6)
            }
            .padding(.horizontal, 24)
        }
    }
}

private struct EntryRow: View {
    let entry: TranscriptEntry
    let isPartial: Bool

    private var isMe: Bool { entry.source == .me }
    private var tint: Color {
        switch entry.source {
        case .me: return .blue
        case .remote: return .purple
        case .room: return .gray
        }
    }

    var body: some View {
        HStack {
            if isMe { Spacer(minLength: 48) }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let label = entry.source.label {
                        Text(label).font(.caption.weight(.semibold)).foregroundStyle(tint)
                    }
                    Text(Transcript.time.string(from: entry.date))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    if isPartial { ProgressView().controlSize(.mini) }
                }
                Text(entry.text)
                    .font(.body)
                    .foregroundStyle(isPartial ? .secondary : .primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(tint.opacity(isPartial ? 0.06 : 0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !isMe && entry.source != .room { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: entry.source == .room ? .leading : (isMe ? .trailing : .leading))
    }
}

// MARK: - History

private struct HistoryView: View {
    let onClose: () -> Void
    let showToast: (String) -> Void
    @State private var items: [SavedTranscript] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Historial").font(.title3.weight(.semibold))
                Spacer()
                Button("Abrir carpeta") { NSWorkspace.shared.open(TranscriptStore.directory) }.controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                    Text("Aún no hay reuniones guardadas").foregroundStyle(.secondary)
                    Text("Cada grabación se guarda sola al detenerla.").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    Button { NSWorkspace.shared.open(item.url) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.callout.weight(.medium))
                            Text(item.preview.isEmpty ? "—" : item.preview)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                    .contextMenu {
                        Button("Copiar texto") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString((try? String(contentsOf: item.url, encoding: .utf8)) ?? "", forType: .string)
                            showToast("Copiado")
                        }
                        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        Divider()
                        Button("Mover a la papelera", role: .destructive) {
                            try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                            items = TranscriptStore.recent()
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear { items = TranscriptStore.recent() }
    }
}

// MARK: - Permissions

private struct PermissionsCard: View {
    let needsScreen: Bool
    @State private var refresh = 0

    private var rows: [(name: String, granted: Bool, request: () -> Void)] {
        _ = refresh
        var r: [(String, Bool, () -> Void)] = [
            ("Micrófono", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, {
                AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { refresh += 1 } }
            }),
            ("Reconocimiento de voz", SFSpeechRecognizer.authorizationStatus() == .authorized, {
                SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async { refresh += 1 } }
            }),
        ]
        if needsScreen {
            r.append(("Audio de apps", CGPreflightScreenCaptureAccess(), {
                _ = CGRequestScreenCaptureAccess(); refresh += 1
            }))
        }
        return r
    }

    var body: some View {
        let rows = rows
        if rows.contains(where: { !$0.granted }) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Permisos necesarios").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(rows, id: \.name) { row in
                    HStack {
                        Image(systemName: row.granted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(row.granted ? .green : .secondary)
                        Text(row.name).font(.callout)
                        Spacer()
                        if !row.granted { Button("Conceder", action: row.request).controlSize(.small) }
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Components

private struct AppBadge: View {
    let size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [.indigo, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Image(systemName: "waveform").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white))
            .frame(width: size, height: size)
            .shadow(color: .purple.opacity(0.3), radius: size * 0.12, y: size * 0.05)
    }
}

private struct RecordingPill: View {
    let start: Date
    @State private var blink = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.red).frame(width: 7, height: 7).opacity(blink ? 0.3 : 1)
            TimelineView(.periodic(from: start, by: 1)) { ctx in
                Text(Transcript.duration(ctx.date.timeIntervalSince(start)))
            }
            .font(.caption.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.red.opacity(0.12), in: Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) { blink = true }
        }
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    @State private var pulse = false
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    Circle().stroke(Color.red.opacity(0.5), lineWidth: 2)
                        .scaleEffect(pulse ? 1.35 : 1).opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.3).repeatForever(autoreverses: false), value: pulse)
                        .onAppear { pulse = true }
                        .onDisappear { pulse = false }
                }
                Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 3)
                    .background(Circle().fill(.background))
                RoundedRectangle(cornerRadius: isRecording ? 6 : 22, style: .continuous)
                    .fill(Color.red.gradient)
                    .frame(width: isRecording ? 22 : 44, height: isRecording ? 22 : 44)
            }
            .frame(width: 56, height: 56)
            .scaleEffect(hovering ? 1.05 : 1)
            .animation(.spring(duration: 0.3), value: isRecording)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isRecording ? "Detener (⌥⌘R)" : "Grabar (⌥⌘R)")
        .accessibilityLabel(isRecording ? "Detener grabación" : "Empezar a grabar")
    }
}

private struct LevelMeter: View {
    let level: Float
    let active: Bool
    @State private var history = Array(repeating: Float(0), count: 18)

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(history.indices, id: \.self) { i in
                Capsule()
                    .fill(active ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .frame(width: 3, height: max(3, CGFloat(history[i]) * 26))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.linear(duration: 0.08), value: history)
        .onChange(of: level) {
            history.removeFirst()
            history.append(level)
        }
        .onChange(of: active) { if !active { history = history.map { _ in 0 } } }
        .accessibilityHidden(true)
    }
}

private struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ActionButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { ActionLabel(title: title, systemName: systemName) }
            .buttonStyle(.bordered)
            .help(title)
    }
}

private struct ActionLabel: View {
    let title: String
    let systemName: String

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemName).font(.system(size: 14, weight: .medium))
            Text(title).font(.caption2)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
    }
}
