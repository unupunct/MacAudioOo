#!/bin/bash
# Developer helper: renders the app's own window (never the screen) for each tab on the test Mac and copies the PNGs here.
# Usage: scripts/snap-all.sh outdir [tab ...]     (default tabs: console eq recording dj classic library presets settings)
set -uo pipefail
cd "$(dirname "$0")/.."
HOST="${MAC_HOST:-George@192.168.1.28}"
OUT="${1:-shots}"; shift || true
TABS="${*:-console eq recording dj classic library presets settings}"
mkdir -p "$OUT"
ssh "$HOST" "cd ~/MacAudioOo && mkdir -p /tmp/rec-demo && for t in $TABS; do (caffeinate -u -t 14 &); sleep 1; extra=''; [ \$t = dj ] && extra='--demo-dj'; [ \$t = eq ] && extra='--select-first';build/MacAudioOo.app/Contents/MacOS/MacAudioOo --snapshot /tmp/shot-\$t.png --tab \$t --demo-channels \$extra --recording-root /tmp/rec-demo --recording-label '~/Music/MacAudioOo' >/dev/null 2>&1; done" 2>&1 | grep -v "post-quantum\|store now\|upgraded"
for t in $TABS; do scp -q "$HOST:/tmp/shot-$t.png" "$OUT/$t.png" 2>&1 | grep -v "post-quantum\|store now\|upgraded"; done
ls "$OUT"
