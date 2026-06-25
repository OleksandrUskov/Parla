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
- ✏️ **Edit transcripts in place** — fix the odd misheard word; the correction is saved to history
- ▶️ **Built-in audio player** — listen alongside the text and **click any timestamp to jump** there
- 🔂 **Re-transcribe** an old entry with a different model (compare Tiny vs large-v3 turbo) — no re-dragging
- 👁 **Folder watch** — point Parla at a folder and new audio is transcribed automatically, hands-free
- 📦 **Batch progress** “N of M” + a completion notification when a long job finishes in the background
- ⌨️ **Quick-transcribe from the menu bar** — “from clipboard”, “repeat last file”, popover drop, or an optional **rebindable** global hotkey (default ⌃⌥⌘T, no Accessibility permission)
- 🎙️ **Live mic dictation** *(opt-in)* — press a hotkey (default ⌃⌥⌘D), speak, press again; Parla transcribes it on-device and copies the text. Microphone permission only, **no Accessibility**
- 🧩 **Model manager** — pick / download / **delete** models with progress, on-disk size, and a recommended pick
- 🔎 **Searchable history** + 📤 **export** — each transcript to **SRT / VTT / JSON / TXT / Markdown**, or the whole history to one Markdown backup
- 📖 **Long recordings** — files over ~10 min are chunked (bounded memory + per-chunk progress) and shown as collapsible chapters
- 🤖 **Automation** — a `parla://` URL scheme, a Finder **Services** entry, and **Shortcuts / Spotlight** actions (see [Automation](#automation--integrations))
- 📋 **Auto-copy** to the clipboard · ⏱ optional **timestamps** · word count · share sheet
- 🔝 **Menu-bar companion** — grab recent transcripts without opening the window
- 🎨 Dark, glassy UI with an indigo aurora background
- 🔒 **No account, no network** for transcription — models download once, then fully offline

## Requirements

- **macOS 14 (Sonoma) or newer.** This floor comes from WhisperKit / on-device CoreML —
  the UI itself uses only macOS-14 APIs (materials + gradients), no macOS-26 Liquid Glass
  lock-in, so it runs on every Mac that can run the engine at all.
- Apple Silicon recommended.
- **No extra setup** — a small self-contained LGPL [`ffmpeg`](https://ffmpeg.org) is **bundled inside
  the app** to decode Telegram's Ogg/Opus (which AVFoundation can't open). A system `ffmpeg`
  (`brew install ffmpeg`) is used automatically as a fallback if one is installed.

## Build & install

```bash
git clone <your-repo-url> Parla
cd Parla
./build_app.sh          # builds Parla.app (first run compiles WhisperKit, a few minutes)
open Parla.app          # launch it (or double-click Parla.app in Finder; drag into /Applications to keep)
```

`build_app.sh` produces a signed (ad-hoc) `Parla.app` with an icon. First transcription with
a given model downloads its CoreML weights once (large-v3 turbo ≈ 600 MB–1.5 GB).

> **Run it as the built `.app`, not from an IDE.** Parla is a Swift Package, not an Xcode project —
> pressing **Build & Run** in Xcode/VS Code launches the bare executable, and a SwiftUI windowed app
> needs a real `.app` bundle to show its window, so nothing appears. Always run via
> `./build_app.sh && open Parla.app` (or double-click the built `Parla.app`).
>
> First launch of a big model shows **"Загружаю модель в память…"** for a while — that's a **one-time**
> CoreML/Neural-Engine compile (the model is already on disk; it's not re-downloading), cached afterward.
> Subsequent launches are fast. Want it consistently quick? Pick a smaller model (Base/Small).

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
m4a / mp3 / wav ──────────────────────────────▶ WhisperKit (CoreML / ANE) ──▶ text   (AVFoundation, no ffmpeg)
ogg / opus / video ──▶ ffmpeg → 16 kHz mono WAV ──▶ WhisperKit ────────────▶ text   (bundled LGPL ffmpeg)
```

- Formats AVFoundation can open (`m4a`/`mp3`/`wav`) go **straight to the engine** — no ffmpeg. Telegram's
  Ogg/Opus (and video) are decoded by a **bundled, self-contained LGPL `ffmpeg`** — nothing to install.
- Long recordings (> ~10 min) are split into ~2-min chunks and stitched back into one timeline — bounded
  memory, per-chunk progress, resilient to a single bad chunk.
- `TranscriptionEngine` is a small `actor` wrapping WhisperKit; it keeps the loaded model in memory and
  reuses it across files. The whole package builds in **Swift 6 language mode** (strict concurrency).
- The UI is SwiftUI: a custom sidebar + main pane over an aurora gradient, glass cards
  (`.ultraThinMaterial`), plus a `MenuBarExtra`.
- History is a plain JSON file in `~/Library/Application Support/Parla/`.

## Privacy & permissions

Parla is **100% on-device** — audio is transcribed locally by WhisperKit. Nothing is uploaded;
there is no account, telemetry, or analytics. The only network use is the **one-time model
download** (CoreML weights from Hugging Face).

Everything beyond plain transcription is **opt-in** and asks for the minimum macOS permission:

| Feature | Permission | Notes |
|---|---|---|
| Transcribe · edit · player · history | **none** | local files only |
| Menu-bar quick actions (clipboard / last file / popover drop) | **none** | reads a file URL from the clipboard only when you click or drop |
| Folder watch | folder access (macOS may prompt once for Downloads/Desktop/Documents) | only **new** files that appear *after* you turn it on are processed |
| Global hotkey *(off by default, rebindable, default ⌃⌥⌘T)* | **none** | uses Carbon `RegisterEventHotKey` (via [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)) — registers one chosen combo, **no Accessibility, no system prompt, no keystroke logging**. The menu-bar buttons work too |
| Live mic dictation *(off by default, rebindable, default ⌃⌥⌘D)* | **Microphone** | records the mic **only while you dictate**, transcribes on-device, copies the text — audio never leaves your Mac. Uses the Microphone permission only (**no Accessibility**) |
| Services menu · `parla://` URL scheme · Shortcuts / Spotlight actions | **none** | transcribe **existing local files only**, read-only — the same on-device pipeline as a drag-and-drop |

Parla is **not sandboxed** (it shells out to `ffmpeg`), so it ships outside the Mac App Store —
and it's open source, so you can read exactly what it does.

**Audio cache.** For the in-app player, Parla keeps a copy of each transcribed clip in
`~/Library/Application Support/Parla/audio/`. This is **auto-managed**: the cache is capped at
**500 MB** and the oldest clips' audio is removed automatically when it grows past that — **your
transcript text is always kept** (an evicted clip just loses its replay button; you can re-transcribe
from the original file). You can also clear it anytime in **Settings**. To change the cap (e.g. keep
more for long-form replay, or disable auto-cleanup):

```bash
defaults write com.parla.app PARLA_AUDIO_CAP_MB -int 2000   # 2 GB; use 0 for unlimited
```

## Automation / integrations

Parla is also a *verb* other tools can call — everything funnels into the same on-device pipeline, no extra setup.

**`parla://` URL scheme** — from a terminal, Raycast, Alfred, Stream Deck, Keyboard Maestro, or a `.command` file:

```bash
open "parla://transcribe?path=/Users/me/voice.ogg"     # transcribe a file (repeat path= for several)
open "parla://transcribe?dir=/Users/me/VoiceNotes"     # transcribe a whole folder
open "parla://transcribe-last"                          # re-run the last file
open "parla://clipboard"                                # transcribe the audio file on the clipboard
open "parla://show"                                     # just bring Parla forward
```

Only existing audio files / folders are accepted, and only for reading — a `parla://` link can never move, write, or delete anything.

**Services menu** — right-click an audio/video file (or selection) in Finder → *Services › Transcribe with Parla*.

**Shortcuts · Spotlight · Siri** — three [App Intents](https://developer.apple.com/documentation/appintents) in Shortcuts.app: *Transcribe File with Parla*, *Transcribe Last File with Parla*, and *Get Last Parla Transcript* (a read action you can pipe into another Shortcut step).

## Tech stack

Swift 6 toolchain (**Swift 6 language mode** — strict concurrency, data-race-checked) · SwiftUI · AppIntents · [WhisperKit](https://github.com/argmaxinc/WhisperKit) · CoreML · bundled LGPL ffmpeg · [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (MIT, for the rebindable hotkey)

## Notes

- `ParlaSmoke` is a tiny headless target for sanity-checking the engine
  (`swift run ParlaSmoke <file.wav> openai_whisper-tiny`).
- Rename the app: replace `Parla` in `Package.swift`, the `Sources/Parla` folder name,
  and `build_app.sh`.

## License

MIT — see [LICENSE](LICENSE).
