# MarkdownKit Release Test Kit

This file defines the repository commands and runtime evidence required before release work can proceed. Run every command from the repository root. Generated results belong under `.artifacts/`, which is intentionally ignored by Git.

## Static delivery gates

```bash
chmod +x Scripts/check-platform-floors.sh Scripts/assert-xcresult-tests.sh Scripts/Tests/delivery-gates-tests.sh
Scripts/Tests/delivery-gates-tests.sh
Scripts/check-platform-floors.sh
swift test
swift build -c release -Xswiftc -warnings-as-errors
```

`check-platform-floors.sh` requires the Swift package to declare iOS 18.0 and macOS 15.0 and requires the Example Xcode build settings to resolve to the same exact values in Debug and Release.

## iOS 18.0 runtime gate

The machine must have Xcode 26.x, Apple Swift 6.2, the iOS 18.0 simulator runtime, and an `iPhone 16 Pro` device for that runtime.

```bash
set -o pipefail
swift --version | grep -E 'Apple Swift version 6\.2([ .]|$)'
xcodebuild -version | head -1 | grep -E '^Xcode 26([.]|$)'
xcrun simctl list runtimes available | grep -E '^iOS 18\.0 '
mkdir -p .artifacts
HARDENING_RESULT_DIR="$(mktemp -d "$PWD/.artifacts/ios18.XXXXXX")"
xcodebuild test \
  -scheme MarkdownKit-Package \
  -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro' \
  -resultBundlePath "$HARDENING_RESULT_DIR/MarkdownKit-iOS18.xcresult" \
  | tee "$HARDENING_RESULT_DIR/MarkdownKit-iOS18.log"
xcodebuild test \
  -project Example/Example.xcodeproj \
  -scheme Example \
  -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro' \
  -resultBundlePath "$HARDENING_RESULT_DIR/Example-iOS18.xcresult" \
  | tee "$HARDENING_RESULT_DIR/Example-iOS18.log"
HARDENING_ARTIFACTS_DIR="$HARDENING_RESULT_DIR" Scripts/assert-xcresult-tests.sh ios18 \
  "$HARDENING_RESULT_DIR/MarkdownKit-iOS18.xcresult" \
  "$HARDENING_RESULT_DIR/Example-iOS18.xcresult"
```

## macOS 15 runtime gate

This gate must run on the self-hosted GitHub Actions runner labelled `[self-hosted, macOS, ARM64, macos-15, xcode-26]`. A run on a newer macOS release is not equivalent evidence.

```bash
set -o pipefail
sw_vers -productVersion | grep -E '^15\.'
swift --version | grep -E 'Apple Swift version 6\.2([ .]|$)'
xcodebuild -version | head -1 | grep -E '^Xcode 26([.]|$)'
mkdir -p .artifacts
HARDENING_RESULT_DIR="$(mktemp -d "$PWD/.artifacts/macos15.XXXXXX")"
xcodebuild test \
  -scheme MarkdownKit-Package \
  -destination 'platform=macOS' \
  -resultBundlePath "$HARDENING_RESULT_DIR/MarkdownKit-macOS15.xcresult" \
  | tee "$HARDENING_RESULT_DIR/MarkdownKit-macOS15.log"
HARDENING_ARTIFACTS_DIR="$HARDENING_RESULT_DIR" Scripts/assert-xcresult-tests.sh macos15 \
  "$HARDENING_RESULT_DIR/MarkdownKit-macOS15.xcresult"
```

## Artifact schema

Each runtime job uploads its fresh result directory. It contains:

- one `.xcresult` per tested scheme;
- one matching plain-text `.log` per scheme;
- JSON reports extracted by `assert-xcresult-tests.sh` under `xcresult-assert.*`;
- `runtime-metadata.txt` with exactly these keys: `host_os`, `xcode_version`, `swift_version`, `simulator_runtime`, `scheme`, `git_sha`, and `result`.

The checked-in `Tests/runtime-test-manifest.json` is the executable inventory of required targets and cases. The assertion command fails if no tests execute, a required target or case is absent, any test is skipped, or any unexpected failure/unknown result is present. Tasks that add accessibility or Dynamic Type runtime coverage must extend this manifest.
