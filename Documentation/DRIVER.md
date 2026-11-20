# MacAudioOo virtual audio driver (macOS 12 – 14.1)

Monterey has no per-process audio capture API, so MacAudioOo ships an optional,
separately installed **AudioServerPlugIn** (user-space HAL plug-in; no kernel extension).

## How it works

- The driver publishes one stereo output device, **MacAudioOo Mixer** (44.1 / 48 kHz, 32-bit float).
- Every application that plays to it is a separate HAL *client*. The driver copies each
  client's audio into its own ring buffer in POSIX shared memory (`/MacAudioOo.mix`,
  layout in `Driver/MAOShared.h`).
- The MacAudioOo app maps that memory read-only. Each client is attributed to its application (parent-process walk, helper bundle IDs, WebKit services -> Safari) and all clients of one application share ONE mixer channel, so a browser with many tabs is a single strip
  (independent volume, mute, solo, EQ …), then plays the mix to your real output device.
  The driver itself makes no sound: **if MacAudioOo is not running, audio sent to
  "MacAudioOo Mixer" is silent.**
- Sample-rate differences and clock drift between the virtual device and your real device are
  absorbed by a resampler with a fill-level controller (`DriverSlotSource`).
- The app never selects the virtual device as its own output (that would be a feedback loop).

## Limits (honest list)

- You must choose "MacAudioOo Mixer" as the system output yourself (Sound settings).
  MacAudioOo never changes it for you.
- Only applications that use the system default output are captured. Apps that let you pick
  their own output device (some DJ/DAW apps, browsers with a per-site device) are not, unless
  you point them at "MacAudioOo Mixer".
- After a crash or force-quit the system output stays on the (silent) driver device until you pick another output or reopen the
  app and use "Switch system output back" (Settings > Audio, or the menu bar). A normal quit can do it automatically if you enable
  *Restore previous output on quit*; it is off by default because MacAudioOo never changes your output without being asked.
- Hardware volume keys do not control this virtual device; use MacAudioOo's master volume.
- Added latency ≈ driver buffer + ~70 ms of ring fill (tunable, `targetFillFrames`).
- Bluetooth/USB/HDMI outputs work as the *real* output because the app plays through them.

## Install / remove

```bash
scripts/build-driver.sh                  # builds build/MacAudioOo.driver (ad-hoc signed)
sudo scripts/install-driver.sh           # copies it to /Library/Audio/Plug-Ins/HAL, asks before restarting audio
sudo scripts/uninstall-driver.sh         # removes it, asks before restarting audio
```

Installing requires administrator rights and restarting `coreaudiod` (all audio pauses for a moment).
The scripts ask for confirmation before each step. Nothing is installed by the app itself.

### Signing

A locally built, ad-hoc signed driver loads on an Intel Mac for development. A driver distributed
to other people must be signed with a **Developer ID Application** certificate and notarized
(`SIGN_IDENTITY="Developer ID Application: …" scripts/build-driver.sh`). Apple-silicon Macs
running Monterey additionally require a valid signature to load the plug-in.

## Testing

`scripts/driver-selftest.sh` needs no root and installs nothing: it loads the built driver the way
coreaudiod does, plays two tones as two fake applications, and checks through the app's real
shared-memory reader and mixer that each is an independent stream.
**Status:** the driver is installed and verified in the real `coreaudiod` on macOS 12.7.6 / Intel with two real processes (see TEST_RESULTS.md). **Not yet verified:** real GUI applications, device hot-plug while the driver is active, Apple silicon.
