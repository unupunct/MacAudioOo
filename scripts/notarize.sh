#!/bin/bash
# Notarizes and staples a signed DMG.   scripts/notarize.sh dist/MacAudioOo-x.y.z-Monterey.dmg
# One-time setup (needs an Apple Developer Program membership and an app-specific password):
#   xcrun notarytool store-credentials "MacAudioOo-notary" --apple-id YOU@EXAMPLE.COM --team-id TEAMID
# then:  NOTARY_PROFILE=MacAudioOo-notary scripts/notarize.sh <dmg>
set -euo pipefail
DMG="${1:?usage: notarize.sh <dmg>}"
PROFILE="${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile}"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG" || true
echo "Notarized and stapled: $DMG"
