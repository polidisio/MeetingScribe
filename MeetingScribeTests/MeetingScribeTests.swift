import XCTest
@testable import MeetingScribe

final class TranscriptTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func transcript(_ entries: [TranscriptEntry]) -> Transcript {
        Transcript(entries: entries, start: t0, end: t0.addingTimeInterval(125), sourceName: "Zoom + micrófono", language: "es-ES")
    }

    func testPlainTextKeepsChronologicalOrderAndLabels() {
        let t = transcript([
            TranscriptEntry(source: .remote, date: t0, text: "Hola, ¿me oyes?"),
            TranscriptEntry(source: .me, date: t0.addingTimeInterval(3), text: "Sí, perfecto"),
            TranscriptEntry(source: .remote, date: t0.addingTimeInterval(6), text: "Empezamos"),
        ])
        let lines = t.plainText.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("Remoto: Hola, ¿me oyes?"))
        XCTAssertTrue(lines[1].hasSuffix("Tú: Sí, perfecto"))
        XCTAssertTrue(lines[2].hasSuffix("Remoto: Empezamos"))
    }

    func testRoomEntriesHaveNoSpeakerLabel() {
        let t = transcript([TranscriptEntry(source: .room, date: t0, text: "Texto")])
        XCTAssertEqual(t.plainText, "[\(Transcript.time.string(from: t0))] Texto")
    }

    func testMarkdownHasHeaderAndEntries() {
        let md = transcript([TranscriptEntry(source: .me, date: t0, text: "Uno dos tres")]).markdown
        XCTAssertTrue(md.hasPrefix("# Reunión — "))
        XCTAssertTrue(md.contains("**Duración:** 02:05"))
        XCTAssertTrue(md.contains("**Palabras:** 3"))
        XCTAssertTrue(md.contains("**Tú** — Uno dos tres"))
    }

    func testDurationFormatting() {
        XCTAssertEqual(Transcript.duration(0), "00:00")
        XCTAssertEqual(Transcript.duration(754), "12:34")
        XCTAssertEqual(Transcript.duration(3725), "1:02:05")
    }

    func testStoreSavesAndListsWithPreview() throws {
        let t = transcript([TranscriptEntry(source: .me, date: t0, text: "Prueba de historial")])
        let url = try TranscriptStore.save(t)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try XCTUnwrap(TranscriptStore.recent().first { $0.url == url })
        XCTAssertEqual(item.preview, "Tú — Prueba de historial")
        XCTAssertEqual(item.date, t0)
    }
}

@MainActor
final class MeetingRecorderTests: XCTestCase {
    func testInitialStateAndReset() {
        let recorder = MeetingRecorder()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(recorder.entries.isEmpty)
        recorder.reset()
        XCTAssertEqual(recorder.transcription, "")
        XCTAssertNil(recorder.errorMessage)
    }
}
