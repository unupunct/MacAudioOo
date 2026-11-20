#!/bin/bash
# Builds MacAudioOo.app using swiftc directly (works with Command Line Tools only,
# no full Xcode and no SwiftPM manifest support required).
# Usage: scripts/build.sh [debug|release]
# env:   ARCHS="x86_64 arm64" (default: host arch)   MIN_OS=12.0
#        SIGN_IDENTITY="Developer ID Application: ..."  (default: ad-hoc "-")
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
MIN_OS="${MIN_OS:-12.0}"
ARCHS="${ARCHS:-$(uname -m)}"
VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
OPT="-Onone -g"; [ "$CONFIG" = "release" ] && OPT="-O"

OUT="build"; APP="$OUT/MacAudioOo.app"
rm -rf "$APP" "$OUT/obj"; mkdir -p "$OUT/obj" "$APP/Contents/MacOS" "$APP/Contents/Resources"
SOURCES=$(find Sources/MacAudioOo -name '*.swift')

SLICES=()
for a in $ARCHS; do
  # -parse-as-library is required because the target uses @main.
  swiftc $OPT -parse-as-library -module-name MacAudioOo \
    -target "$a-apple-macos$MIN_OS" $SOURCES -o "$OUT/obj/MacAudioOo-$a"
  SLICES+=("$OUT/obj/MacAudioOo-$a")
done
if [ ${#SLICES[@]} -gt 1 ]; then lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/MacAudioOo"
else cp "${SLICES[0]}" "$APP/Contents/MacOS/MacAudioOo"; fi

# App icon: generated from scripts/make-icon.swift if not already present.
if [ ! -f Resources/AppIcon.icns ]; then
  if swiftc -O scripts/make-icon.swift -o "$OUT/make-icon" 2>/dev/null && "$OUT/make-icon" Resources >/dev/null 2>&1 \
     && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns 2>/dev/null; then :; else echo "warning: could not generate AppIcon.icns"; fi
fi
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>MacAudioOo</string>
<key>CFBundleDisplayName</key><string>MacAudioOo</string>
<key>CFBundleIdentifier</key><string>com.unupunct.MacAudioOo</string>
<key>CFBundleExecutable</key><string>MacAudioOo</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
<key>LSApplicationCategoryType</key><string>public.app-category.music</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAudioCaptureUsageDescription</key><string>MacAudioOo captures the audio of the applications you choose so it can change their volume, apply EQ and effects, and record them. Nothing leaves your Mac.</string>
<key>NSMicrophoneUsageDescription</key><string>MacAudioOo does not use the microphone. This text is only shown if macOS asks on behalf of an audio component.</string>
</dict></plist>
PLIST

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"          # ad-hoc: runs locally only
else
  codesign --force --options runtime --timestamp --entitlements Resources/MacAudioOo.entitlements --sign "$SIGN_IDENTITY" "$APP"
fi
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/MacAudioOo")) v$VERSION, minimum macOS $MIN_OS"
