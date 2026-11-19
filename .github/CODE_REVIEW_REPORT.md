# Code Review Report: MeetingScribe
Generated: 2026-11-20T00:01:22.558468

I've read all the source files. Here's my review.

---

# MeetingScribe Code Review

Reviewed: `MeetingRecorder.swift`, `ScreenCaptureManager.swift`, `ContentView.swift`, `AppDelegate.swift`, `main.swift`, `Info.plist`, `project.yml`, both test files. The codebase is small and mostly readable, but it has several real defects.

---

_CRITICAL findings withheld from this public PR pending verification against the source code._

## 2. HIGH issues (should fix)

### H1. `installTap` on the mixer never gets a valid mono downmix
**`MeetingRecorder.swift:142-147`** — the comment says the mixer is used to "downmix ALL Aggregate channels to mono", but the mixer is connected with `hwFormat` (multi-channel), so the tap receives multi-channel audio, not the mono the comment describes. Combined with C4 the mono downmix never actually happens.

### H2. Microphone recognition is never rotated → dies after ~60s
**`MeetingRecorder.swift:276-285`**

`rotateSession()` only rotates `recognitionRequest` (screen). `micRecognitionRequest` is created once in `startScreenCapture` and never rotated, so `SFSpeechRecognizer`'s ~60s hard limit kills mic transcription for the rest of the meeting — silently, since the error is only logged.

**Fix:** Rotate both requests in `rotateSession()`, and cancel/restart `micRecognitionTask` accordingly.

### H3. Menu-bar "Stop Recording" doesn't stop screen capture
**`AppDelegate.swift:91-101`**

`toggleRecording()` always calls `recorder.stopRecording()`, which tears down the AVAudioEngine path only. If the user started capture in "App de Reunión" mode via the popover, the `SCStream` and the `AVCaptureSession` keep running: the app keeps recording the microphone and the meeting app's audio after the user pressed stop. `stopScreenCapture(manager:)` is the correct teardown and is never called from here.

**Fix:** Track the active capture mode in `MeetingRecorder` (or pass the manager to `AppDelegate`) and dispatch to the matching stop path.

### H4. Mic failure in app-capture mode is swallowed
**`MeetingRecorder.swift:327-335`**

Mic capture starts 2 seconds *after* screen capture, in a `DispatchQueue.main.asyncAfter` block. If it throws (permission revoked, no mic), the error is only written to the log file — the user sees a recording that looks healthy but has no local speaker, and `errorMessage` is never set.

**Fix:** Set `self.errorMessage` on the main actor and surface it in the UI.

### H5. Blocking `startRunning()` on the main thread
**`MeetingRecorder.swift:373` and `:392`**

`AVCaptureSession.startRunning()` blocks the calling thread for hundreds of ms. It's called from `DispatchQueue.main.asyncAfter`, i.e. the main queue — the menu bar UI freezes during startup. It's also called **twice** (lines 373 and 392), a leftover from the refactor.

**Fix:** Call `startRunning()` once, on a dedicated background queue.

### H6. File I/O inside the real-time audio callback
**`MeetingRecorder.swift:157-165` → `log()` at `:74-87`**

The mixer tap runs on a real-time audio thread and calls `self?.log(...)` every 25 buffers. `log()` creates an `ISO8601DateFormatter` per call, opens a `FileHandle`, seeks, writes, and closes — all on the audio thread. That is heavy I/O on an RT thread: it can cause buffer underruns/dropouts and audible glitches. The RMS computation at line 162 also allocates two `Array`s per call via `.map{}` — allocation on an RT thread.

**Fix:** Move logging to a background queue with a buffered writer; compute RMS with a `vDSP_measqv` call or a plain `for` loop with no allocation.

### H7. Log file leaks transcript content to the Desktop
**`MeetingRecorder.swift:56-60`, `:229`**

