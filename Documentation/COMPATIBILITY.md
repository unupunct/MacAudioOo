# Compatibility

| macOS | Backend | Per-app capture | Independent per-app volume |
|---|---|---|---|
| 14.2+ | Core Audio Process Taps | Yes | Yes (original output muted, mixed by MacAudioOo) |
| 13.0 – 14.1 | ScreenCaptureKit | Capture only | **No** (cannot silence the original output) |
| 12.x | Optional virtual audio driver | Via routing to the virtual device | Only after the user installs the driver |

Detection logic lives in `AudioEngine/BackendCapability.swift` and is unit tested.
Unsupported features are shown as unavailable in Settings ▸ Audio, never as working.

## Status (Phase 1)

Verified on real hardware: macOS 12.7.6, Intel — builds, launches, 7/7 unit tests pass,
real Core Audio output-device enumeration.

Not yet implemented: capture, routing, mixing, recording, DJ, library, menu bar.
Not yet tested: macOS 13, 14, 15, Apple Silicon.
