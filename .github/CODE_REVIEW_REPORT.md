# Code Review Report: MeetingScribe
Generated: 2026-11-19T00:01:38.326573

I've read all 9 source files (5 app sources, tests, project.yml, Info.plist). Here's the review.

---

# MeetingScribe Code Review

**Scope:** `MeetingRecorder.swift`, `ScreenCaptureManager.swift`, `ContentView.swift`, `AppDelegate.swift`, `main.swift`, tests, `project.yml`, `Info.plist`

---

_CRITICAL findings withheld from this public PR pending verification against the source code._

## 2. HIGH — should fix

### H1. Mic recognition dies after ~60 s (never rotated)
**`MeetingRecorder.swift:276-285`** — `rotateSession()` rotates only `recognitionRequest`/`recognitionTask` (the screen/session recognizer). `micRecognitionRequest`/`micRecognitionTask` are never rotated, so the mic recognizer hits the `SFSpeechRecognizer` session limit and errors out; mic transcription stops for the rest of the meeting.

**Fix:** rotate the mic task in the same function, or drive both from one rotation point.

### H2. Screen rotation also discards the tail of each window
**`MeetingRecorder.swift:283-284`** — same `endAudio()` + `cancel()` pattern as C4, so every 45 s rotation loses the last partial segment.

**Fix:** same as C4 — wait for the final result before cancelling.

### H3. Diarization speaker assignment is non-functional
**`MeetingRecorder.swift:242-266`** (`processSegments`)

- `currentSpeaker` and `lastTimestamp` are **local** variables, reset on every call. Pause detection (`pause > 2.0`) can therefore never fire — the first segment of every callback has `lastTimestamp == 0`, and the guard `lastTimestamp > 0` blocks it. Speaker switching never happens by pause.
- `currentSpeaker += 2` with `if currentSpeaker > 4 { currentSpeaker = baseSpeaker }` means mic (base 1) can only ever produce speakers 1 and 3, screen (base 2) only 2 and 4. Since the pause branch is dead, everything lands on the base speaker.
- `allSegments` is shared between the mic and screen streams, so the dedup check compares mic segments against screen segments and the `$0.timestamp > lastTimestamp - 0.1` clause (always `> -0.1`) makes dedup depend on exact timestamp+substring equality — it will usually fail, duplicating segments.

**Fix:** make speaker/pause state instance properties (per source), and dedup on a stable key such as `(source, timestamp, substring)` with rounding of timestamps.

### H4. Mic-mode audio is labelled as remote participants
**`MeetingRecorder.swift:230`** — `self.processSegments(result.bestTranscription.segments)` uses the default `source: "screen"`, so in pure microphone mode the local user's speech is attributed to "Person 2" (the remote participant), never "Person 1".

**Fix:** pass `source: "mic"` from the mic-only recognition path, or track the source per recognizer instance.

### H5. Screen-capture mode silently fails to capture the microphone
**`ContentView.swift:261-279`** — in `.app` mode only speech-recognition permission is requested; `AVCaptureDevice.requestAccess(for: .audio)` is never called. `startMicCaptureSession` then throws "Microphone not authorized" and the error is only written to the log file (`MeetingRecorder.swift:333`) — the user gets a half-working recording with no indication the mic was missing.

**Fix:** request mic permission in `.app` mode too, and surface mic-capture failure in `errorMessage` / the UI.

### H6. Recording writes meeting content to an unencrypted file on the Desktop
**`MeetingRecorder.swift:56-60`, `:229`** — `setupLogFile()` creates `~/Desktop/MeetingScribe_log.txt` and `log("Final segment: \(partial)")` writes **verbatim meeting transcript** into it. This is unencrypted, unconsented, and persists after the app quits; it also breaks the "no data leaves the Mac"-adjacent promise of local-only privacy handling.

**Fix:** remove transcript content from logs (log only lengths/IDs), write logs to `~/Library/Logs/MeetingScribe/` rather than the Desktop, and make it opt-in.

### H7. Status-bar / button state desynchronises from actual recording
**`ContentView.swift:199-214`** — `updateStatusIcon()` is called immediately after `requestPermissionsAndStart()`, but recording only begins after async permission requests complete, so `recorder.isRecording` is still `false` and the icon stays "mic.fill" while recording. `AppDelegate.swift:91-101` has a second, divergent copy of this logic.

