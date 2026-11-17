# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MeetingScribe is a privacy-focused macOS menu bar app that records meetings via microphone and transcribes speech to text in real-time using Apple's on-device Speech framework. No data leaves the Mac.

## Build Commands

```bash
# Generate Xcode project from project.yml
xcodegen generate

# Build
xcodebuild -project MeetingScribe.xcodeproj -scheme MeetingScribe -configuration Debug build

# Test
xcodebuild test -project MeetingScribe.xcodeproj -scheme MeetingScribe

# Run single test
xcodebuild test -project MeetingScribe.xcodeproj -scheme MeetingScribe -only-testing:MeetingScribeTests/MeetingScribeTests/testName
```

## Architecture

### Core Components

- **MeetingRecorder** (`MeetingScribe/MeetingRecorder.swift`) - `@MainActor` state + capture. Mic mode: one `AVAudioEngine` (mixer → mono tap). App mode (default): ScreenCaptureKit audio (selected app + its helpers, or all system audio) is the clock; `AVCaptureSession` mic is mixed in by `SourceMixer`, which labels each utterance Tú/Remoto by which source was louder. `requiresOnDeviceRecognition = true` always. `toggle()` is the single entry point (UI, menu, ⌥⌘R hot key).
- **Only ONE recognition task at a time**: on-device `SFSpeechRecognizer` kills the older task (error 1110) when a second starts in the same process — never run one task per source.
- **RecognitionStream** (same file) - new request per utterance (pause 1.6 s / 50 s cap / recognizer gave up). Opening a new request kills the old task, so the old task's last partial is committed as the final text.
- **Transcript** (`Transcript.swift`) - `TranscriptEntry` (source Tú/Remoto/none, date, text), plain text + Markdown formatting, `TranscriptStore` autosave/history in `~/Library/Application Support/MeetingScribe/Transcripts/`.
- **ScreenCaptureManager** - app-level `SCContentFilter` (works with minimised windows), meeting apps listed first.
- **AppDelegate** - status item derived from `recorder.$isRecording` (red dot + elapsed time), right-click menu, Carbon hot key ⌥⌘R.
- **ContentView** - popover UI: chat-style transcript, level meter, record button, history, permissions card, toasts.

### Speech Recognition Locale

Selectable in the gear menu (`MeetingRecorder.languages`), persisted in UserDefaults `language` (default `es-ES`).

## Key Implementation Details

- **Menu bar app**: `LSUIElement: true` in Info.plist (no Dock icon)
- **Entry point**: Manual `NSApplication.shared.run()` in `main.swift` (no @main)
- **App sandbox disabled**: `com.apple.security.app-sandbox: false` (direct microphone access)
- **Audio input entitlement**: `com.apple.security.device.audio-input: true`

## Export Options

- **Autosave** - every stopped recording → Markdown in Application Support (history view)
- **Copiar** - plain text with timestamps and speaker labels
- **Guardar** - NSSavePanel, `.md` (Markdown) or `.txt`
- **Compartir** - SwiftUI `ShareLink` (system share sheet: Mail, Notes, Telegram, AI apps…)

## Known Limitations

- App mode captures meeting audio via ScreenCaptureKit (no BlackHole needed); without headphones the mic also picks up remote voices → duplicated "Tú" lines
- AirPods recommended in noisy environments

## Roadmap (from README)

- [ ] BlackHole support for system audio
- [ ] Export to PDF
- [ ] AI summaries
- [ ] Transcription history