# Parla

**Transcribe voice messages to text — 100% locally on your Mac.**

Drag a Telegram voice note (or any audio/video file) onto the window — get clean,
copy-ready text in seconds. Powered by [WhisperKit](https://github.com/argmaxinc/WhisperKit)
running OpenAI Whisper on the Apple Neural Engine. Nothing leaves your machine.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift)
![Local](https://img.shields.io/badge/privacy-100%25%20on--device-brightgreen)

---

## Features

- 🎙 **Drag & drop** any audio/video — `.ogg` (Telegram), `.m4a`, `.mp3`, `.wav`, `.mp4`, … (or pick a file / whole folder)
- 🧠 **On-device Whisper** via CoreML / Neural Engine — fast, free, private
- 🌍 **~99 languages** with auto-detect — English and any other work out of the box; great Russian / Ukrainian / surzhik
- 🔁 **Translate to English** — turn speech in any language straight into English text (Whisper translate task)
- 🧩 **Model manager** — pick / download / **delete** models with progress, on-disk size, and a recommended pick
- 🔎 **Searchable history** + 📤 **export** all transcripts to a Markdown file (backup)
- 📋 **Auto-copy** to the clipboard · ⏱ optional **timestamps** · word count · share sheet
- 🔝 **Menu-bar companion** — grab recent transcripts without opening the window
- 🎨 Dark, glassy UI with an indigo aurora background
- 🔒 **No account, no network** for transcription — models download once, then fully offline

## Requirements

- **macOS 14 (Sonoma) or newer.** This floor comes from WhisperKit / on-device CoreML —
  the UI itself uses only macOS-14 APIs (materials + gradients), no macOS-26 Liquid Glass
  lock-in, so it runs on every Mac that can run the engine at all.
- Apple Silicon recommended.
- [`ffmpeg`](https://ffmpeg.org) — needed to decode Telegram's Ogg/Opus (AVFoundation can't):
  `brew install ffmpeg`

## Build & install

```bash
git clone <your-repo-url> Parla
cd Parla
./build_app.sh          # builds Parla.app (first run compiles WhisperKit, a few minutes)
open .                  # then drag Parla.app into /Applications
```

`build_app.sh` produces a signed (ad-hoc) `Parla.app` with an icon. First transcription with
a given model downloads its CoreML weights once (large-v3 turbo ≈ 600 MB–1.5 GB).

## Usage

1. Open **Parla**.
2. In Telegram Desktop, right-click a voice message → **Save As…** → `.ogg`
   (or use any audio/video file).
3. **Drag it onto the drop zone** (or click *choose a file…*).
4. The text appears, lands in your clipboard, and is saved to history. The menu-bar icon
   keeps recent transcripts one click away.

Pick the model and language in **Settings** (⌘,). For Russian/Ukrainian/surzhik, keep the
language on **Auto** and use `large-v3 turbo`.

## How it works

```
audio file ──▶ ffmpeg (→ 16 kHz mono WAV) ──▶ WhisperKit (CoreML / ANE) ──▶ text
```

- `AudioConverter` shells out to `ffmpeg` because Telegram ships Ogg/Opus, which
  AVFoundation (WhisperKit's loader) won't open.
- `TranscriptionEngine` is a small `actor` wrapping WhisperKit; it keeps the loaded model
  in memory and reuses it across files.
- The UI is SwiftUI: a custom sidebar + main pane over an aurora gradient, glass cards
  (`.ultraThinMaterial`), plus a `MenuBarExtra`.
- History is a plain JSON file in `~/Library/Application Support/Parla/`.

## Tech stack

Swift 6 toolchain (Swift 5 language mode) · SwiftUI · [WhisperKit](https://github.com/argmaxinc/WhisperKit) · CoreML · ffmpeg

## Notes

- `ParlaSmoke` is a tiny headless target for sanity-checking the engine
  (`swift run ParlaSmoke <file.wav> openai_whisper-tiny`).
- Rename the app: replace `Parla` in `Package.swift`, the `Sources/Parla` folder name,
  and `build_app.sh`.

## License

MIT — see [LICENSE](LICENSE).