**Fix:** drive the icon from `recorder.isRecording` via `onChange(of:)`, and delete the duplicated manual updates in both places.

### H8. `startRunning()` called twice, and blocks the caller
**`MeetingRecorder.swift:373` and `:392`** — `session.startRunning()` is invoked twice on the same `AVCaptureSession`. It is also a blocking call, invoked from a `DispatchQueue.main.asyncAfter` block, so it runs on the **main thread** and can stall the UI.

**Fix:** call `startRunning()` once, on a dedicated background queue.

---

## 3. MEDIUM — consider fixing

### M1. Real-time thread violations in the audio tap
**`MeetingRecorder.swift:157-165`** — the tap callback (audio render thread) performs file I/O via `self?.log(...)` every 25 buffers, and computes RMS by allocating two arrays: `(0..<frameLength).map { ... }.reduce(0, +)`. Both are classic causes of audio glitches/dropouts.

**Fix:** move logging and RMS to a separate timer/queue reading an atomic snapshot.

### M2. `log()` re-opens the log file on every call and creates a formatter each time
**`MeetingRecorder.swift:74-87`** — a new `FileHandle` is opened and closed per log line, and `ISO8601DateFormatter()` is instantiated per call. With logging every ~4 s plus per-segment lines this is unnecessary I/O and allocation churn.

**Fix:** keep one open `FileHandle`, and a static formatter.

### M3. `AudioStreamOutput` decoding uses the same broken planar assumption
**`ScreenCaptureManager.swift:120-124`** → `CMSampleBuffer.toAVAudioPCMBuffer()` — inherits C2. Screen audio is affected too, not just mic.

### M4. `SCStream` is created with a `nil` delegate
**`ScreenCaptureManager.swift:72`** — `SCStream(filter:configuration:delegate: nil)`. Stream errors and the `.ended` lifecycle callback are therefore never delivered; a crashed/interrupted stream fails silently and `isCapturing` stays `true`.

**Fix:** implement `SCStreamDelegate` and propagate `didStopWithError` into `errorMessage`.

### M5. Force-unwrap / optional-chaining swallows capture failures
**`ScreenCaptureManager.swift:74, 81`** — `stream?.addStreamOutput(streamOutput!, ...)` and `try await stream?.startCapture()`. If `stream` were nil these would silently no-op, yet `isCapturing = true` is still set (line 85), so the UI claims to be recording with no audio.

**Fix:** `guard let stream, let streamOutput else { throw ... }`.

### M6. Arbitrary window selection
**`ScreenCaptureManager.swift:53`** — `appWindows.first` may pick a hidden, zero-size, tooltip or offscreen window rather than the meeting's main window.

**Fix:** choose the largest window by area, or prefer the one matching the app's main window.

### M7. Unused/dead code
- `MeetingRecorder.swift:15` `accumulatedText` is written (`:228`) and never read.
- `MeetingRecorder.swift:15, 30-34` `mergedTranscription`, `remoteDeviceID`, `localDeviceID` are unused.
- `ScreenCaptureManager.swift:28` `meetingApps` is computed and never used.
- `ScreenCaptureManager.swift:42` `selectApp(byBundleID:)` is unused (`ContentView` sets `selectedApp` directly).
- `MeetingRecorder.swift:30` "Keep dual-picker API for UI compatibility" — the UI only has one picker; the shim can go.

### M8. `accumulatedText` and `speakerTranscripts` are written from background threads
**`MeetingRecorder.swift:230, 381-382`** — `processSegments` mutates `speakerTranscripts`/`allSegments` on the recognition callback queue, while `formatSpeakerOutput()` reads them on the main thread. Undefined behaviour / lost updates under TSan.

**Fix:** serialise all diarization state onto one queue (or a dedicated actor) and publish only derived strings to the main thread.

### M9. `AudioValueTranslation` size mismatch
**`MeetingRecorder.swift:432-441`** — the pointer is allocated as `UnsafeMutablePointer<CFString?>` (16 bytes) but `mInputDataSize` is reported as `MemoryLayout<CFString>.size` (8). It works by coincidence (the translation reads only the 8-byte CFStringRef) but is inconsistent and fragile.

