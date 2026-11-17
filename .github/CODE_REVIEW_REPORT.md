# Code Review Report: MeetingScribe
Generated: 2026-11-18T00:01:45.981087

I've read all 7 source files plus the project config. Here's the review.

---

# MeetingScribe — Code Review

**Scope:** 5 source files (~1200 LOC) + 2 test files + build config. Small, focused codebase; the audio pipeline is the main risk area.

---

_CRITICAL findings withheld from this public PR pending verification against the source code._

## 2. HIGH (should fix)

### H1. `installTap` format almost certainly mismatches the mixer node's output format
**`MeetingRecorder.swift:145-157`**
```swift
engine.connect(engine.inputNode, to: mixer, format: hwFormat)   // mixer output = hwFormat (stereo, 48k)
...
mixer.installTap(onBus: 0, bufferSize: 4096, format: monoFormat) // tap claims mono
```
`installTap(onBus:format:)` requires the format to match the node's output format; a mismatch raises an `NSException` at `engine.start()` (`MeetingRecorder.swift:169`), which is **not** catchable by the `do/catch` around `startCapture` — it crashes the app. The comment says the mixer is used "to downmix ALL Aggregate channels to mono", but nothing actually downmixes: the mixer's output format is set by the connect call to the multichannel hardware format.

**Fix:** Connect with an explicit mono format: `engine.connect(engine.inputNode, to: mixer, format: hwFormat)` then `engine.connect(mixer, to: engine.mainMixerNode, format: monoFormat)` and tap the mixer with `monoFormat`; or tap the mixer using `mixer.outputFormat(forBus: 0)` and do the downmix yourself via `AVAudioConverter`. Verify against the runtime's actual output format before tapping.

### H2. `SCStream` created with `delegate: nil` — stream errors are silently ignored
**`ScreenCaptureManager.swift:72`**
`SCStream` requires a delegate to receive `didStopWithError:`. With `nil`, any mid-session failure (window closed, app quit, permission revoked) is invisible to the app: `isCapturing` stays `true`, the UI keeps showing "Recording", and no partial transcript is finalized. The recorder then keeps appending to a dead request.

**Fix:** Implement `SCStreamDelegate` and surface `didStopWithError` through `onAudioBuffer`'s sibling error callback into `recorder.errorMessage`.

### H3. Speaker diarization mixes two unrelated timestamp timelines
**`MeetingRecorder.swift:242-265`**
Mic segments and screen segments are appended to a single `allSegments` array and compared by `timestamp`, but mic timestamps are relative to the mic session start and screen timestamps relative to the screen session start (which begins ~2s earlier, `MeetingRecorder.swift:327`). The dedup check at line 251 and the pause-based speaker switching at 254-258 therefore compare meaningless values, so segments are randomly dropped as "duplicates" and speakers are mis-assigned.

**Fix:** Keep separate segment arrays and separate speaker maps per source, or normalize every segment to a common clock origin before merging.

### H4. Session rotation discards the final transcription of each45-second window
**`MeetingRecorder.swift:276-285`**
```swift
recognitionRequest = newRequest
startRecognitionTask()
oldRequest?.endAudio()
oldTask?.cancel()
```
`cancel()` is issued immediately after `endAudio()`, so the old task's pending final result is discarded rather than flushed. Every 45 seconds a chunk of speech is lost. The ordering is also wrong: `endAudio()` should be awaited, and the task cancelled only in its completion handler.

**Fix:** Call `oldRequest?.endAudio()` and let the task's completion callback deliver the final result; cancel only after the callback fires, or keep a short grace period.

### H5. Mic permission failure after start is swallowed
**`MeetingRecorder.swift:329-334`**
```swift
} catch {
    self.log("Mic capture failed after delay: \(error)")
}
```
If the microphone is not authorized or unavailable in app-capture mode, the user gets **no feedback** — the app shows "Recording" with only remote audio. `startMicCaptureSession` throws meaningful `NSError`s (codes 3, 4) that are discarded here.

