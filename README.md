# Lens

Lens is a floating macOS translation overlay. It captures the content behind its own window, runs on-device OCR with Vision, and redraws translated text in place so you can read foreign-language UI, web pages, documents, and video subtitles without copying text into another app.

## Requirements

- macOS 26 or newer
- Xcode and the Swift 6.2 toolchain
- Screen Recording permission for the app

## Build

```bash
swift build
```

## Launch

Run through SwiftPM:

```bash
swift run Lens
```

Or launch the built executable directly:

```bash
./.build/debug/Lens
```

On first launch, macOS should prompt for Screen Recording permission. If the overlay appears blank, check System Settings > Privacy & Security > Screen Recording and allow Lens or the terminal app you launched it from.

## How It Works

- Screen capture uses ScreenCaptureKit
- OCR runs locally with Apple Vision
- Translation uses Apple's Translation framework
- The overlay updates continuously and suppresses translations while the underlying content is scrolling
- Repeated phrases are cached to reduce translation churn

## Controls

- Move or resize the floating lens window over any content you want to read
- Open Settings to choose the target language and optionally show source text
- Use the Lens app menu to pause or resume capture and to force a manual refresh

## Project Layout

- `Sources/Lens/App` contains the SwiftUI app, overlay view, window behavior, and settings UI
- `Sources/Lens/Capture` contains screen capture code
- `Sources/Lens/OCR` contains Vision text recognition
- `Sources/Lens/Translation` contains translation and phrase caching

## Notes

- This repository includes local reference folders `Snip-Text` and `sim-daltonism`, but they are not part of the Lens app and are ignored by git
- `.build/` is generated output and is not tracked
- The project is still in active development and some edge cases around layout stability and translation quality remain rough
