#!/bin/bash
# Installs the MacAudioOo virtual audio driver. Needs administrator rights:
#   sudo scripts/install-driver.sh [path/to/MacAudioOo.driver]
# It never changes your default audio device and asks before restarting the audio system.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo:  sudo $0"; exit 1; fi
cd "$(dirname "$0")/.."
SRC="${1:-build/MacAudioOo.driver}"
DEST_DIR="/Library/Audio/Plug-Ins/HAL"
DEST="$DEST_DIR/MacAudioOo.driver"

[ -d "$SRC" ] || { echo "Driver bundle not found at $SRC (build it with scripts/build-driver.sh)"; exit 1; }
OSMAJ=$(sw_vers -productVersion | cut -d. -f1)
OSMIN=$(sw_vers -productVersion | cut -d. -f2)
if [ "$OSMAJ" -gt 14 ] || { [ "$OSMAJ" -eq 14 ] && [ "$OSMIN" -ge 2 ]; }; then
  echo "This macOS ($(sw_vers -productVersion)) has native process taps; the driver is not needed."
  read -r -p "Install anyway? [y/N] " a; [ "$a" = "y" ] || exit 0
fi
codesign --verify --deep "$SRC" 2>&1 || { echo "Driver bundle signature is invalid"; exit 1; }
SIGNER=$(codesign -dvv "$SRC" 2>&1 | grep -E '^Authority=|Signature=adhoc' | head -1 || true)
echo "Bundle:    $SRC  (${SIGNER:-unsigned})"
echo "Install to: $DEST"
echo "No default audio device or system setting will be changed."
read -r -p "Install the MacAudioOo audio driver? [y/N] " a; [ "$a" = "y" ] || { echo "Cancelled."; exit 0; }

mkdir -p "$DEST_DIR"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
chown -R root:wheel "$DEST"
chmod -R go-w "$DEST"
echo "Driver files installed."

echo
echo "macOS only loads new drivers when the audio system (coreaudiod) restarts."
echo "Restarting it interrupts all audio for a second or two (playback in other apps may need to be resumed)."
read -r -p "Restart the audio system now? [y/N] " a
if [ "$a" = "y" ]; then
  killall coreaudiod || true
  echo "Audio system restarting. 'MacAudioOo Mixer' should appear in Sound settings in a few seconds."
else
  echo "Not restarted. Run 'sudo killall coreaudiod' or restart your Mac when ready."
fi
