# Contributing

All contributors are welcome. Please use issues and pull requests to contribute to the project. And update [CHANGELOG.md](CHANGELOG.md) when committing.

## Making a change

When you commit a change, please add a note to [CHANGELOG.md](CHANGELOG.md).

## Verifying a change

Everything below is what CI runs, not an approximation of it. Run the static
gates before opening a pull request:

```bash
Scripts/run-static-gates.sh .artifacts/local
```

That is one script rather than six commands because every gate runs even when an
earlier one fails, each writes its own log under the directory you pass, and it
reports the whole set once at the end. It covers:

| Gate | What it catches |
|---|---|
| `Scripts/check-platform-floors.sh` | Sources and `Package.swift` disagreeing about the deployment floor |
| `Scripts/check-image-ownership.sh` | A platform image reachable outside the audited files |
| `Scripts/check-link-activation.sh` | A link activation path that bypasses the policy |
| `swift test` | The whole suite, on macOS |
| `swift build -c release -Xswiftc -warnings-as-errors` | Anything that only fails in release, and every warning |
| `swiftformat --lint .` | Formatting |

Two more static gates are not in that script and are run by CI directly:

```bash
Scripts/check-unchecked-sendable.sh          # only the approved @unchecked adapter exists
Scripts/check-validated-image-construction.sh # no image is built bypassing validation
```

### Runtime evidence

`swift test` runs on macOS, and a number of behaviours only exist on iOS — the
system content-size trait, `UIFontMetrics` per-style scaling, the UIKit
accessibility tree. Those suites are *inert* rather than failing on macOS, so a
green `swift test` is not evidence they ran.

`Tests/runtime-test-manifest.json` is what turns "it ran on iOS" into a checked
claim. Each section names the targets and the individual test cases that must
appear in a result bundle with a nonzero count and zero skips:

```bash
mkdir -p .artifacts
D="$(mktemp -d .artifacts/local-ios18.XXXXXX)"
xcodebuild test -scheme MarkdownKit-Package \
  -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro' \
  -resultBundlePath "$D/MarkdownKit-iOS18.xcresult"
xcodebuild test -project Example/Example.xcodeproj -scheme Example \
  -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro' \
  -resultBundlePath "$D/Example-iOS18.xcresult"

Scripts/assert-xcresult-tests.sh ios18 \
  "$D/MarkdownKit-iOS18.xcresult" "$D/Example-iOS18.xcresult"
Scripts/assert-xcresult-tests.sh ios18-accessibility "$D/MarkdownKit-iOS18.xcresult"
Scripts/assert-xcresult-tests.sh ios18-dynamic-type  "$D/MarkdownKit-iOS18.xcresult"
```

Adding an iOS-only behaviour means adding its test to the matching manifest
section. A test that exists but never runs on the platform it is about protects
nothing.

**Reset the simulator afterwards** if you changed its appearance or text size for
a screenshot:

```bash
xcrun simctl ui <device> appearance light
xcrun simctl ui <device> content_size large
```

`xcodebuild` clones the device and inherits both. A simulator left in dark mode
fails the `RenderMigrationParityTests` fixtures, which record light-mode colors; a
simulator left at an accessibility text size fails `AdaptiveLayoutTests`.

### Tests may not wait on a timer

`RepositoryHygieneTests` fails if any source under `Tests/` calls `Task.sleep`. A
sleep in a test is a bet that the work finishes first, sized for the slowest
machine that will ever run it.

Wait on an event instead. The label views, the render session, the parse executor
and the image resource coordinator each expose a `RenderObservationPoint` that
reports when their observable state can have moved, and test doubles carry an
`EventSignal`:

```swift
await view.settled { view.currentSnapshot != nil }
await loader.events.settled { await loader.calls == 1 }
```

`settled` re-checks its condition on each report, so the wait ends when the work
does. A condition that becomes true with no report *hangs* rather than passing
late — that is deliberate, and each suite's `.timeLimit` turns it into a failure.

## Release process

1. Confirm the build is [passing in GitHub Actions](https://github.com/wxlpp/MarkdownKit/actions)
2. Push a release commit
   1. Create a new Main section at the top
   2. Rename the old Main section like:
          ## [1.0.5](https://github.com/wxlpp/MarkdownKit/releases/tag/1.0.5)
          Released on 2019-10-15.
3. Create a GitHub release
   1. Tag the release (like `1.0.5`)
   2. Paste notes from [CHANGELOG.md](CHANGELOG.md)
