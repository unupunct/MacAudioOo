#!/bin/bash
# Headless engine smoke test on real hardware: starts the engine on the default output,
# plays two test tones (A=440 Hz on the left-weighted channel, B=660 Hz), exercises
# volume/mute/solo while reading the real meters, and reports render-callback activity.
# You should HEAR the tones. Usage: scripts/engine-smoke.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/smoke; rm -rf "$OUT"; mkdir -p "$OUT/src"
for f in $(find Sources/MacAudioOo -name '*.swift' ! -name MacAudioOoApp.swift ! -path '*Views*' ! -name AppState.swift ! -name AppSettings.swift); do cp "$f" "$OUT/src/$(basename "$f")"; done
cat > "$OUT/src/main.swift" <<'SWIFT'
import Foundation
let devices = AudioDeviceManager()
let engine = AudioEngine()
engine.selectOutput(uid: nil, devices: devices)
print("status:", engine.status)
guard engine.status.isRunning else { exit(2) }
let a = engine.addChannel(name: "A", source: ToneSource(frequency: 440, amplitude: 0.3, sampleRate: Float(engine.sampleRate)))!
let b = engine.addChannel(name: "B", source: ToneSource(frequency: 660, amplitude: 0.3, sampleRate: Float(engine.sampleRate)))!
func meters(_ label: String) {
    Thread.sleep(forTimeInterval: 0.6)                     // let smoothing settle
    _ = a.readMeter(); _ = b.readMeter(); _ = engine.masterMeter()   // drop peaks from before the change
    Thread.sleep(forTimeInterval: 0.8)
    let ma = a.readMeter(), mb = b.readMeter(), m = engine.masterMeter()
    print(String(format: "%@  A %.1f dB  B %.1f dB  master L %.1f R %.1f  callbacks %llu", label, ma.peakDB, mb.peakDB, m.peakL, m.peakR, engine.callbackCount))
}
meters("both playing        ")
a.volumeDB = -20; meters("A lowered to -20 dB")
a.mute = true;   meters("A muted            ")
a.mute = false; b.solo = true; meters("B solo             ")
b.solo = false; engine.masterVolumeDB = -12; meters("master -12 dB       ")
let cb0 = engine.callbackCount; Thread.sleep(forTimeInterval: 1)
print("callbacks in last second:", engine.callbackCount - cb0, "(expected ≈", Int(engine.sampleRate) / Int(max(1, engine.bufferFrames)), ")")
print("counters:", engine.debugCounters)
print("sampleRate", engine.sampleRate, "buffer", engine.bufferFrames, "latency ms", engine.latencyMs)
SWIFT
swiftc -O -module-name Smoke -target "$(uname -m)-apple-macos12.0" "$OUT"/src/*.swift -o "$OUT/smoke"
"$OUT/smoke"