**Fix:** Set `self.errorMessage` and notify the UI on this path.

### H6. `AudioStreamOutput`/recognition callbacks mutate shared state off the main thread
**`MeetingRecorder.swift:313-320`, `ScreenCaptureManager.swift:113`**
`screenBufferCount` is captured by the SCStream sample handler running on `DispatchQueue.global(qos: .userInteractive)` and incremented without synchronization — a data race. Similarly `speakerTranscripts` and `allSegments` are mutated from the mic recognition callback and the screen recognition callback (different threads) while `formatSpeakerOutput()` reads them — unsynchronized concurrent access to a `Dictionary`/`Array` is undefined behavior and can crash.

**Fix:** Confine all mutable session state to a single serial queue (or `DispatchQueue.main`), and make the captured counters properties of the owning object.

### H7. Force unwrap / swallowed errors in `ScreenCaptureManager.startCapture`
**`ScreenCaptureManager.swift:72-81`**
```swift
stream = SCStream(filter: filter, configuration: config, delegate: nil)
try stream?.addStreamOutput(streamOutput!, type: .audio, ...)
try await stream?.startCapture()
```
`streamOutput!` is force-unwrapped, and `try` on an *optional* call means a `nil` stream silently becomes "success" — `startCapture()` proceeds, `isCapturing` is set `true`, and no audio ever flows.

**Fix:** Guard `guard let stream, let output = streamOutput else { throw ... }` and call the non-optional methods.

### H8. App menu "Stop Recording" cannot stop a screen-capture session
**`AppDelegate.swift:91-101`**
`toggleRecording()` always calls `recorder.stopRecording()` (the AVAudioEngine path). If the session was started in "App de Reunión" mode from the popover, the menu's Stop only tears down the mic path — the SCStream and the mic AVCaptureSession keep running. There is no way to stop an app-mode recording from the menu bar.

**Fix:** Route the stop through a single `MeetingRecorder.stop()` that tears down whichever subsystems are active, and expose the active mode.

---

## 3. MEDIUM (consider fixing)

### M1. `NSApp.currentEvent!` force unwrap
**`AppDelegate.swift:41`** — `currentEvent` is `nil` when the action is triggered by keyboard/menu rather than a mouse event, which is exactly the "r" key equivalent path (`AppDelegate.swift:67`). Crash. Use `event?.type` with a default.

### M2. File I/O on the realtime audio thread
**`MeetingRecorder.swift:74-87, 157-165, 313-320`** — `log()` opens a `FileHandle`, seeks, writes and closes the file **on every log line**, and it is called from the AVAudioEngine tap callback and the SCStream handler. That is blocking file I/O at audio priority, causing priority inversion and dropouts. It is also O(file open) per line — very slow. Buffer logs and flush on a background queue/serial timer.

### M3. `log()` reopens the file for every line
**`MeetingRecorder.swift:78-84`** — Open the handle once and keep it; or accumulate in memory and write periodically. Also `seekToEndOfFile()` on a freshly opened handle is redundant.

### M4. `allSegments` and `speakerTranscripts` grow without bound
**`MeetingRecorder.swift:42, 251-252, 262`** — Every segment is retained for the whole session, and `speakerTranscripts` strings are concatenated with `existing + segment.substring + " "` — O(n²) string copying over a long meeting. Drop `allSegments` (it is only used for dedup) or bound it, and use an array + `joined` instead of repeated string concatenation.

### M5. Dedup check is O(n) per segment → O(n²) overall
**`MeetingRecorder.swift:251`** — `allSegments.contains(where:)` scans the whole array for each incoming segment. Use a `Set` of hashable segment keys.

### M6. `meetingApps` allow-list is computed but never used
**`ScreenCaptureManager.swift:28-30`** — The `meetingApps` array is declared and never referenced; the filter actually admits *every* non-excluded app. Either apply the allow-list or delete the dead variable. (Allow-listing is also a mild privacy plus: today the picker lists every running app.)

