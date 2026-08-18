#!/usr/bin/env bash
# Assembles Parla.app: release binary + bundle + Info.plist + icon + ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")"

APP="Parla"
# Do not change: the notification grant (UNUserNotificationCenter) is tied to this bundle ID.
# Changing it makes every existing user lose the permission and be asked again.
BUNDLE_ID="com.parla.app"
# Overridable so a release build can stamp a real version/build without editing the script:
#   PARLA_VERSION=1.1.0 PARLA_BUILD=42 ./build_app.sh
VERSION="${PARLA_VERSION:-1.0.0}"
COPYRIGHT="${PARLA_COPYRIGHT:-Copyright © 2026 Oleksandr Uskov. All rights reserved.}"
BUILD_NUMBER="${PARLA_BUILD:-1}"

# Generate the icon if it is missing (needs swift + sips + iconutil — present on any Mac with Xcode).
# Every step is CHECKED. This used to swallow all three failures and print "✅ Done" over a bundle with no icon,
# which the App Store rejects — and the icon it drew used an SF Symbol, which Apple's SF Symbols licence forbids
# in app icons outright. `make_icon.swift` now rasterises the project's real artwork and exits non-zero if it
# cannot; treat any failure here as fatal rather than shipping an app that silently lost its face.
if [ ! -f Resources/AppIcon.icns ] && [ -f make_icon.swift ]; then
  echo "• Generating the icon…"
  mkdir -p Resources
  TMP="$(mktemp -d)"
  swift make_icon.swift "$TMP/i.png" || { echo "❌ icon render failed"; rm -rf "$TMP"; exit 1; }
  ISET="$TMP/AppIcon.iconset"; mkdir -p "$ISET"
  for s in 16 32 128 256 512; do
    d=$((s * 2))
    sips -z "$s" "$s" "$TMP/i.png" --out "$ISET/icon_${s}x${s}.png" >/dev/null \
      || { echo "❌ icon resize ${s} failed"; rm -rf "$TMP"; exit 1; }
    sips -z "$d" "$d" "$TMP/i.png" --out "$ISET/icon_${s}x${s}@2x.png" >/dev/null \
      || { echo "❌ icon resize ${s}@2x failed"; rm -rf "$TMP"; exit 1; }
  done
  iconutil -c icns "$ISET" -o Resources/AppIcon.icns \
    || { echo "❌ iconutil failed"; rm -rf "$TMP"; exit 1; }
  rm -rf "$TMP"
  [ -s Resources/AppIcon.icns ] || { echo "❌ AppIcon.icns is empty"; exit 1; }
fi

echo "▶ Building $APP (release, via xcodebuild)…"
# Why xcodebuild and not `swift build`: MLX (mlx-swift, which powers the on-device LLM insights) ships Metal
# shaders, and ONLY an Xcode build rule compiles them into `default.metallib`. The bare SwiftPM CLI links fine
# but the .app then dies at runtime with "Failed to load the default metallib". xcodebuild builds the SAME
# Package.swift (no .xcodeproj) through the auto-generated "Parla" scheme. Unit tests stay on `swift test`
# (MLX is disabled under XCTest, so not a single Metal operation runs). DerivedData goes under .build/ (gitignored).
# `--store`: build the OFFICIAL App-Store variant — freemium gate + StoreKit ON, flagged by a `ParlaStoreBuild`
# Info.plist key (read at runtime, so no fragile global compile-condition override). The DEFAULT build OMITS the
# key → the FULL app with NO gate: that's what someone who clones this public repo gets (the self-compiled build
# is the immaterial honor-system "leak"; StoreKit security is Apple-side, not code secrecy). Test with `--store`.
STORE_PLIST=""
if [[ " $* " == *" --store "* ]]; then
  STORE_PLIST="<key>ParlaStoreBuild</key><true/>"
  echo "▶ STORE build: freemium gate ON (Pro + paywall active)"
else
  echo "▶ FULL build: no gate (open-source / dev). Use --store for the gated App-Store variant."
  echo "  ⚠️  NEVER submit THIS variant to an app store. Without the key there is no paywall, no length"
  echo "     cap — and no Restore Purchases button anywhere, because the Settings Pro section keys on the"
  echo "     same flag. Missing restore is an automatic rejection (App Review Guideline 3.1.1)."
fi

DERIVED="$PWD/.build/xcode"
xcodebuild build \
  -scheme "$APP" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO
# -derivedDataPath + -configuration Release (macOS, no platform suffix) makes the product path deterministic.
BIN="$DERIVED/Build/Products/Release/$APP"
[ -x "$BIN" ] || { echo "❌ no binary at $BIN"; exit 1; }

APPDIR="$APP.app"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp "$BIN" "$APPDIR/Contents/MacOS/$APP"

# MLX Metal library: xcodebuild compiles MLX's .metal kernels into mlx-swift_Cmlx.bundle. MLX's loader
# resolves current_binary_dir() via dladdr on its OWN (statically-linked) code → the executable's dir, so
# place the metallib NEXT TO the binary as Contents/MacOS/mlx.metallib (the loader's colocated search path).
# Without it the app crashes on first MLX use: "Failed to load the default metallib". Proven in the P3 spike
# (established by a spike before this shipped). No sidecar bundles are needed.
MLXLIB="$(find "$DERIVED/Build/Products/Release" -name default.metallib -path '*Cmlx*' 2>/dev/null | head -1)"
if [ -n "$MLXLIB" ]; then
  cp "$MLXLIB" "$APPDIR/Contents/MacOS/mlx.metallib"
  echo "• Embedded MLX default.metallib → Contents/MacOS/mlx.metallib"
else
  # HARD fail: without the metallib, MLX aborts via a C++ std::terminate at first use (uncatchable by Swift) —
  # i.e. shipping a broken .app. Every other prerequisite above is fatal too; this must be as well.
  echo "❌ MLX metallib not found (mlx-swift_Cmlx.bundle/.../default.metallib) — the MLX build is broken, refusing to ship the .app"; exit 1
fi

# SwiftPM RESOURCE BUNDLES: xcodebuild emits one `<Package>_<Target>.bundle` per package that ships resources
# (KeyboardShortcuts, swift-transformers Hub, swift-crypto, mlx Cmlx, …). `Bundle.module` resolves them from the
# app's Contents/Resources at runtime — WITHOUT copying them the FIRST access fatalErrors (EXC_BREAKPOINT). This bit
# us hard: opening Settings builds a KeyboardShortcuts recorder → its Bundle.module → crash. `swift build` resolved
# these implicitly; xcodebuild does not, so the assembler MUST copy them. Copy ALL of them (belt-and-braces).
shopt -s nullglob
for b in "$DERIVED/Build/Products/Release/"*.bundle; do
  # Skip mlx-swift_Cmlx.bundle: its ONLY payload is default.metallib, which we already place colocated as
  # Contents/MacOS/mlx.metallib (the loader's search path #0 — proven self-sufficient by that spike). Avoids
  # shipping the 3.6MB metallib twice.
  case "$(basename "$b")" in
    mlx-swift_Cmlx.bundle) echo "• Skipped mlx-swift_Cmlx.bundle (the metallib is already colocated → no ~3.6 MB duplicate)"; continue ;;
  esac
  cp -R "$b" "$APPDIR/Contents/Resources/"
  echo "• Embedded resource bundle: $(basename "$b")"
done
shopt -u nullglob

# In-process Opus decoder frameworks (Phase 2c: the macOS app links opus + ogg for native Ogg/Opus decode,
# replacing the old ffmpeg subprocess). The binary references them via @rpath and the only LC_RPATH is
# @executable_path/../lib → embed the macOS framework slices under Contents/lib, or the .app fails to LAUNCH
# with dyld "Library not loaded: @rpath/opus.framework" (the build SUCCEEDS regardless — this only bites at
# run time, which is why it slipped through until the .app was actually launched). The trailing codesign --deep
# signs them along with the bundle.
mkdir -p "$APPDIR/Contents/lib"
for fw in opus ogg; do
  FWSRC="$DERIVED/Build/Products/Release/$fw.framework"
  if [ -d "$FWSRC" ]; then
    cp -R "$FWSRC" "$APPDIR/Contents/lib/"
    echo "• Embedded framework: $fw.framework → Contents/lib/"
  else
    echo "❌ $fw.framework not found ($FWSRC) — native decode is broken, refusing to ship the .app"; exit 1
  fi
done

ICON_LINE=""
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APPDIR/Contents/Resources/AppIcon.icns"
  ICON_LINE="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