**Fix:** use `MemoryLayout<CFString?>.size`, or better, query `kAudioDevicePropertyDeviceUID` per device instead of building a translation struct.

### M10. `sendToAria` silently destroys the transcript
**`ContentView.swift:367-375`** — after copying to the clipboard, the transcription is cleared 2 seconds later with no confirmation and no undo. Since "Send to Aria" currently *only* copies to the clipboard (per `CLAUDE.md`), pressing it loses the meeting text with nothing gained.

**Fix:** don't auto-reset; require an explicit "New Recording" press (the button already exists at `:239`).

### M11. Screen-capture mode ignores the user's selected audio device
**`MeetingRecorder.swift:351`** — `AVCaptureDevice.default(for: .audio)` ignores `selectedDeviceID`, so the device picker has no effect in `.app` mode.

### M12. No cleanup on app termination
Neither `AppDelegate` nor `MeetingRecorder` implements `applicationWillTerminate`, so quitting mid-recording leaves the `SCStream`/audio engine running until process teardown and the final transcript is lost.

### M13. `logFile` path force-unwrap
**`MeetingRecorder.swift:57`** — `urls(for: .desktopDirectory, ...).first!` will crash if the Desktop is unavailable (e.g. no home directory / sandboxed profiles).

### M14. `AppDelegate.showMenu` menu hack is fragile
**`AppDelegate.swift:86-88`** — assigning `statusItem.menu`, calling `performClick`, then immediately setting `statusItem.menu = nil` races with menu tracking; the menu can close immediately on some macOS versions.

**Fix:** keep a persistent `NSMenu` and swap its items, rather than attaching/detaching per click.

---

## 4. MINOR — nice to have

- **`ScreenCaptureManager.swift:67`** — `minimumFrameInterval = 1 fps` is a *video* setting; since only an audio output is registered, consider whether video frames are still being rendered (wasted GPU).
- **`MeetingRecorder.swift:389` vs `:387`** — the mic task is started *after* `session.startRunning()` (`:373`), so the first buffers are appended to a request with no consumer. Start the recognition task before running the session.
- **`MeetingRecorder.swift:333`** — mic-capture failure is only logged, never surfaced to the user (see H5).
- **`ContentView.swift:265-279`** — permission requests are duplicated between `AppDelegate.requestPermissionsAndStartRecording` and `ContentView.requestPermissionsAndStart`; consolidate into one place.
- **`ContentView.swift:377-381`** — `DateFormatter` is recreated per call; use a static one.
- **`MeetingRecorder.swift:97-102`** — `errorMessage` is not cleared when a subsequent start succeeds.
- **`ScreenCaptureManager.swift:14`** — `errorMessage` is never displayed in the UI (`ContentView` only shows `recorder.errorMessage`).
- **Tests (`MeetingScribeIntegrationTests.swift:20-41, 47-56`)** — the assertions are tautological (`XCTAssertTrue(permission == .undetermined || …)`) and test nothing meaningful. Worth replacing with tests for the pure logic that actually has bugs: `processSegments` speaker assignment, `formatSpeakerOutput`, and the sample-buffer conversion.
- **`MeetingScribeIntegrationTests.swift:48`** — `AVAudioSession.sharedInstance().recordPermission` is deprecated on macOS 10.14+; use `AVCaptureDevice.authorizationStatus(for: .audio)`.
- **`MeetingRecorder.swift:114-172`** — `startCapture()` has an important implicit contract (device must be set before the input format is queried) that isn't documented; a one-line comment would help.

---

## Summary

The code is **not clean**. The two most serious problems are (1) the app uploads audio to Apple servers despite advertising on-device-only privacy, and (2) the hand-rolled CMSampleBuffer→AVAudioPCMBuffer conversion is wrong for planar audio, which plausibly explains poor transcription quality. Beyond those, the session-rotation logic loses text and never rotates the mic recognizer, the diarization speaker assignment is effectively dead code, and the transcription exported to disk contains `[Partial: …]` artifacts. The UI also has duplicated and desynchronised status logic, and the app writes verbatim meeting content to an unencrypted file on the Desktop.

Highest-value first steps: fix C1 (one-line), replace the audio conversion with `AVAudioConverter` (C2), and rework stop/rotation to await final results (C4/H1/H2).