### M7. `Timer` scheduled on the default run-loop mode
**`MeetingRecorder.swift:271`** — `Timer.scheduledTimer` lands in `.default` mode, so it does not fire while a menu is tracking or during scroll/mouse tracking. Rotation would be delayed past SFSpeechRecognizer's limit. Schedule with `RunLoop.main.add(timer, forMode: .common)`.

### M8. The device picker is ignored in app-capture mode
**`MeetingRecorder.swift:351`** — `AVCaptureDevice.default(for: .audio)` ignores `selectedDeviceID`, so the user's chosen input device is not used when capturing app audio + mic. Use `availableDevices.first { $0.uniqueID == selectedDeviceID } ?? .default(...)`.

### M9. `AVCaptureSession` is started twice**`MeetingRecorder.swift:373` and `MeetingRecorder.swift:392`** — `session.startRunning()` is called twice in `startMicCaptureSession`. The second call is a no-op-with-warning at best. Remove the duplicate.

### M10. `AVCaptureSession` is configured and started on the main thread
**`MeetingRecorder.swift:327, 373`** — `startRunning()` blocks and should not be called on the main thread (it can take hundreds of ms and will freeze the UI). Also `session.sessionPreset` is never set, so the default `.high` preset may be incompatible with the device.

### M11. `FileManager…desktopDirectory.first!` force unwrap
**`MeetingRecorder.swift:57`** — `desktopDirectory` can be absent (network/managed home dirs). Use `?? FileManager.default.temporaryDirectory` or guard it.

### M12. `showMenu()` uses a fragile assign-performClick-unassign trick
**`AppDelegate.swift:86-88`** — Assigning `statusItem.menu` then calling `performClick` then immediately clearing `.menu` races with the async menu display; the menu can fail to open or open as an empty menu. Use a dedicated `NSMenu` retained as a property, or `popover`/custom view instead of hijacking `statusItem.menu`.

### M13. Status-bar icon gets out of sync with actual state
**`AppDelegate.swift:111-115` and `ContentView.swift:199-214`** — The icon is set to "stop" optimistically right after `startRecording()`, even when `startRecording()` bails out with `errorMessage` (`MeetingRecorder.swift:97-102`). It is also set to "stop" *before* the async permission prompt completes. Drive the icon from the observed `recorder.isRecording` state instead.

### M14. `screenCapture.onAudioBuffer` closure is never cleared
**`MeetingRecorder.swift:314` / `ScreenCaptureManager.swift:76-78`** — The manager retains the recorder's closure; the recorder holds `recognitionRequest` via the same object. Set `manager.onAudioBuffer = nil` in `stopScreenCapture` to break the cycle and avoid appending into a stale request.

### M15. `processSegments` speaker-numbering logic is arbitrary
**`MeetingRecorder.swift:254-258`** — `currentSpeaker += 2` and the `> 4` reset means a third pause wraps speakers back to the base number, silently merging different voices into one label. Replace with a real turn-taking heuristic or remove the speaker labels entirely until diarization is reliable.

---

## 4. MINOR (nice to have)