# UI localizations (en/ru/uk) → Bundle.main, so the runtime language switch (Localized.setLanguage) can find
# the right .lproj. The source of truth is Localization/ at the repo root.
if compgen -G "Localization/*.lproj" > /dev/null; then
  cp -R Localization/*.lproj "$APPDIR/Contents/Resources/"
fi

cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <!-- Export compliance. Declared here, as iOS already does, so App Store Connect stops asking on every single
       upload and cannot hold a build in "Missing Compliance". False is the accurate answer: the only cryptography
       in play is HTTPS for the one-time model download plus the hashing swift-transformers uses to verify it,
       both of which are exempt. -->
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <!-- Shown in the About box and expected on a store listing. -->
  <key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string><string>uk</string></array>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.parla.app.url</string>
      <key>CFBundleURLSchemes</key><array><string>parla</string></array>
    </dict>
  </array>
  <key>NSUserActivityTypes</key>
  <array><string>com.parla.viewTranscript</string></array>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Transcribe with Parla</string></dict>
      <key>NSMessage</key><string>transcribeFiles</string>
      <key>NSPortName</key><string>Parla</string>
      <key>NSSendTypes</key><array><string>public.file-url</string><string>NSFilenamesPboardType</string></array>
      <key>NSReturnTypes</key><array/>
    </dict>
  </array>
  <key>NSMicrophoneUsageDescription</key><string>Parla records your microphone only while you are dictating, and transcribes it on-device. Audio never leaves your Mac.</string>
  $ICON_LINE
  $STORE_PLIST
</dict>
</plist>
PLIST

# STORE-FLAG GUARD — assert what the bundle ACTUALLY carries, not what this script meant to write.
# Everything above is unquoted-heredoc shell interpolation, and the one key that decides whether the app
# earns anything is a hand-written string appearing in exactly two places. A typo in the key, a `<string>true
# </string>` instead of `<true/>`, an `$STORE_PLIST` that stops being interpolated — each produces a plausible
# .app that gates nothing, and the first symptom of all three is zero revenue. `plutil -extract … xml1` is
# read back rather than `raw` on purpose: `raw` prints "true" for a STRING too, which is precisely the
# confusion being guarded against.
plutil -lint "$APPDIR/Contents/Info.plist" >/dev/null \
  || { echo "❌ the generated Info.plist is malformed"; exit 1; }
STORE_XML="$(plutil -extract ParlaStoreBuild xml1 -o - "$APPDIR/Contents/Info.plist" 2>/dev/null || true)"
if [ -n "$STORE_PLIST" ]; then
  case "$STORE_XML" in
    *"<true/>"*) echo "• Store-flag guard: ParlaStoreBuild is a real boolean true → gate + paywall ON" ;;
    *) echo "❌ --store was requested, but the bundle does not carry ParlaStoreBuild as a boolean true."
       echo "   Shipping this would be an App Store build with no paywall, no length cap, every Pro"
       echo "   feature free, and no Restore button. Refusing to ship it."; exit 1 ;;
  esac
else
  [ -z "$STORE_XML" ] || { echo "❌ a plain build must not carry ParlaStoreBuild, but it does"; exit 1; }
  echo "• Store-flag guard: no ParlaStoreBuild key → the FULL ungated build, as intended"
fi

# Ad-hoc signature so the app runs locally without the "unidentified developer" gate.
# It is enough for UNUserNotificationCenter when launching the assembled .app; notifications are NOT delivered
# when running outside a bundle (`swift run`) or from quarantine/translocation — which is why they are
# best-effort in the app and the in-window chip/progress is the primary completion signal.
# (Audio decode is fully in-process now — libopus + AVAssetReader, no bundled ffmpeg subprocess. Phase 2c.)
#
# THIS STEP IS FATAL ON FAILURE. On Apple Silicon an unsigned binary does not execute at all, so signing
# decides whether the .app launches. It used to be `codesign … >/dev/null 2>&1 || true` followed by an
# unconditional "✅ Done" — the one step that can break a downloaded app was the one step that could not
# fail the build. Its output is no longer swallowed either.
# NOTE: ad-hoc, no hardened runtime — fine for local/dev runs and doesn't block exec'ing the helper.
# At the notarization milestone, sign the outer app with a Developer ID + `--options runtime` (and prefer
# explicit per-binary signing over `--deep`, which is unreliable for nested code).
codesign --force --deep --sign - "$APPDIR" || { echo "❌ codesign failed — the .app will not launch"; exit 1; }
codesign --verify --deep --strict "$APPDIR" || { echo "❌ signature fails verification — refusing to ship the .app"; exit 1; }

# LAUNCH GUARD: every @rpath dependency must resolve INSIDE the bundle. This is the exact failure we
# shipped once (`1607bd3`): the build succeeded, the .app died at launch with dyld "Library not loaded:
# @rpath/opus.framework" because the frameworks were never embedded. A build-time invariant now.
EXEC="$APPDIR/Contents/MacOS/$APP"
RPATHS="$(otool -l "$EXEC" | awk '/LC_RPATH/{f=1} f && / path /{print $2; f=0}')"
MISSING=0
while read -r dep; do
  [ -n "$dep" ] || continue
  rel="${dep#@rpath/}"
  found=0
  for rp in $RPATHS; do
    cand="${rp/@executable_path/$APPDIR/Contents/MacOS}"
    cand="${cand/@loader_path/$APPDIR/Contents/MacOS}"
    if [ -e "$cand/$rel" ]; then found=1; break; fi
  done
  if [ "$found" -eq 0 ]; then echo "❌ dependency does not resolve inside the bundle: $dep"; MISSING=1; fi
done <<< "$(otool -L "$EXEC" | awk '/@rpath\//{print $1}')"
[ "$MISSING" -eq 0 ] || { echo "❌ the .app will not launch (dyld cannot find its libraries) — refusing to ship"; exit 1; }
echo "• Launch guard: every @rpath dependency resolves inside the bundle"

# App Intents metadata — the ONE thing this hand-assembled bundle was missing that Xcode does for free.
#
# A SwiftPM build never runs `appintentsmetadataprocessor`, so this app shipped for months with no
# Metadata.appintents at all: Shortcuts, Spotlight and Siri could not see a single intent, while the README
# advertised three of them. The Xcode target added for the Mac App Store is what finally surfaced it, and it
# also surfaced an invalid App Shortcut phrase that nothing here could have validated.
#
# It turns out this is fixable rather than a limitation of the script: xcodebuild DOES emit the
# `.swiftconstvalues` the processor needs, they are simply never consumed. So consume them.
#
# FATAL on failure, deliberately. The failure mode being closed here is precisely a feature disappearing in
# silence, and re-introducing that to be polite about a future Xcode changing these flags would be the same
# mistake twice. CI's Xcode lane builds the same intents, so a flag change surfaces there too.
echo "• App Intents metadata…"
AI_TMP="$(mktemp -d)"
ls "$PWD/Sources/Parla"/*.swift > "$AI_TMP/sources.txt"
find "$DERIVED/Build/Intermediates.noindex/Parla.build" -name '*.swiftconstvalues' > "$AI_TMP/consts.txt" 2>/dev/null || true
if [ ! -s "$AI_TMP/consts.txt" ]; then
  rm -rf "$AI_TMP"
  echo "❌ no .swiftconstvalues from the build — App Intents metadata cannot be produced, so Shortcuts/Siri"
  echo "   would silently see nothing. Refusing to ship a bundle whose advertised automation is absent."
  exit 1
fi
xcrun appintentsmetadataprocessor \
  --output "$APPDIR/Contents/Resources" \
  --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
  --module-name Parla \
  --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
  --xcode-version "$(xcodebuild -version | tail -1 | awk '{print $3}')" \
  --platform-family macOS \
  --deployment-target 14.0 \
  --target-triple arm64-apple-macos14.0 \
  --source-file-list "$AI_TMP/sources.txt" \
  --swift-const-vals-list "$AI_TMP/consts.txt" >/dev/null 2>&1 \
  || { rm -rf "$AI_TMP"; echo "❌ appintentsmetadataprocessor failed — Shortcuts/Siri would see nothing"; exit 1; }
rm -rf "$AI_TMP"
[ -s "$APPDIR/Contents/Resources/Metadata.appintents/extract.actionsdata" ] \
  || { echo "❌ Metadata.appintents is empty — the three App Intents would not exist"; exit 1; }
echo "• App Intents: Shortcuts / Spotlight / Siri metadata embedded"


echo "✅ Done: $(pwd)/$APPDIR  (v$VERSION build $BUILD_NUMBER)"

# Optional relaunch (--run). The old and new binaries share ONE bundle ID, so with an instance already
# running `open` would just bring the OLD in-memory process forward instead of picking up the rebuilt file.
# Hence: quit the running instance first, then open the fresh one.
if [[ " $* " == *" --run "* ]]; then
  if pgrep -x "$APP" >/dev/null; then
    osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1 || true
  fi
  pkill -9 -x "$APP" 2>/dev/null || true
  # wait for the old instance to fully exit, otherwise `open` hits LSOpenURLs -600
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$APP" >/dev/null || break; sleep 0.3; done
  open "$APPDIR"
  echo "↻ Relaunched: $APPDIR"
fi
