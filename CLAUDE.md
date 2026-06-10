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

- **MeetingRecorder** (`MeetingScribe/MeetingRecorder.swift`) - Audio capture and speech recognition. Uses `AVAudioEngine` + `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` for privacy.
- **AppDelegate** - Creates `NSStatusItem` menu bar icon and `NSPopover` containing SwiftUI UI.
- **ContentView** - SwiftUI interface with record/stop button and export options (clipboard, file, send to Aria).

### Data Flow

```
Microphone → AVAudioEngine.inputNode.installTap() → SFSpeechAudioBufferRecognitionRequest → SFSpeechRecognizer.recognitionTask()
                                                                                                              ↓
                                                                                                    @Published transcription (ObservableObject)
                                                                                                              ↓
                                                                                                    ContentView (SwiftUI binding via @ObservedObject)
```

### Recording States

- `.idle` - No active recording
- `.recording` - Audio engine running, partial results streaming
- `.transcribed` - Recording stopped, transcription available for export

### Speech Recognition Locale

Default locale is Spanish (`es-ES`). To add English support, modify `setupSpeechRecognizer()` in MeetingRecorder.swift line 24.

## Key Implementation Details

- **Menu bar app**: `LSUIElement: true` in Info.plist (no Dock icon)
- **Entry point**: Manual `NSApplication.shared.run()` in `main.swift` (no @main)
- **App sandbox disabled**: `com.apple.security.app-sandbox: false` (direct microphone access)
- **Audio input entitlement**: `com.apple.security.device.audio-input: true`

## Export Options

- **Copy Transcription** - Copies to NSPasteboard
- **Save to File** - NSSavePanel with .plainText type, filename `transcription_YYYY-MM-dd_HHmmss.txt`
- **Send to Aria** - Currently copies to clipboard only; roadmap includes real Telegram bot integration

## Known Limitations

- Uses default system microphone only
- For Zoom/Teams/System audio capture, BlackHole virtual audio driver is needed (roadmap item)
- AirPods recommended in noisy environments

## Roadmap (from README)

- [ ] BlackHole support for system audio
- [ ] Export to PDF
- [ ] Aria Telegram bot integration for AI summaries
- [ ] Keyboard shortcuts
- [ ] Transcription history