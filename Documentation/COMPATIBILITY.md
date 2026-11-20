# Compatibility

| macOS | Backend | Per-app capture | Independent per-app volume |
|---|---|---|---|
| 14.2+ | Core Audio Process Taps | Yes | Yes (original output muted, mixed by MacAudioOo) |
| 13.0 – 14.1 | ScreenCaptureKit | Capture only | **No** (cannot silence the original output) |
| 12.x | Optional virtual audio driver | Via routing to the virtual device | Only after the user installs the driver |

Detection logic lives in `AudioEngine/BackendCapability.swift` and is unit tested.
Unsupported features are shown as unavailable in Settings ▸ Audio, never as working.

## Status

Verified on real hardware: macOS 12.7.6, Intel only (see TEST_RESULTS.md). Detection logic for 12, 13, 14.1, 14.2 and 15 is unit
tested; the app has not been run on any other version or on Apple silicon. The macOS 14.2+ process-tap backend is written but has
never been compiled against the 14.2 SDK or run (its symbols are resolved at run time so the binary still loads on macOS 12).
The macOS 12 driver is verified without installation (`scripts/driver-selftest.sh`); loading it into the real `coreaudiod`
is the next hardware test.
