#!/bin/bash
# Runs unit tests via scripts/XCTestShim.swift, which supports the XCTest subset our tests use.
# Needed because the Monterey dev Mac has only a partial Command Line Tools install (no XCTest).
# With full Xcode, `swift test` / xcodebuild can run the same test files natively.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/tests; rm -rf "$OUT"; mkdir -p "$OUT/src"
for f in $(find Sources/MacAudioOo -name '*.swift' ! -name MacAudioOoApp.swift); do cp "$f" "$OUT/src/$(basename "$f")"; done
for f in $(find Tests/MacAudioOoTests -name '*.swift'); do
  sed -e '/@testable import MacAudioOo/d' -e 's/^import XCTest$/import Foundation/' "$f" > "$OUT/src/$(basename "$f")"
done
cp scripts/XCTestShim.swift "$OUT/src/XCTestShim.swift"
CLASSES=$(grep -hoE 'class [A-Za-z0-9_]+: XCTestCase' Tests/MacAudioOoTests/*.swift | awk '{sub(":","",$2); printf "%s.self, ", $2}')
printf 'import Foundation\n@main struct TestMain { static func main() { exit(runAllShimTests([%s])) } }\n' "$CLASSES" > "$OUT/src/TestMain.swift"
swiftc -parse-as-library -module-name MacAudioOoTests -target "$(uname -m)-apple-macos12.0" \
  "$OUT"/src/*.swift -o "$OUT/run-tests"
"$OUT/run-tests"
