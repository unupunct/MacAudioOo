#!/bin/bash
# Builds a release DMG.
#   scripts/package.sh monterey   -> dist/MacAudioOo-<ver>-Monterey.dmg      (macOS 12+, includes the optional audio driver)
#   scripts/package.sh modern     -> dist/MacAudioOo-<ver>-macOS13plus.dmg   (macOS 13+, native capture, no driver)
#   scripts/package.sh all        -> both
#
# env: ARCHS="x86_64 arm64"            (default: universal)
#      SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   (default: ad-hoc; ad-hoc builds only run on the Mac that built them)
#      NOTARY_PROFILE=<notarytool keychain profile>              (optional: notarize + staple; see scripts/notarize.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
VARIANT="${1:-}"
if [ "$VARIANT" = "all" ]; then "$0" monterey; "$0" modern; exit 0; fi
VERSION="$(cat VERSION)"
ARCHS="${ARCHS:-x86_64 arm64}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
case "$VARIANT" in
  monterey) MIN_OS=12.0; NAME="MacAudioOo-$VERSION-Monterey";     WITH_DRIVER=1 ;;
  modern)   MIN_OS=13.0; NAME="MacAudioOo-$VERSION-macOS13plus";  WITH_DRIVER=0 ;;
  *) echo "usage: $0 monterey|modern|all"; exit 1 ;;
esac

echo "== Building app ($VARIANT, macOS $MIN_OS+, archs: $ARCHS)"
MIN_OS="$MIN_OS" ARCHS="$ARCHS" SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build.sh release

STAGE="build/stage-$VARIANT"
rm -rf "$STAGE"; mkdir -p "$STAGE" dist
cp -R build/MacAudioOo.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

if [ "$WITH_DRIVER" = "1" ]; then
  echo "== Building audio driver"
  MIN_OS=12.0 ARCHS="$ARCHS" SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build-driver.sh
  mkdir -p "$STAGE/Audio Driver (optional)"
  cp -R build/MacAudioOo.driver "$STAGE/Audio Driver (optional)/"
  cp scripts/install-driver.sh scripts/uninstall-driver.sh "$STAGE/Audio Driver (optional)/"
  cat > "$STAGE/Audio Driver (optional)/Install Audio Driver.command" <<'CMD'
#!/bin/bash
# Installs the MacAudioOo audio driver (asks for your administrator password and for confirmation).
DIR="$(cd "$(dirname "$0")" && pwd)"
echo "This installs the MacAudioOo virtual audio driver into /Library/Audio/Plug-Ins/HAL."
sudo "$DIR/install-driver.sh" "$DIR/MacAudioOo.driver"
echo; read -r -p "Press Return to close." _
CMD
  cat > "$STAGE/Audio Driver (optional)/Remove Audio Driver.command" <<'CMD'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
sudo "$DIR/uninstall-driver.sh"
echo; read -r -p "Press Return to close." _
CMD
  chmod +x "$STAGE/Audio Driver (optional)/"*.command "$STAGE/Audio Driver (optional)/"*.sh
fi

if [ "$WITH_DRIVER" = "1" ]; then
cat > "$STAGE/READ ME.txt" <<TXT
MacAudioOo $VERSION - macOS 12 Monterey edition

Install: drag MacAudioOo.app to the Applications folder, then open it.

Per-application volume on macOS 12 - 14.1 needs the optional MacAudioOo audio driver
(folder "Audio Driver (optional)"). It is NOT installed automatically:
  1. Double-click "Install Audio Driver.command", read what it says, and confirm.
     It asks for your administrator password and restarts the audio system (audio pauses for a moment).
  2. Choose "MacAudioOo Mixer" as the output in System Settings > Sound. MacAudioOo never changes it for you.
Without the driver the app still runs, but it cannot capture or control other applications.
To remove the driver later, double-click "Remove Audio Driver.command".

MacAudioOo needs no account and no internet connection, and sends nothing anywhere.
TXT
else
cat > "$STAGE/READ ME.txt" <<TXT
MacAudioOo $VERSION - macOS 13 and later edition

Install: drag MacAudioOo.app to the Applications folder, then open it.

  - macOS 14.2 and later: each application's audio is captured with Core Audio process taps
    (independent volume, EQ, effects and recording). macOS asks for permission the first time.
  - macOS 13 - 14.1: independent per-application volume is not possible without a driver
    (use the macOS 12 edition's driver); the app says so in Settings.

MacAudioOo needs no account and no internet connection, and sends nothing anywhere.
TXT
fi

echo "== Creating $NAME.dmg"
rm -f "dist/$NAME.dmg"
hdiutil create -volname "MacAudioOo" -srcfolder "$STAGE" -ov -format UDZO "dist/$NAME.dmg" >/dev/null
if [ "$SIGN_IDENTITY" != "-" ]; then codesign --force --timestamp --sign "$SIGN_IDENTITY" "dist/$NAME.dmg"; fi
if [ -n "${NOTARY_PROFILE:-}" ]; then scripts/notarize.sh "dist/$NAME.dmg"; fi
( cd dist && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256" )
echo "== Done: dist/$NAME.dmg ($(du -h "dist/$NAME.dmg" | cut -f1))"
[ "$SIGN_IDENTITY" = "-" ] && echo "   Note: ad-hoc signed and not notarized. Other Macs will show a Gatekeeper warning. See Documentation/RELEASE.md."
true
