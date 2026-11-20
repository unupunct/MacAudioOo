#!/bin/bash
# End-to-end test of the driver WITHOUT installing it (no root, no system changes):
#  1. builds the driver bundle and a host harness that loads it like coreaudiod would;
#  2. the harness plays two tones as two separate "applications" into the driver;
#  3. the app's real shared-memory reader + mixer pull them back out; we check that each
#     application is an independent stream (frequency, level, solo, volume independence).
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-driver.sh >/dev/null
OUT=build/drvtest; rm -rf "$OUT"; mkdir -p "$OUT/src"
clang -O1 -arch "$(uname -m)" -mmacosx-version-min=12.0 -framework CoreAudio -framework CoreFoundation \
  Driver/selftest.c -o "$OUT/selftest"

for f in RingBuffer ChannelSource AudioMixer AudioChannel DriverSharedMemory; do cp Sources/MacAudioOo/AudioEngine/$f.swift "$OUT/src/"; done
cp Sources/MacAudioOo/DSP/Limiter.swift "$OUT/src/"
cat > "$OUT/src/main.swift" <<'SWIFT'
import Foundation
let name = "/MacAudioOo.selftest"
var shm: DriverSharedMemory? = nil
for _ in 0..<60 { shm = DriverSharedMemory(name: name); if shm != nil { break }; usleep(50_000) }
guard let shm = shm else { print("READER FAIL: shared memory not found"); exit(1) }
var slots: [DriverSharedMemory.SlotInfo] = []
for _ in 0..<60 { slots = shm.activeSlots(); if slots.count == 2 { break }; usleep(50_000) }
var failures = 0
func check(_ ok: Bool, _ msg: String) { print((ok ? "PASS " : "FAIL ") + msg); if !ok { failures += 1 } }
check(slots.count == 2, "two active clients seen (\(slots.count))")
check(Set(slots.map { $0.pid }) == [4001, 4002], "client PIDs 4001/4002")
check(Set(slots.map { $0.bundleID }) == ["com.example.appA", "com.example.appB"], "bundle IDs")
check(shm.sampleRate == 48000, "driver rate 48000")
guard slots.count == 2 else { exit(1) }

let outRate = 44100.0   // differs from the driver rate on purpose: exercises resampling
let mixer = AudioMixer(sampleRate: outRate)
mixer.master.pointee.limiterEnabled = false
let sa = slots.first { $0.pid == 4001 }!, sb = slots.first { $0.pid == 4002 }!
for (i, s) in [sa, sb].enumerated() {
    mixer.slots[i] = ChannelState(active: true, volumeTarget: 1, volumeCurrent: 1, balance: 0, mute: false, solo: false,
        peak: 0, rmsSquares: 0, rmsCount: 0, source: Unmanaged.passRetained(DriverSlotSource(shm: shm, slot: s.index, outputRate: outRate)))
}
let block = 512
var l = [Float](repeating: 0, count: block), r = l
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
var tick = 0, t0 = now()
/// Renders `seconds` of audio paced in real time; returns left-channel samples after `skip` seconds.
func capture(_ seconds: Double, skip: Double = 0.4) -> [Float] {
    var out: [Float] = []; let n = Int(seconds * outRate) / block
    for b in 0..<n {
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            mixer.render(frames: block, left: lp.baseAddress!, right: rp.baseAddress!) } }
        if Double(b * block) / outRate >= skip { out += l }
        tick += 1
        let d = t0 + Double(tick * block) / outRate - now(); if d > 0 { usleep(UInt32(d * 1e6)) }
    }
    return out
}
func freq(_ s: [Float]) -> Double {
    var c = 0; for i in 1..<s.count where (s[i - 1] < 0) != (s[i] < 0) { c += 1 }
    return Double(c) / 2 / (Double(s.count) / outRate)
}
func peak(_ s: [Float]) -> Float { s.map { abs($0) }.max() ?? 0 }

_ = capture(0.8)                                   // let both streams prime
mixer.slots[0].solo = true
let a = capture(1.5)
check(abs(freq(a) - 440) < 12, String(format: "app A alone is 440 Hz (measured %.1f)", freq(a)))
check(abs(peak(a) - 0.5) < 0.03, String(format: "app A level 0.5 (measured %.3f)", peak(a)))
mixer.slots[0].solo = false; mixer.slots[1].solo = true
let b = capture(1.5)
check(abs(freq(b) - 660) < 18, String(format: "app B alone is 660 Hz (measured %.1f)", freq(b)))
check(abs(peak(b) - 0.25) < 0.02, String(format: "app B level 0.25 (measured %.3f)", peak(b)))
mixer.slots[1].solo = false
_ = capture(0.5); mixer.slots[0].peak = 0; mixer.slots[1].peak = 0
mixer.slots[0].volumeTarget = dbToLinear(-12)      // lower A only
_ = capture(0.6); mixer.slots[0].peak = 0; mixer.slots[1].peak = 0
_ = capture(0.5)
let pa = linearToDB(mixer.slots[0].peak), pb = linearToDB(mixer.slots[1].peak)
check(abs(pa - (-6.0 - 12)) < 1.0, String(format: "A lowered 12 dB -> %.1f dB (expect ≈ -18)", pa))
check(abs(pb - (-12.0)) < 1.0, String(format: "B unchanged -> %.1f dB (expect ≈ -12)", pb))
let sA = mixer.slots[0].source!.takeUnretainedValue() as! DriverSlotSource, sB = mixer.slots[1].source!.takeUnretainedValue() as! DriverSlotSource
check(sA.underruns <= 2 && sB.underruns <= 2, "no sustained underruns (A \(sA.underruns), B \(sB.underruns))")
print(failures == 0 ? "READER OK" : "READER FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
SWIFT
swiftc -O -module-name DrvTest -target "$(uname -m)-apple-macos12.0" "$OUT"/src/*.swift -o "$OUT/reader"

MAO_SHM_NAME=/MacAudioOo.selftest "$OUT/selftest" build/MacAudioOo.driver/Contents/MacOS/MacAudioOoDriver 9 > "$OUT/driver.log" 2>&1 &
DPID=$!
set +e
"$OUT/reader"; RC=$?
wait $DPID; DRC=$?
cat "$OUT/driver.log"
# remove the test segment (python avoids a C helper)
python3 - <<'PY' 2>/dev/null || true
import ctypes, ctypes.util
libc = ctypes.CDLL(ctypes.util.find_library("c")); libc.shm_unlink(b"/MacAudioOo.selftest")
PY
[ $RC -eq 0 ] && [ $DRC -eq 0 ] && echo "DRIVER SELFTEST PASSED" || { echo "DRIVER SELFTEST FAILED"; exit 1; }