- **`MeetingRecorder.swift:236, 385`** — magic error code `301` (cancelled) should be a named constant or checked via `error.code == 203`/`NSUserSpeechRecognitionErrorDomain`.
- **`MeetingRecorder.swift:30-34`** — `remoteDeviceID`/`localDeviceID` are compatibility shims with no callers; `localDeviceID` is dead. Delete both.
- **`MeetingRecorder.swift:36`** — `mergedTranscription` has no callers; `formatSpeakerOutput()` is called directly instead.
- **`MeetingRecorder.swift:30`** — `requireOnDeviceRecognition` naming typo (see C1).
- **`MeetingRecorder.swift:162`** — the RMS calculation allocates a 4096-element array via `map` on every log interval. Use a `vDSP_measqv`-style loop or `Sequence.reduce` without the intermediate array.
- **`ScreenCaptureManager.swift:50-55`** — `appWindows.first` picks an arbitrary window (possibly a tooltip or utility panel) rather than the largest/frontmost meeting window. Rank by `frame` area and prefer the frontmost window.
- **`ScreenCaptureManager.swift:46`** — `startCapture` re-queries `SCShareableContent`, duplicating the query already done in `refreshApps`; use the cached `selectedApp` and its window list.
- **`ScreenCaptureManager.swift:51-69, 116`** — debug `print` calls remain in production code, and one prints the entire `CMSampleBuffer` description every 5 seconds. Route through the `MeetingRecorder.log` facility or strip them.
- **`ContentView.swift:353`** — `NSSavePanel.begin(completionHandler:)` is deprecated in favor of `runModal()`; the completion handler's thread should also be asserted to be the main thread before touching `@State`.
- **`ContentView.swift:367-375`** — `sendToAria` silently discards the transcription after 2 seconds via `recorder.reset()`. If the user does not paste into Telegram, the transcript is lost with no warning.
- **`ContentView.swift:340-346`** — `copyToClipboard` sets `alertMessage = "Copied to clipboard!"`, then `sendToAria` immediately overwrites it (line 369); the "Copied" message is never seen.
- **`ContentView.swift:36`** — `alertMessage` is used as the alert *title*; error text should be the informative text.
- **`ContentView.swift:11`** — `captureMode` is `@State` and resets to `.microphone` every time the popover is reopened, losing the user's mode choice mid-session.
- **`ContentView.swift:377-381`** — `DateFormatter` is allocated per call and has no `locale` set, so the filename format depends on the user's region. Use a static formatter with `locale = Locale(identifier: "en_US_POSIX")`.
- **`ContentView.swift:106`** — `bundleIdentifier ?? ""` as the picker tag means an app with no bundle ID is indistinguishable from "no selection".
- **`AppDelegate.swift:33`** — `addGlobalMonitorForEvents` only observes events in *other* applications, so clicking inside the popover does not dismiss it, and the monitor requires Accessibility permission (not declared in the entitlements).
- **Tests** — `MeetingScribeTests.swift:35` creates a real `NSStatusItem` that is never removed, leaking a status-bar icon per test run. `testStatusBarIconExists` and `testContentViewRendering` contain no assertions (empty or trivial tests that always pass). `MeetingScribeIntegrationTests.swift:15` calls `recorder.stopRecording()` in `tearDown` for a recorder that never started, which logs "Stop recording called" on every test. `MeetingScribeUITests` lives in a unit-test bundle and `app.launch()` is never exercised meaningfully.
- **`project.yml`** — `ENABLE_HARDENED_RUNTIME: YES` is set, but with the sandbox disabled there is no `com.apple.security.*` hardening beyond `audio-input`; consider also declaring the Screen Recording usage string in `Info.plist` (`NSScreenCaptureUsageDescription` does not exist, but `NSMicrophoneUsageDescription` should mention app-audio capture, and macOS 15+ prompts for "Audio Recording" permission which is not covered by the current usage strings).

---

## Summary

The code is **not** clean. The most urgent items are **C1** (on-device recognition disabled while the product claims the opposite), **C2/C3** (the mic path silently records silence and can crash on format conversion), and **C5** (microphone left running after the user stops). The audio pipeline is the weak point: format handling is guessed rather than derived from the device, and no failure is surfaced to the user. The diarization logic (H3, M15) is also not sound enough to be shipping a "Person1 / Person 2" label to users.

Two systemic patterns recur and would fix many items at once: **(a)** no error from the audio layer ever reaches the UI — every catch logs and continues; **(b)** session state is mutated from multiple threads without a single owner (H6). Addressing (a) with a proper error-reporting path and (b) with one serial session queue would resolve H5, H6, M2, and several others.