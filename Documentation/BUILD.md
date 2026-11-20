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

## Development setup used so far

Source is edited on Windows and synced to a MacBook Air (Intel, macOS 12.7.6, Swift 5.7.2,
Command Line Tools only, SDK 13.1) over SSH, where it is built, tested and launched.

Known toolchain limits on that Mac:

- No Xcode, so the SDK tops out at macOS 13.1. APIs introduced in macOS 14.2
  (Core Audio process taps) cannot be compiled directly there; the tap backend must
  resolve them at runtime or be built on a newer toolchain.
- The Command Line Tools install lacks `PackageDescription` and `XCTest`, so `swift build`
  and `swift test` fail. `scripts/test.sh` runs the tests through `scripts/XCTestShim.swift`.
