#!/bin/zsh
# Compila Recorded y crea build/Recorded.app
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
BIN="build/Recorded"
swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macosx14.2" \
  -framework CoreAudio -framework AVFoundation -framework SwiftUI -framework AppKit \
  Sources/Recorded/*.swift -o "$BIN"

APP="build/Recorded.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Recorded"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Recorded</string>
    <key>CFBundleDisplayName</key><string>Recorded</string>
    <key>CFBundleIdentifier</key><string>local.recorded.app</string>
    <key>CFBundleExecutable</key><string>Recorded</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSScreenCaptureUsageDescription</key><string>Recorded necesita capturar el audio que se reproduce en el Mac.</string>
    <key>NSAudioCaptureUsageDescription</key><string>Recorded necesita capturar el audio que se reproduce en el Mac.</string>
</dict>
</plist>
PLIST

# Firma con un certificado estable si existe ("Recorded Dev"), para que macOS
# conserve el permiso de grabación entre compilaciones. Si no, firma ad-hoc.
IDENTITY="${RECORDED_SIGN_IDENTITY:-Recorded Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "Firmado con: $IDENTITY"
else
  codesign --force --deep --sign - "$APP"
  echo "Firmado ad-hoc (crea el certificado \"$IDENTITY\" para no perder el permiso al recompilar)"
fi
echo "Listo: $PWD/$APP"
