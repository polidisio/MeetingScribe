# MeetingScribe 🎤

**macOS menu bar app for recording and transcribing meetings using on-device speech recognition.**

## Overview

MeetingScribe is a lightweight macOS application that lives in your menu bar and allows you to:
- Record meetings using your Mac's microphone (AirPods, built-in mic, etc.)
- Transcribe speech to text in real-time using Apple's on-device Speech framework
- Save transcriptions, copy to clipboard, or send them to Aria for action item extraction

## Features

- 🎤 **One-click recording** from menu bar
- 🔒 **Privacy-first** - All processing happens locally on your Mac using Apple's Speech framework
- 🌐 **Multi-language support** - Speech recognition in Spanish (es-ES) and English (en-US)
- 📋 **Multiple export options** - Save to file, copy to clipboard, or send to Aria
- 📊 **Live transcription display** - See your words appear in real-time

## Requirements

- macOS 14.0 (Sonoma) or later
- Microphone access permission
- Speech recognition permission (both granted on first run)

## Installation

### From Source

```bash
# Clone the repository
git clone https://github.com/polidisio/MeetingScribe.git
cd MeetingScribe

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open MeetingScribe.xcodeproj

# Build and run (Cmd+R)
```

### Build from Command Line

```bash
xcodebuild -project MeetingScribe.xcodeproj -scheme MeetingScribe -configuration Debug build
```

## Usage

1. **Click the microphone icon** in your menu bar
2. **Select "Start Recording"** from the dropdown menu
3. **Grant permissions** on first use (microphone + speech recognition)
4. **Join your meeting** - MeetingScribe will transcribe everything it hears
5. **Click "Stop"** when the meeting ends
6. **Choose an export option:**
   - **Copy Transcription** - Copy to clipboard for pasting anywhere
   - **Save to File** - Save as .txt file
   - **Send to Aria** - Copy to clipboard with a message to paste in Telegram

## Privacy

- All audio processing happens **on-device** using Apple's Speech framework
- **No data sent to external servers**
- Audio is captured locally and never leaves your Mac
- Supports on-device speech recognition for maximum privacy

## Architecture

```
MeetingScribe/
├── main.swift              # Application entry point
├── AppDelegate.swift       # Menu bar setup and window management
├── ContentView.swift       # SwiftUI popover interface
├── MeetingRecorder.swift   # Audio recording and speech recognition logic
├── Info.plist              # App configuration and permissions
├── MeetingScribe.entitlements  # App entitlements
└── Assets.xcassets/        # App icons and images

MeetingScribeTests/
├── MeetingScribeTests.swift           # Unit tests
└── MeetingScribeIntegrationTests.swift # Integration tests
```

## Testing

```bash
# Run all tests
xcodebuild test -project MeetingScribe.xcodeproj -scheme MeetingScribe

# Run with coverage
xcodebuild test -project MeetingScribe.xcodeproj -scheme MeetingScribe -enableCodeCoverage YES
```

## Known Limitations

- **Audio capture** uses the default microphone input
- For capturing system audio (Teams, Zoom, etc.), consider using **BlackHole** virtual audio driver
- AirPods or headphones recommended for best quality in noisy environments

## Roadmap

- [ ] Add BlackHole support for system audio capture
- [ ] Export to PDF format
- [ ] Integration with Aria via Telegram bot
- [ ] Keyboard shortcut support
- [ ] Transcription history

## License

MIT License - See LICENSE file for details

## Author

Built with ❤️ by Aria for Jose (Saraiba)