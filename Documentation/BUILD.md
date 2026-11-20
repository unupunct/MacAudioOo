# Building MacAudioOo

The app is built with `swiftc` directly (see `scripts/build.sh`), so only the macOS
Command Line Tools are required. `Package.swift` is also provided for use with a full
Xcode / `swift build` where the SwiftPM manifest module is available.

```bash
scripts/build.sh debug              # host architecture
ARCHS="x86_64 arm64" scripts/build.sh release   # universal (needs an SDK/toolchain that can target both)
scripts/test.sh                     # unit tests
```

Output: `build/MacAudioOo.app` (ad-hoc signed; Developer ID signing and notarization are Phase 8).

## More scripts

| Script | Purpose |
|---|---|
| `scripts/build-driver.sh` | builds `build/MacAudioOo.driver` |
| `scripts/driver-selftest.sh` | loads the driver like coreaudiod would; no root, no install |
| `scripts/engine-smoke.sh` | plays two tones through the real output and prints meters |
| `scripts/package.sh monterey`, `modern`, `all` | DMG installers (see RELEASE.md) |
| `scripts/make-icon.swift` | generates the app icon (run automatically by `build.sh`) |

Developer switches of the app itself (not used in normal operation): `--snapshot out.png --tab <tab> [--demo-channels|--demo-dj]`
renders the app window to a PNG and quits; `--record-test result.txt` and `--switch-test result.txt` run the hardware checks
described in TEST_RESULTS.md. **Never judge audio performance on a debug build**: `build.sh debug` is unoptimized and the
render callback is several times too slow.

## Development setup used so far

Source is edited on Windows and synced to a MacBook Air (Intel, macOS 12.7.6, Swift 5.7.2,
Command Line Tools only, SDK 13.1) over SSH, where it is built, tested and launched.

Known toolchain limits on that Mac:

- No Xcode, so the SDK tops out at macOS 13.1. APIs introduced in macOS 14.2
  (Core Audio process taps) cannot be compiled directly there; the tap backend must
  resolve them at runtime or be built on a newer toolchain.
- The Command Line Tools install lacks `PackageDescription` and `XCTest`, so `swift build`
  and `swift test` fail. `scripts/test.sh` runs the tests through `scripts/XCTestShim.swift`.
