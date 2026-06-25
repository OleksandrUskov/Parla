#!/usr/bin/env bash
# Build a minimal LGPL static ffmpeg for Parla and vendor it at Vendor/ffmpeg/ffmpeg.
#
# Why: the headline format (Telegram Ogg/Opus) needs ffmpeg, and Homebrew's ffmpeg is GPL
# (--enable-gpl --enable-libx264) so it can't be bundled. This builds an LGPL-clean static binary
# (--disable-gpl --disable-nonfree) with only the codecs Parla uses, so it can ship inside Parla.app.
#
# Provenance/compliance: see SOURCE.md. Reproducible — re-run to rebuild from the same source.
# Requires: clang, make, pkg-config, and a static libopus (Homebrew: `brew install opus`).
set -euo pipefail
cd "$(dirname "$0")"

FFMPEG_VERSION="${FFMPEG_VERSION:-8.0}"
TARBALL="ffmpeg-${FFMPEG_VERSION}.tar.xz"
SRC="ffmpeg-${FFMPEG_VERSION}"
URL="https://ffmpeg.org/releases/${TARBALL}"

# 1. Fetch source (we configure LGPL-only below).
[ -f "$TARBALL" ] || curl -fL -o "$TARBALL" "$URL"
[ -d "$SRC" ]     || tar xf "$TARBALL"
cd "$SRC"

# 2. Configure: LGPL only, minimal — just what Parla decodes/encodes/muxes.
#    Uses ffmpeg's NATIVE opus decoder (built-in, LGPL) — NOT libopus — so the binary is fully
#    self-contained (no /opt/homebrew dylib to drag along). --disable-autodetect + the explicit
#    --disable-xlib/libxcb/sdl2/videotoolbox stop X11/SDL/VT from creeping in via autodetection.
./configure \
  --disable-gpl --disable-nonfree \
  --disable-shared --enable-static \
  --disable-everything --disable-doc --disable-network --disable-autodetect \
  --disable-programs --enable-ffmpeg \
  --disable-xlib --disable-libxcb --disable-sdl2 \
  --disable-videotoolbox --disable-audiotoolbox --disable-vaapi \
  --enable-swresample \
  --enable-decoder=opus,vorbis,aac,mp3,mp3float,flac,pcm_s16le,pcm_f32le,pcm_s16be \
  --enable-encoder=pcm_s16le,aac \
  --enable-demuxer=ogg,matroska,mov,mp3,flac,wav,aac \
  --enable-muxer=wav,segment,ipod,mp4 \
  --enable-parser=opus,vorbis,aac,flac,mpegaudio \
  --enable-protocol=file,pipe \
  --enable-filter=aresample,aformat,anull

# 3. Build just the ffmpeg binary.
make -j"$(sysctl -n hw.ncpu)" ffmpeg

# 4. Strip + vendor.
strip -x ffmpeg
cp ffmpeg ../ffmpeg
# LGPL text alongside the binary (ffmpeg ships it as COPYING.LGPLv2.1).
cp COPYING.LGPLv2.1 ../LICENSE.LGPL 2>/dev/null || true
cd ..
echo "✅ Vendored: Vendor/ffmpeg/ffmpeg — $(file ffmpeg | cut -d: -f2-)"
echo "   arch: $(lipo -archs ffmpeg 2>/dev/null || echo unknown)"