`log("Final segment: \(partial)")` writes the full spoken transcript in plaintext to `~/Desktop/MeetingScribe_log.txt`, in a world-readable location, with no file protection, and it accumulates across sessions (appended forever). For an app whose pitch is privacy, this is a meaningful leak — it also captures meeting content that the user never explicitly asked to persist.

**Fix:** Either drop transcript content from logs, or put the log in `~/Library/Application Support` (or Caches) with `.completeFileProtection`, and rotate/truncate it.

---

## 3. MEDIUM issues (consider fixing)

### M1. `NSApp.currentEvent!` force unwrap
**`AppDelegate.swift:41`** — `currentEvent` is `nil` when the action is invoked programmatically (keyboard shortcut, menu item, accessibility). Crashes the app. Use `NSApp.currentEvent?.type == .rightMouseUp` with an optional-chained comparison.

### M2. `showMenu()` hack is fragile and re-entrant
**`AppDelegate.swift:63-89`** — Assigning `statusItem.menu` and calling `performClick(nil)` synthesizes an event whose type is `.leftMouseUp`, so `showPopoverAndMenu` runs again and opens the popover. It also leaves `statusItem.menu` set for the duration of the click. Build the menu and call `NSMenu.popUp(positioning:at:in:)` instead.

### M3. `processSegments` mixes timestamps from two unrelated recognizers
**`MeetingRecorder.swift:250-259`** — `allSegments` is shared between the screen and mic tasks, but each task's segment timestamps are relative to *its own* request. The dedup check (`$0.timestamp == segment.timestamp && $0.substring == segment.substring`) will therefore collide across sources and the pause-based speaker logic is meaningless. Keep per-source segment lists.

### M4. Speaker numbering can skip/duplicate
**`MeetingRecorder.swift:255-258`** — `currentSpeaker += 2` on a pause, with mic base 1 and screen base 2. A single pause in mic audio jumps Person 1 → Person 3, and a second pause wraps to 1, producing a "Person 3" with no "Person 2" in between. The mapping needs to be explicit, e.g. separate (source, turn) counters.

### M5. `accumulatedText` is dead code
**`MeetingRecorder.swift:15, 93, 228`** — it's appended to but never read; the displayed text comes only from `speakerTranscripts`. Either use it as the fallback for `formatSpeakerOutput()` (so a mic-only recording isn't lost when diarization yields one speaker) or delete it.

### M6. `canAddInput`/`canAddOutput` failures are ignored
**`MeetingRecorder.swift:360-371`** — if the input or output can't be added, the session starts with no audio and no error is reported. Throw instead.

