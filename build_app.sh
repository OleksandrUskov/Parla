#!/usr/bin/env bash
# Собирает Murmur.app: release-бинарь + бандл + Info.plist + иконка + ad-hoc подпись.
set -euo pipefail
cd "$(dirname "$0")"

APP="Murmur"
BUNDLE_ID="com.murmur.app"
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
  $ICON_LINE
</dict>
</plist>
PLIST

# Ad-hoc подпись — чтобы запускалось локально без «неизвестный разработчик».
codesign --force --deep --sign - "$APPDIR" >/dev/null 2>&1 || true

echo "✅ Готово: $(pwd)/$APPDIR"
