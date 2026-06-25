# Vendored ffmpeg — provenance & LGPL compliance

Parla bundles a **minimal, LGPL-licensed, static** build of ffmpeg so Telegram's Ogg/Opus voice
messages (and other formats) transcribe out of the box — no `brew install ffmpeg` required.

## What & why
- **Version:** ffmpeg 8.0 — https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz
- **License:** LGPL v2.1+ — built with `--disable-gpl --disable-nonfree`. No GPL codecs
  (x264/x265), no nonfree. The LGPL text ships next to the binary as `LICENSE.LGPL`.
- **Linking / arch:** static (`--enable-static --disable-shared`), arm64 (Apple Silicon) for v1.
  **Self-contained** — depends only on system libs (`/usr/lib`, `/System` frameworks), no
  `/opt/homebrew` dylib, so it runs on any Mac without Homebrew.
- **Codecs (minimal):** decode opus/vorbis/aac/mp3/flac/pcm (ffmpeg's **native opus decoder** — no
  libopus dependency) · encode pcm_s16le + aac · demux ogg/matroska/mov/mp3/flac/wav/aac · mux
  wav/segment/ipod/mp4.

## Reproducing / relinking (the LGPL obligation)
Run `Vendor/ffmpeg/build.sh` — it fetches the exact source, configures LGPL-only with the flags
above, builds, strips, and writes `Vendor/ffmpeg/ffmpeg`. This recipe **+** the upstream source
pointer satisfy the LGPL "means to rebuild/relink" requirement. Requires only `clang` and `make` —
no external codec libs (opus decode is ffmpeg's built-in native decoder).

## How Parla uses it
`build_app.sh` copies `Vendor/ffmpeg/ffmpeg` into `Parla.app/Contents/Resources/Helpers/ffmpeg`
and code-signs it inside-out (before the outer app). `AudioConverter.ffmpegURL()` prefers this
bundled binary, falling back to a system ffmpeg for dev machines / `swift run`.

## Not committed
The build intermediates (`ffmpeg-8.0/`, `*.tar.xz`) are gitignored; only `ffmpeg` (the binary),
`build.sh`, `LICENSE.LGPL`, and this file are vendored.
