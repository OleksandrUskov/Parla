#!/usr/bin/env bash
# Собирает Parla.app: release-бинарь + бандл + Info.plist + иконка + ad-hoc подпись.
set -euo pipefail
cd "$(dirname "$0")"

APP="Parla"
# Не менять: к bundle ID привязан грант на уведомления (UNUserNotificationCenter).
# Сменишь — пользователь потеряет разрешение и его спросят заново.
BUNDLE_ID="com.parla.app"
VERSION="1.0.0"

# Сгенерить иконку, если её ещё нет (нужны swift + sips + iconutil — есть на любом маке с Xcode).
if [ ! -f Resources/AppIcon.icns ] && [ -f make_icon.swift ]; then
  echo "• Генерю иконку…"
  mkdir -p Resources
  TMP="$(mktemp -d)"
  if swift make_icon.swift "$TMP/i.png" >/dev/null 2>&1; then
    ISET="$TMP/AppIcon.iconset"; mkdir -p "$ISET"
    for s in 16 32 128 256 512; do
      sips -z "$s" "$s" "$TMP/i.png" --out "$ISET/icon_${s}x${s}.png" >/dev/null 2>&1
      d=$((s * 2)); sips -z "$d" "$d" "$TMP/i.png" --out "$ISET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ISET" -o Resources/AppIcon.icns >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
fi

echo "▶ Сборка $APP (release, via xcodebuild)…"
# Почему xcodebuild, а не `swift build`: MLX (mlx-swift, нужен для on-device LLM-инсайтов) поставляет
# Metal-шейдеры, которые в `default.metallib` компилит ТОЛЬКО Xcode-build-rule. Голый SwiftPM CLI
# линкует нормально, но .app падает в рантайме («Failed to load the default metallib»). xcodebuild
# собирает ТОТ ЖЕ Package.swift (без .xcodeproj) через авто-схему «Parla». Юнит-тесты остаются на
# `swift test` (MLX выключен под XCTest → ни одной Metal-операции). DerivedData кладём под .build/ (gitignored).
DERIVED="$PWD/.build/xcode"
xcodebuild build \
  -scheme "$APP" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO
# -derivedDataPath + -configuration Release (macOS, без суффикса платформы) → путь детерминирован.
BIN="$DERIVED/Build/Products/Release/$APP"
[ -x "$BIN" ] || { echo "❌ нет бинаря $BIN"; exit 1; }

APPDIR="$APP.app"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp "$BIN" "$APPDIR/Contents/MacOS/$APP"

# MLX Metal library: xcodebuild compiles MLX's .metal kernels into mlx-swift_Cmlx.bundle. MLX's loader
# resolves current_binary_dir() via dladdr on its OWN (statically-linked) code → the executable's dir, so
# place the metallib NEXT TO the binary as Contents/MacOS/mlx.metallib (the loader's colocated search path).
# Without it the app crashes on first MLX use: "Failed to load the default metallib". Proven in the P3 spike
# (blueprints/LOCAL_AI_LAYER_P3.md → SPIKE RESULTS). No sidecar bundles are needed.
MLXLIB="$(find "$DERIVED/Build/Products/Release" -name default.metallib -path '*Cmlx*' 2>/dev/null | head -1)"
if [ -n "$MLXLIB" ]; then
  cp "$MLXLIB" "$APPDIR/Contents/MacOS/mlx.metallib"
  echo "• Вшит MLX default.metallib → Contents/MacOS/mlx.metallib"
else
  # HARD fail: without the metallib, MLX aborts via a C++ std::terminate at first use (uncatchable by Swift) —
  # i.e. shipping a broken .app. Every other prerequisite above is fatal too; this must be as well.
  echo "❌ MLX metallib не найден (mlx-swift_Cmlx.bundle/.../default.metallib) — сборка MLX сломана, не отгружаю .app"; exit 1
fi

# SwiftPM RESOURCE BUNDLES: xcodebuild emits one `<Package>_<Target>.bundle` per package that ships resources
# (KeyboardShortcuts, swift-transformers Hub, swift-crypto, mlx Cmlx, …). `Bundle.module` resolves them from the
# app's Contents/Resources at runtime — WITHOUT copying them the FIRST access fatalErrors (EXC_BREAKPOINT). This bit
# us hard: opening Settings builds a KeyboardShortcuts recorder → its Bundle.module → crash. `swift build` resolved
# these implicitly; xcodebuild does not, so the assembler MUST copy them. Copy ALL of them (belt-and-braces).
shopt -s nullglob
for b in "$DERIVED/Build/Products/Release/"*.bundle; do
  # Skip mlx-swift_Cmlx.bundle: its ONLY payload is default.metallib, which we already place colocated as
  # Contents/MacOS/mlx.metallib (the loader's search path #0 — proven self-sufficient in the P3 spike). Avoids
  # shipping the 3.6MB metallib twice.
  case "$(basename "$b")" in
    mlx-swift_Cmlx.bundle) echo "• Пропущен mlx-swift_Cmlx.bundle (metallib уже colocated → без дубля ~3.6MB)"; continue ;;
  esac
  cp -R "$b" "$APPDIR/Contents/Resources/"
  echo "• Вшит ресурс-бандл: $(basename "$b")"
done
shopt -u nullglob

ICON_LINE=""
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APPDIR/Contents/Resources/AppIcon.icns"
  ICON_LINE="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

# Локализации интерфейса (en/ru/uk) → Bundle.main, чтобы рантайм-переключатель языка
# (Localized.setLanguage) находил нужный .lproj. Источник правды — Localization/ в корне репо.
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
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
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
</dict>
</plist>
PLIST

# Ad-hoc подпись — чтобы запускалось локально без «неизвестный разработчик».
# Для UNUserNotificationCenter ad-hoc подписи достаточно при запуске собранного .app;
# уведомления НЕ доставляются при запуске вне бандла (swift run) или из карантина/translocated —
# поэтому в приложении они best-effort, а основной сигнал готовности это чип/прогресс в окне.
# (Audio decode is fully in-process now — libopus + AVAssetReader, no bundled ffmpeg subprocess. Phase 2c.)

# NOTE: ad-hoc, no hardened runtime — fine for local/dev runs and doesn't block exec'ing the helper.
# At the notarization milestone, sign the outer app with a Developer ID + `--options runtime` (and prefer
# explicit per-binary signing over `--deep`, which is unreliable for nested code).
codesign --force --deep --sign - "$APPDIR" >/dev/null 2>&1 || true

echo "✅ Готово: $(pwd)/$APPDIR"

# Опционально перезапустить (--run). Старый и новый бинарь имеют ОДИН bundle ID, поэтому при
# уже запущенном инстансе `open` просто вынесет вперёд СТАРЫЙ процесс из памяти, а не подхватит
# пересобранный файл. Поэтому: закрыть запущенный инстанс, затем открыть свежий.
if [[ " $* " == *" --run "* ]]; then
  if pgrep -x "$APP" >/dev/null; then
    osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1 || true
  fi
  pkill -9 -x "$APP" 2>/dev/null || true
  # дождаться полного выхода старого инстанса, иначе `open` ловит LSOpenURLs -600
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$APP" >/dev/null || break; sleep 0.3; done
  open "$APPDIR"
  echo "↻ Перезапущено: $APPDIR"
fi
