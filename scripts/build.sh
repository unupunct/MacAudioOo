#!/bin/bash
# Builds MacAudioOo.app using swiftc directly (works with Command Line Tools only,
# no full Xcode and no SwiftPM manifest support required).
# Usage: scripts/build.sh [debug|release]
# env: ARCHS="x86_64 arm64" (default: host arch)  MIN_OS=12.0
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
MIN_OS="${MIN_OS:-12.0}"
ARCHS="${ARCHS:-$(uname -m)}"
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

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>MacAudioOo</string>
<key>CFBundleDisplayName</key><string>MacAudioOo</string>
<key>CFBundleIdentifier</key><string>com.unupunct.MacAudioOo</string>
<key>CFBundleExecutable</key><string>MacAudioOo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSMicrophoneUsageDescription</key><string>MacAudioOo uses audio input only when you add a microphone channel.</string>
</dict></plist>
PLIST
# Ad-hoc signature so the bundle launches locally; release signing is separate.
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/MacAudioOo"))"
