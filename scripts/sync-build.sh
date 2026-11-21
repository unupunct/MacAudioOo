#!/bin/bash
# Developer helper: copies the working tree to the test Mac over SSH and builds there.
# Usage: scripts/sync-build.sh [release|debug]
set -uo pipefail
cd "$(dirname "$0")/.."
HOST="${MAC_HOST:-George@192.168.1.28}"
tar --exclude=build --exclude=dist --exclude=.git -cf - Sources Tests scripts Package.swift VERSION Resources Driver 2>/dev/null |
  ssh -o BatchMode=yes "$HOST" 'cd ~/MacAudioOo && rm -rf Sources/MacAudioOo/Views && tar -xf - && echo synced' 2>&1 | grep -v "post-quantum\|store now\|upgraded"
ssh "$HOST" "cd ~/MacAudioOo && scripts/build.sh ${1:-release} 2>&1 | grep -E 'error|Built|built' | head -${LINES_MAX:-60}" 2>&1 | grep -v "post-quantum\|store now\|upgraded"
