#!/bin/bash
# Removes the MacAudioOo virtual audio driver:  sudo scripts/uninstall-driver.sh
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo:  sudo $0"; exit 1; fi
DEST="/Library/Audio/Plug-Ins/HAL/MacAudioOo.driver"
[ -d "$DEST" ] || { echo "Driver is not installed."; exit 0; }
echo "This removes $DEST."
echo "If 'MacAudioOo Mixer' is your current output device, choose another output in Sound settings first."
read -r -p "Remove the driver? [y/N] " a; [ "$a" = "y" ] || { echo "Cancelled."; exit 0; }
rm -rf "$DEST"
echo "Driver removed."
read -r -p "Restart the audio system now to unload it? [y/N] " a
if [ "$a" = "y" ]; then killall coreaudiod || true; echo "Audio system restarting."
else echo "It stays loaded until you run 'sudo killall coreaudiod' or restart."; fi
