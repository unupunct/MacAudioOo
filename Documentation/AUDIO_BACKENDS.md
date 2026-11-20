# Audio engine and backends

## Engine (implemented, verified on Monterey / Intel / built-in output)

```
capture backend ──write──▶ AudioRingBuffer ──read──▶ RingSource ─┐
generated test tone ───────────────────────────▶ ToneSource ─────┤  (ChannelSource)
                                                                  ▼
                          AudioMixer.render (real-time): per-channel smoothed volume,
                          balance, mute, solo → sum → master volume/mute/DIM/MONO →
                          limiter → meters ──▶ AudioOutput (AUHAL) ──▶ chosen device
```

- Parameters live in engine-owned fixed memory (`AudioMixer.Storage`); the UI writes them and
  the render thread reads them. No locks, no allocation, no Swift collections on the render path.
- The mixer is recreated when the output device or sample rate changes; channels and settings persist.
- Selected output follows hot-plug: if the chosen device disappears the engine falls back to the
  system default (never changing it) and returns when the device is back.
- `scripts/engine-smoke.sh` plays two tones through the real device and prints meter values and
  render-callback counts. Last run (macOS 12.7.6, Built-in Output, 44.1 kHz, 512-frame buffer,
  ≈17.7 ms latency): 86 callbacks/s as expected; lowering A by 20 dB read −30.5 dB on A with B
  unchanged at −10.5 dB; mute and solo reduced the affected channel to −∞; master −12 dB lowered
  the output by ≈12 dB.

Note: audio I/O only starts when the Mac is fully awake. A Mac in dark-wake (e.g. display asleep,
driven over SSH) refuses to start any audio (even `afplay` fails with -66681); use
`caffeinate -u -t 3` first.

## Backends

| Backend | Status |
|---|---|
| Process discovery (`AudioProcessManager`) | Implemented: lists running GUI apps with icon/PID, tears channels down on app quit. Does not yet say which apps are producing sound. |
| Core Audio Process Taps (macOS 14.2+) | **Written, untested.** `CoreAudioTapBackend` polls Core Audio process objects, taps each application that is producing output (muted when tapped), and feeds a ring through `RingResamplerSource`. Symbols are resolved at run time (the Monterey dev Mac has SDK 13.1). Needs a macOS 14.2+ machine to compile against the real SDK and verify. |
| ScreenCaptureKit (macOS 13–14.1) | **Not implemented.** Capture-only by design (cannot silence the original output). |
| Virtual audio driver (macOS 12) | **Implemented, partly verified.** AudioServerPlugIn in `Driver/`, app side in `VirtualDriverBackend` / `DriverSharedMemory`. Verified without installing (`scripts/driver-selftest.sh`): independent per-client streams, correct pitch/level, resampling 48→44.1 kHz, per-channel volume independence. **Not yet verified:** loading in the real coreaudiod and real applications. See `DRIVER.md`. |

Until a backend exists the mixer can only play generated test tones; the UI says so.
