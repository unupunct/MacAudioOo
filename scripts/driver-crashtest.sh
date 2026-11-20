#!/bin/bash
# CRASH / FORCE-QUIT / QUIT-THE-CAPTURED-APP tests with the INSTALLED driver (VLC must be installed).
# Run on the Mac or over ssh after scripts/install-driver.sh and scripts/build.sh release.
#
# It deliberately changes the system output to "MacAudioOo Mixer", plays a quiet tone in VLC, kills MacAudioOo with
# SIGKILL, relaunches it, and quits VLC while MacAudioOo is capturing it. At the end (even on failure, via trap) it
# restores the previous system output, resets the test setting and quits VLC.
#   A  normal quit with "restore previous output on quit" ON puts the previous output back
#   B  force-quit: the captured app keeps running, MacAudioOo comes back and recovers the channel and its audio
#   C  quitting the captured app while MacAudioOo runs removes its channel without a crash
set -uo pipefail
cd "$(dirname "$0")/.."
APP=build/MacAudioOo.app
[ -d "$APP" ] || { echo "Build the app first: scripts/build.sh release"; exit 1; }
RESULT=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; RESULT=1; }
caffeinate -u -t 3 2>/dev/null

query() { pkill -x MacAudioOo 2>/dev/null; sleep 1; rm -f /tmp/maoo-q.txt; open -W "$APP" --args --query-output /tmp/maoo-q.txt; cat /tmp/maoo-q.txt 2>/dev/null; }
PREV="$(query)"
echo "Previous system output: ${PREV:-unknown}"
[ -n "$PREV" ] || { echo "Cannot read the current output; aborting without changes."; exit 1; }

cleanup() {
  pkill -x MacAudioOo 2>/dev/null
  osascript -e 'tell application "VLC" to quit' 2>/dev/null
  defaults delete com.unupunct.MacAudioOo restoreOutputOnQuit 2>/dev/null
  sleep 2; pkill -x VLC 2>/dev/null; pkill -x MacAudioOo 2>/dev/null; sleep 1
  open -W "$APP" --args --set-output "$PREV"
  echo "System output restored to: $(query)  (was: $PREV)"
  rm -f /tmp/maoo-crash-tone.wav
}
trap cleanup EXIT

# ---------- A: normal quit restores the previous output (opt-in setting)
echo "=== A: normal quit with restore-on-quit enabled"
defaults write com.unupunct.MacAudioOo restoreOutputOnQuit -bool true
open -W "$APP" --args --quit-restore-test
AFTER="$(query)"
if [ "$AFTER" = "$PREV" ]; then pass "A: after a normal quit the system output was switched back to the previous device"
else fail "A: system output after quit is '$AFTER', expected '$PREV'"; fi
defaults delete com.unupunct.MacAudioOo restoreOutputOnQuit 2>/dev/null

# ---------- B: force-quit with the driver as system output
echo "=== B: force-quit (SIGKILL) while VLC plays into the driver"
python3 - <<'PY'
import math, struct, wave
w = wave.open("/tmp/maoo-crash-tone.wav", "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(44100)
w.writeframes(b"".join(struct.pack("<h", int(0.08 * 32767 * math.sin(2 * math.pi * 440 * i / 44100))) for i in range(44100 * 120))); w.close()
PY
pkill -x MacAudioOo 2>/dev/null; sleep 1
open -W "$APP" --args --set-output driver
open -a VLC; sleep 4
osascript -e 'tell application "VLC" to open "/tmp/maoo-crash-tone.wav"' >/dev/null
sleep 1
rm -f /tmp/maoo-p1.log /tmp/maoo-p2.log /tmp/maoo-p3.log
open "$APP" --args --probe-log /tmp/maoo-p1.log 0
sleep 9
if tail -2 /tmp/maoo-p1.log | grep -q "VLC:-[0-9]"; then pass "B0: MacAudioOo shows VLC as a channel with signal before the crash: $(tail -1 /tmp/maoo-p1.log | cut -d'|' -f3,4)"
else fail "B0: no VLC channel before the crash: $(tail -1 /tmp/maoo-p1.log)"; fi
pkill -9 -x MacAudioOo; sleep 3
pgrep -x VLC >/dev/null && pass "B1: VLC kept running after MacAudioOo was killed (the driver does not hang its clients)" || fail "B1: VLC died"
echo "(while MacAudioOo is dead the driver device is silent: expected)"
open "$APP" --args --probe-log /tmp/maoo-p2.log 0
sleep 12
if tail -3 /tmp/maoo-p2.log | grep -q "VLC:-[0-9]"; then pass "B2: after relaunch MacAudioOo recovered VLC's channel with live audio: $(tail -1 /tmp/maoo-p2.log | cut -d'|' -f3,4)"
else fail "B2: VLC channel not recovered: $(tail -2 /tmp/maoo-p2.log)"; fi

# ---------- C: quit the captured application while MacAudioOo is running
echo "=== C: quit VLC while MacAudioOo captures it"
osascript -e 'tell application "VLC" to quit'
sleep 5
pgrep -x MacAudioOo >/dev/null && pass "C1: MacAudioOo is still running after the captured app quit" || fail "C1: MacAudioOo crashed"
if tail -2 /tmp/maoo-p2.log | grep -q "n=0"; then pass "C2: VLC's channel was removed: $(tail -1 /tmp/maoo-p2.log | cut -d'|' -f2,3)"
else fail "C2: channel still present: $(tail -1 /tmp/maoo-p2.log)"; fi
LASTSEC=$(tail -1 /tmp/maoo-p2.log | cut -d'|' -f1); sleep 3
NOW=$(tail -1 /tmp/maoo-p2.log | cut -d'|' -f1)
[ "$NOW" -gt "$LASTSEC" ] && pass "C3: MacAudioOo keeps running and reporting normally" || fail "C3: MacAudioOo stopped reporting"

echo "---- summary ----"
[ "$RESULT" -eq 0 ] && echo "ALL PASSED" || echo "SOME FAILED"
