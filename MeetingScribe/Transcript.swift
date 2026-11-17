import Foundation

struct TranscriptEntry: Identifiable, Equatable {
    enum Source: String {
        case me       // local microphone in app-capture mode
        case remote   // meeting app audio (ScreenCaptureKit)
        case room     // single mixed input (microphone mode) — speaker unknown

        var label: String? {
            switch self {
            case .me: return "Tú"
            case .remote: return "Remoto"
            case .room: return nil
            }
        }
    }

    var id = UUID()
    let source: Source
    let date: Date
    let text: String
}

struct Transcript {
    var entries: [TranscriptEntry]
    var start: Date
    var end: Date
    var sourceName: String
    var language: String

    var wordCount: Int {
        entries.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    var plainText: String {
        entries.map { "[\(Self.time.string(from: $0.date))] " + Self.prefix($0) + $0.text }
            .joined(separator: "\n")
    }

    var markdown: String {
        var md = """
        # Reunión — \(Self.longDate.string(from: start))

        - **Duración:** \(Self.duration(end.timeIntervalSince(start)))
        - **Fuente:** \(sourceName)
        - **Idioma:** \(language)
        - **Palabras:** \(wordCount)

        ---


        """
        for e in entries {
            let who = e.source.label.map { "**\($0)** — " } ?? ""
            md += "**\(Self.time.string(from: e.date))** \(who)\(e.text)\n\n"
        }
        return md
    }

    private static func prefix(_ e: TranscriptEntry) -> String {
        e.source.label.map { "\($0): " } ?? ""
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateStyle = .long; f.timeStyle = .short
        return f
    }()

    static let fileStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"; return f
    }()
}

// MARK: - Auto-save / history

struct SavedTranscript: Identifiable {
    let url: URL
    let date: Date
    let preview: String
    var id: URL { url }
}

enum TranscriptStore {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe/Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func save(_ t: Transcript) throws -> URL {
        let url = directory.appendingPathComponent("reunion_\(Transcript.fileStamp.string(from: t.start)).md")
        try t.markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // ponytail: reads every file on open; fine for hundreds of meetings, index if it gets slow
    static func recent(limit: Int = 30) -> [SavedTranscript] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .map { url in
                let stamp = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "reunion_", with: "")
                let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let firstLine = body.split(separator: "\n").first { $0.hasPrefix("**") } ?? ""
                let preview = firstLine.replacingOccurrences(of: "**", with: "")
                    .split(separator: " ", maxSplits: 1).dropFirst().joined()  // drop timestamp
                return SavedTranscript(url: url,
                                       date: Transcript.fileStamp.date(from: stamp) ?? .distantPast,
                                       preview: preview)
            }
    }
}