### M7. Hardcoded device-name matching is fragile
**`MeetingRecorder.swift:120-123`** — `findDeviceID(containing: "Capture")` matches the *first* device whose name contains "Capture", which can be an unrelated USB interface. Prefer matching the aggregate device explicitly (e.g. by checking `AVAudioDevice`/`kAudioHardwarePropertyDeviceForUID` of known aggregate UIDs, or by inspecting `device.isConnected` and the aggregate's sub-devices).

### M8. No error surface for `SCStream` runtime failures
**`ScreenCaptureManager.swift:72`** — `SCStream` is created with `delegate: nil`, so runtime stream errors are dropped on the floor. Implement `SCStreamDelegate.stream(_:didStopWithError:)` and report it.

### M9. `refreshApps` filter is dead code
**`ScreenCaptureManager.swift:28`** — `meetingApps` is declared and never used; the filter only applies `excluded`. Either use the allowlist (which matches the intent — "meeting apps only") or delete the variable.

### M10. `SCContentFilter(desktopIndependentWindow:)` is deprecated
**`ScreenCaptureManager.swift:59`** — deprecated since macOS 13 in favour of `SCContentFilter(desktopIndependentWindow:)` → `init(desktopIndependentWindow:)` is superseded by the new `SCContentFilter` with `SCStreamConfiguration.captureResolution`/window list. Migrate to the macOS 14 API since deployment target is 14.0.

### M11. Locale is hardcoded with no fallback
**`MeetingRecorder.swift:52-53`** — `SFSpeechRecognizer(locale: "es-ES")` is used without checking `isAvailable` / `supportsOnDeviceRecognition`. If the locale is unavailable the recognition task fails immediately with only a log line. Expose a locale picker and report unavailability in `errorMessage`.

### M12. `saveToFile` uses the deprecated `NSSavePanel.begin`
**`ContentView.swift:353`** — deprecated since macOS 12; also, without a parent window there's no proper sheet presentation. Use `beginSheetModal(for:)` against the popover's window.

---

## 4. MINOR suggestions (nice to have)

- **`MeetingRecorder.swift:57`** — `urls(for: .desktopDirectory, ...).first!` force unwrap; use `?? FileManager.default.temporaryDirectory` fallback. The Desktop directory also may not be writable in all environments.
- **`MeetingRecorder.swift:236`, `:385`** — magic number `301` (the `SFSpeechRecognizer` "no more audio" sentinel). Extract to a named constant.
- **`MeetingRecorder.swift:236`** — `error as NSError?` — the double optional is redundant; `error as? NSError` is clearer.
- **`MeetingRecorder.swift:20-21`** — `micAudioInput` is stored but never used; `remoteDeviceID`/`localDeviceID` are a vestigial dual-picker API ("reserved for future use") — delete them.
- **`MeetingRecorder.swift:42`, `:265`** — `allSegments` grows unboundedly for the life of a recording and `contains(where:)` is O(n) per segment → O(n²) over a long meeting. Bound it or use a `Set` keyed by (timestamp, substring).
- **`ScreenCaptureManager.swift:106-117`** — `bufferCount`/`lastLogTime` are mutated from the stream's output queue without synchronization; if the output is ever moved to a different queue this becomes a data race. Mark the class `@unchecked Sendable` or confine the state.
- **`ScreenCaptureManager.swift:74`** — `streamOutput!` force unwrap immediately after assignment; use `guard let`.
- **`ContentView.swift:212`** — `updateStatusIcon()` is called right after the start action, before permissions resolve and before capture actually begins, so the icon shows "stop" even if the start fails. Move the icon update into a `recorder.isRecording` `onChange` or update it from the recorder's published state.
- **`ContentView.swift:367-375`** — "Aria" is a clipboard copy followed by `recorder.reset()` after 2 seconds, which wipes the user's transcript from the UI. Don't reset on a stub action.
- **`AppDelegate.swift:145-149`** — `deinit` never runs: `main.swift` holds the delegate in a global `let`. The event monitor is therefore never removed (harmless at exit, but the pattern is misleading).
- **`MeetingScribeTests.swift:35`** — the test creates an `NSStatusItem` that is never removed, leaking a menu bar item during the test run. Also `mockStatusItem` is unused; `testContentViewRendering` doesn't render anything. The tests are largely tautological (`testErrorMessageHandling` asserts nil after `reset()`); consider asserting real behavior instead.
- **`MeetingScribeUITests.swift`** — declared in a `bundle.unit-test` target, so these XCUIApplication-based tests won't run as intended; `testStatusBarIconExists` has no assertions at all.
- **Logging** — the codebase uses `print()` in `ScreenCaptureManager` for diagnostics alongside the file logger. Unify on `os.Logger` (with a privacy-conscious `OSLog` category) so logs are filterable and can be stripped from release builds.

---

## Summary

The code is **not** clean — there are four must-fix issues. The most consequential is **C1**: the app claims on-device privacy while `requiresOnDeviceRecognition = false` streams audio to Apple. **C2** (unsynchronized dictionary writes from two recognition queues) and **C4** (tap format mismatch, which the repo already fixed once in `b258a54` before the mixer refactor) will both crash or corrupt data in normal use, and **C3** means the "App de Reunión" mode likely transcribes nothing but silence from the screen source.

Beyond correctness, the privacy story has a second hole: **H7** writes the full transcript to a plaintext file on the Desktop.