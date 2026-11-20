# Releasing

```bash
scripts/package.sh monterey    # dist/MacAudioOo-<ver>-Monterey.dmg      (macOS 12+, app + optional driver)
scripts/package.sh modern      # dist/MacAudioOo-<ver>-macOS13plus.dmg   (macOS 13+, no driver)
scripts/package.sh all         # both, each with a .sha256
```

Version comes from the `VERSION` file. Default `ARCHS` is `x86_64 arm64` (universal). Every build is **ad-hoc signed** unless you
set `SIGN_IDENTITY`; ad-hoc builds only run cleanly on the Mac that built them.

## Signing and notarization (needs an Apple Developer Program membership)

1. Create a **Developer ID Application** certificate and install it in the keychain.
2. One-time notary credentials:
   `xcrun notarytool store-credentials "MacAudioOo-notary" --apple-id YOU@EXAMPLE.COM --team-id TEAMID`
3. Build, sign, notarize and staple in one go:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=MacAudioOo-notary scripts/package.sh all
```

The app and driver are signed with the hardened runtime (`Resources/MacAudioOo.entitlements` is intentionally empty: no sandbox,
no JIT, no special entitlements). The driver is a user-space HAL plug-in; Apple-silicon Macs refuse unsigned ones.

## What has been verified

Packaging has not yet been run end to end with a real Developer ID. Build scripts were exercised on the Monterey/Intel
development Mac; the Apple-silicon slice is cross-compiled and untested. See TEST_RESULTS.md.

## Publishing to GitHub

Create a release with the two DMGs and their `.sha256` files; the repository About text and a release-notes template are in
`docs/GITHUB_ABOUT.md`. The workflow in `.github/workflows/build.yml` builds, tests and packages on macOS 13/14/15 runners.
