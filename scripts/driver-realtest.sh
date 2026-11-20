#!/bin/bash
# REAL-APPLICATION TEST of the INSTALLED driver. Run on the Mac (or over ssh) after scripts/install-driver.sh.
#
# What it does (it deliberately changes your system output and restores it):
#   1. remembers the current system output;
#   2. creates two quiet test tones (440 Hz and 660 Hz, 18 s) and plays them with two separate `afplay` processes
#      while the system output is "MacAudioOo Mixer" -> you will HEAR both tones through your speakers;
#   3. MacAudioOo (in --driver-test mode) checks that they appear as two channels, that volume / mute / solo act on one
#      application only, and that recording gives two separate stems;
#   4. ALWAYS sets the system output back to what it was, even if the test failed.
# Usage: scripts/build.sh release && scripts/driver-realtest.sh
set -uo pipefail
cd "$(dirname "$0")/.."
APP=build/MacAudioOo.app
[ -d "$APP" ] || { echo "Build the app first: scripts/build.sh release"; exit 1; }
rm -f /tmp/maoo-ready /tmp/maoo-report.txt /tmp/maoo-prev-output.txt
caffeinate -u -t 3 2>/dev/null   # audio hardware may refuse to start while the display sleeps

open -W "$APP" --args --query-output /tmp/maoo-prev-output.txt
PREV="$(cat /tmp/maoo-prev-output.txt 2>/dev/null)"
echo "Current system output: ${PREV:-unknown}"

python3 - <<'PY'
import math, struct, wave
for name, f in (("440", 440.0), ("660", 660.0)):
    w = wave.open("/tmp/maoo-tone-%s.wav" % name, "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(44100)
    w.writeframes(b"".join(struct.pack("<h", int(0.12 * 32767 * math.sin(2 * math.pi * f * i / 44100))) for i in range(44100 * 18)))
    w.close()
PY

open -W "$APP" --args --driver-test /tmp/maoo-report.txt --driver-ready /tmp/maoo-ready &
TESTPID=$!
for i in $(seq 1 60); do [ -f /tmp/maoo-ready ] && break; sleep 0.5; done
if [ -f /tmp/maoo-ready ]; then
  echo "Playing two tones from two separate processes..."
  afplay /tmp/maoo-tone-440.wav & P1=$!
  afplay /tmp/maoo-tone-660.wav & P2=$!
fi
# Wait for the test (bounded), then clean up the players.
for i in $(seq 1 120); do kill -0 $TESTPID 2>/dev/null || break; sleep 1; done
kill $P1 $P2 2>/dev/null
pkill -x MacAudioOo 2>/dev/null; sleep 1

# Always restore the previous output.
if [ -n "$PREV" ]; then open -W "$APP" --args --set-output "$PREV"; fi
echo "---- report ----"; cat /tmp/maoo-report.txt 2>/dev/null || echo "(no report written)"
open -W "$APP" --args --query-output /tmp/maoo-after-output.txt
echo "System output now: $(cat /tmp/maoo-after-output.txt 2>/dev/null)  (was: ${PREV:-unknown})"
rm -f /tmp/maoo-tone-440.wav /tmp/maoo-tone-660.wav
