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

echo "▶ Сборка $APP (release)…"
swift build -c release --product "$APP"
BIN=".build/release/$APP"
[ -x "$BIN" ] || { echo "❌ нет бинаря $BIN"; exit 1; }

APPDIR="$APP.app"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp "$BIN" "$APPDIR/Contents/MacOS/$APP"

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
  $ICON_LINE
</dict>
</plist>
PLIST

# Ad-hoc подпись — чтобы запускалось локально без «неизвестный разработчик».
# Для UNUserNotificationCenter ad-hoc подписи достаточно при запуске собранного .app;
# уведомления НЕ доставляются при запуске вне бандла (swift run) или из карантина/translocated —
# поэтому в приложении они best-effort, а основной сигнал готовности это чип/прогресс в окне.
# Vendored LGPL ffmpeg (optional) → Contents/Resources/Helpers/ffmpeg, so Telegram Ogg/Opus works
# WITHOUT a user-installed brew ffmpeg. Sign the nested binary BEFORE the outer app (inside-out;
# `--deep` is unreliable for nested executables).
if [ -f "Vendor/ffmpeg/ffmpeg" ]; then
  mkdir -p "$APPDIR/Contents/Resources/Helpers"
  cp "Vendor/ffmpeg/ffmpeg" "$APPDIR/Contents/Resources/Helpers/ffmpeg"
  chmod +x "$APPDIR/Contents/Resources/Helpers/ffmpeg"
  # LGPL 2.1 §6: the license text AND a source/relink notice must travel WITH the binary the end
  # user receives (they get the .app, not the git repo). LICENSE.LGPL = the full license; SOURCE.md =
  # exact version + upstream URL + configure line + reproducible build recipe (the "how to get/relink
  # the source" notice). Without these in the bundle, distributing the static LGPL binary is non-compliant.
  [ -f "Vendor/ffmpeg/LICENSE.LGPL" ] && cp "Vendor/ffmpeg/LICENSE.LGPL" "$APPDIR/Contents/Resources/Helpers/LICENSE.LGPL"
  [ -f "Vendor/ffmpeg/SOURCE.md" ]    && cp "Vendor/ffmpeg/SOURCE.md"    "$APPDIR/Contents/Resources/Helpers/ffmpeg-SOURCE.md"
  codesign --force --options runtime --sign - "$APPDIR/Contents/Resources/Helpers/ffmpeg" >/dev/null 2>&1 || true
  echo "• Вшит LGPL ffmpeg + LICENSE/SOURCE → Helpers/"
fi

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
