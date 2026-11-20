#!/bin/bash
# Builds build/MacAudioOo.driver (AudioServerPlugIn bundle). Ad-hoc signed by default;
# set SIGN_IDENTITY="Developer ID Application: ..." for a release build.
# env: ARCHS="x86_64 arm64" (default: host arch), MIN_OS=12.0
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHS="${ARCHS:-$(uname -m)}"; MIN_OS="${MIN_OS:-12.0}"
BUNDLE=build/MacAudioOo.driver
rm -rf "$BUNDLE"; mkdir -p "$BUNDLE/Contents/MacOS"
ARCH_FLAGS=""; for a in $ARCHS; do ARCH_FLAGS="$ARCH_FLAGS -arch $a"; done
clang -bundle -Wall -Wextra -Wno-unused-parameter -O2 $ARCH_FLAGS -mmacosx-version-min="$MIN_OS" \
  -framework CoreAudio -framework CoreFoundation \
  Driver/MacAudioOoDriver.c -o "$BUNDLE/Contents/MacOS/MacAudioOoDriver"
cp Driver/Resources/Info.plist "$BUNDLE/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" "$BUNDLE"
plutil -lint "$BUNDLE/Contents/Info.plist" >/dev/null
echo "Built $BUNDLE ($(lipo -archs "$BUNDLE/Contents/MacOS/MacAudioOoDriver"))"
