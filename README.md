# Murmur

**Transcribe voice messages to text — 100% locally on your Mac.**

Drag a Telegram voice note (or any audio/video file) onto the window — get clean,
copy-ready text in seconds. Powered by [WhisperKit](https://github.com/argmaxinc/WhisperKit)
running OpenAI Whisper on the Apple Neural Engine. Nothing leaves your machine.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift)
![Local](https://img.shields.io/badge/privacy-100%25%20on--device-brightgreen)

---

## Features

- 🎙 **Drag & drop** any audio/video — `.ogg` (Telegram), `.m4a`, `.mp3`, `.wav`, `.mp4`, …
- 🧠 **On-device Whisper** via CoreML / Neural Engine — fast, free, private
- 🌍 **Multilingual** with auto language detection (great Russian, English, etc.)
- 📋 **Auto-copy** the result to the clipboard
- 🕘 **History** of every transcription, searchable in the sidebar
- 🔝 **Menu-bar companion** — grab recent transcripts without opening the window
- ⏱ Optional **timestamps**, model picker (tiny → large-v3 turbo), share sheet
- 🔒 **No account, no network** for transcription — model is downloaded once, then offline

## Requirements

- macOS 14 (Sonoma) or newer, Apple Silicon recommended
- [`ffmpeg`](https://ffmpeg.org) — needed to decode Telegram's Ogg/Opus
  (AVFoundation can't): `brew install ffmpeg`

## Build & install

```bash
git clone <your-repo-url> Murmur
cd Murmur
./build_app.sh          # builds Murmur.app (first run compiles WhisperKit, a few minutes)
open .                  # then drag Murmur.app into /Applications
```

`build_app.sh` produces a signed (ad-hoc) `Murmur.app` with an icon. First launch of a
model downloads its CoreML weights once (large-v3 turbo ≈ 600 MB–1.5 GB) into
`~/Documents/huggingface`.

## Usage

1. Open **Murmur**.
2. In Telegram Desktop, right-click a voice message → **Save As…** → `.ogg`
   (or use any audio/video file you have).
3. **Drag it onto the drop zone** (or click *choose a file…*).
4. The text appears, lands in your clipboard, and is saved to history.
   The menu-bar icon keeps your recent transcripts one click away.

Pick the model and language in **Settings** (⌘,). For Russian, `large-v3 turbo` is the
sweet spot of speed and accuracy.

## How it works

```
audio file ──▶ ffmpeg (→ 16 kHz mono WAV) ──▶ WhisperKit (CoreML / ANE) ──▶ text
```

- `AudioConverter` shells out to `ffmpeg` because Telegram ships Ogg/Opus, which
  AVFoundation (WhisperKit's loader) won't open.
- `TranscriptionEngine` is a small `actor` wrapping WhisperKit; it keeps the loaded
  model in memory and reuses it across files.
- The UI is SwiftUI: a `NavigationSplitView` (history + detail) plus a `MenuBarExtra`.
- History is a plain JSON file in `~/Library/Application Support/Murmur/`.

## Tech stack

Swift 6 · SwiftUI · [WhisperKit](https://github.com/argmaxinc/WhisperKit) · CoreML · ffmpeg

## Notes

- `MurmurSmoke` is a tiny headless target used to sanity-check the engine
  (`swift run MurmurSmoke <file.wav> openai_whisper-tiny`).
- The app name/bundle id (`Murmur` / `com.murmur.app`) are trivial to rename —
  search-replace in `Package.swift`, the `Sources/` folder name, and `build_app.sh`.

## License

MIT — see [LICENSE](LICENSE).
