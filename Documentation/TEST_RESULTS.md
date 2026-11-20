# Test results

Environment of every "verified" entry: MacBook Air 7,2 · Intel · **macOS 12.7.6** · Command Line Tools only (Swift 5.7.2, SDK 13.1)
· Built-in Output · release (`-O`) build for anything audio-related. **Debug builds are not usable for audio**: the unoptimized
render callback used 184 % of real time in the same test (the engine's health indicator reports "overloaded").

## Automated tests — `scripts/test.sh` (95 tests, 0 failures)

Compatibility detection for macOS 12–15, settings persistence, mixer (volume, mute, solo, balance, smoothing, master, DIM, MONO,
limiter ceiling, ring buffer), EQ (every band hits its gain ±0.5 dB, stability), compressor, reverb/delay stability, per-channel
independence, groups (mute/solo/gain/link), scenes (CRUD, persistence, apply-to-late-appearing-app), undo/redo, fader taper and
meter ballistics, WAV writer (24-bit bytes, header, crash repair, 44.1→48 kHz conversion), recording library (naming, recovery,
disk space), stem/mix taps (stems are dry and pre-fader), BPM detection (124/90/150/100 BPM, accents and off-beats, phase),
beat grid, crossfader curves, waveform peaks, library (import, metadata, search, sort, favorites, playlists, persistence),
DJ engine rendered offline (crossfader selects decks, gain/filter/EQ, key-lock keeps pitch, sync, hot cues, loops),
application attribution (helper processes -> app) and one-channel-per-app grouping, output restore policy, ducking, launch-at-login plist, log, configuration export/import.

## Real-hardware checks

| Check | Result |
|---|---|
| Engine on Built-in Output (44.1 kHz, 512 frames, ≈17.7 ms latency) | 87 callbacks/s (expected 86); render load 4.5 %, worst block 9.5 % |
| `scripts/engine-smoke.sh`: A lowered 20 dB → A −30.5 dB, B unchanged; mute/solo → −∞; master −12 dB → −12 dB | pass |
| `scripts/driver-selftest.sh`: two fake apps through the real driver code → independent streams (439.8 Hz / 660.2 Hz, exact levels), 48→44.1 kHz resampling, A −12 dB leaves B unchanged | pass |
| `--record-test`: mix + 2 stems from the live engine for 4 s | 3 files of 4.01 s; stem A = dry 440 Hz at 0.300 (its −6 dB fader ignored, as designed); stem B = 1 kHz at 0.200; mix present; 0 dropped frames |
| `--switch-test`: 7 Console↔Classic switches during playback | worst callback-rate deviation 2.1 % — audio not interrupted |
| On-screen rendering of all six screens | screenshots in `docs/screenshots/` |
| App attribution on this Mac: 9 helper processes of the running Chrome resolve (parent-process walk) to one application and one grouping key | pass (`AppIdentityResolver`); helpers whose parent is launchd fall back to the bundle ID the driver reports |

## Real driver, real processes (macOS 12.7.6, driver installed in the live `coreaudiod`) — `scripts/driver-realtest.sh`

Two separate `afplay` processes (440 Hz and 660 Hz) played while the system output was "MacAudioOo Mixer"; MacAudioOo played the
mix through the Built-in Output. **All checks passed** and the previous system output was restored afterwards:

- macOS loaded the driver; "MacAudioOo Mixer" appears as a virtual output device.
- The two processes appeared as **two separate channels**, each at the expected level (−18.4 dB).
- Lowering channel 1 by 20 dB dropped **only its** meter, by exactly 20.0 dB; channel 2 changed by 0.0 dB.
- Mute silenced channel 2 (−120 dB) while channel 1 kept playing; solo of channel 1 silenced channel 2.
- Recording produced **separate stems** (≈444 Hz and ≈666 Hz, peak 0.120 each, 3.02 s, 0 dropped frames) plus the mix.
- Found and fixed with the real driver: ten macOS system helpers (telephony, media-remote, AirPlay…) connect to the virtual device without
  ever playing; they showed up as empty channels. They are now hidden until they send audio (`scripts/driver-selftest.sh` covers this).

Not yet done with the driver: a real GUI application (Safari/YouTube, Music, VLC, Spotify), device hot-plug, and a crash/force-quit.

## Acceptance tests 1 – 16

| # | Test | Status |
|---|---|---|
| 1 | Two applications at once | **Verified with two real processes** (`afplay`) through the real driver in `coreaudiod`; GUI apps such as Safari/Spotify not yet tried |
| 2 | Lower A without changing B | **Verified with real processes** (A −20.0 dB, B 0.0 dB change) |
| 3 | Mute A, B continues | **Verified with real processes** |
| 4 | Solo B | **Verified with real processes** |
| 5 | EQ on A leaves B unaffected | Verified (unit test, per-channel DSP) |
| 6 | Compression on one app | Verified (unit tests + gain-reduction meter on screen) |
| 7 | Master volume | Verified on hardware |
| 8 | Console ↔ Classic without interruption | Verified on hardware |
| 9 | Record two apps to separate WAVs | **Verified with two real processes** (separate stems 444 / 666 Hz); GUI apps pending |
| 10 | Record the stereo mix | Verified on hardware |
| 11 | Load and play two local tracks in DJ | Verified: loaded on screen with real analysis; playback verified by offline render. Audible playback on the speakers not yet checked |
| 12 | Crossfader | Verified (offline render: A only / B only / both) |
| 13 | Disconnect/reconnect an output device | Implemented (falls back to the default, returns when the device returns); **not tested on hardware** |
| 14 | Close an application with an active channel | Implemented (channel removed, recording finalized); **not tested with a real app** |
| 15 | OS compatibility | Detection verified by unit tests for 12/13/14.1/14.2/15; the app itself has only been run on 12.7.6 Intel |
| 16 | Exported files playable and correct | Verified: re-read with AVFoundation (length, level, frequency). Playback through `AVAudioPlayer` on the speakers not yet checked |
