# MarkdownKit Library Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver MarkdownKit 0.2.0 with bounded and cancellable rendering work, near-linear safe streaming, secure opt-in remote images, exact copying, structured accessibility, Dynamic Type, lower platform floors, and enforceable delivery gates.

**Architecture:** Keep `MarkdownCore` as immutable IR and parsing logic, introduce a bounded process-wide cmark executor plus a session-owned orchestration layer in `MarkdownPlatformView`, and split rendering into a `Sendable` display model followed by `@MainActor` platform materialization. Resource work remains session-owned while shared actors grant hard budgets and completed-result caches use explicit configuration namespaces and residency leases.

**Tech Stack:** Swift 6.2, SwiftPM, swift-markdown/cmark, TextKit 2, SwiftUI, UIKit, AppKit, ImageIO, URLSession, Swift Testing, XCTest UI tests, SwiftFormat, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-07-library-hardening-design.md`

## Global Constraints

- Target iOS 18 and macOS 15 in the package, Example app, and test hosts; release evidence must execute on the actual minimum runtimes.
- Treat `Markdown.Document(parsing:)` as synchronous and non-cancellable; at most two cmark calls process-wide and one per session token.
- Keep remote images disabled until host opt-in; the default loader is HTTPS-only, isolated from ambient credentials/cookies/cache, limited to 20 MiB per response, 40 MP source metadata, 4,096 px per output side, and 64 MiB accounted decoded pixels per image.
- Enforce 80 MiB upfront encoded reservations, 192 MiB hard accounted decoded-pixel residency, and a 128 MiB completed-cache ownership sublimit.
- Normal Copy returns exact selected semantic text; source recovery is a distinct localized Copy Markdown Source action.
- Do not pass UIKit/AppKit/TextKit objects across actors in public unchecked containers. Public mutable `@unchecked Sendable` contracts must be removed.
- Before writing code against swift-markdown, ImageIO, URLSession, UIKit, or AppKit APIs, use the `context7-mcp` skill for current primary documentation and record the consulted API in the task notes.
- Every implementation task follows red → green → refactor, ends in a focused commit, and is reviewed with `superpowers-reviewer`; process feedback through `superpowers:receiving-code-review` before continuing.
- Run focused tests after each green step. At each checkpoint run `swift test`, the relevant iOS build/test command, and `swift build -c release -Xswiftc -warnings-as-errors` where the platform permits.
- Preserve unrelated user changes. Start execution in an isolated worktree using `superpowers:using-git-worktrees`.

## File and Interface Map

| Area | Files | Responsibility |
|---|---|---|
| Delivery | `Package.swift`, `.swiftformat`, `.github/workflows/ci.yml`, `RTK.md`, Example project | Platform floors, formatting, CI, real-runtime verification |
| Core parsing | `DocumentParser.swift`, `MathScanner.swift`, new `IncrementalParseState.swift`, `ParseWorkMetrics.swift` | IR parsing, conservative fallback, cancellation checks, deterministic work counters |
| Render boundary | new `RenderInput.swift`, `RenderDisplayModel.swift`, `ResolvedResource.swift`, `RenderSnapshot.swift`, `RenderConfiguration.swift`, `RenderPreparer.swift`, `RenderMaterializer.swift`, `AccessibilityNode.swift`; later retire legacy `AttributedStringRenderer.swift`; modify `RenderStyle.swift` and math/SVG protocols | Pure background preparation and main-actor platform materialization |
| Session | new `ParseExecutor.swift`, `MarkdownRenderSession.swift`, `RenderSessionTypes.swift` | Revisions, coalescing, tombstones, task ownership, publication |
| Resources | new `ResourceConfiguration.swift`, `MarkdownImageLoader.swift`, `ImageResourceCoordinator.swift`, `ImageResidencyLedger.swift`, `MarkdownLinkPolicy.swift`; refactor math/SVG coordinators | Configuration generations, secure transport, permits, caches, leases, activation |
| Platform views | split `MarkdownLabelView.swift` into shared session bridge plus `MarkdownLabelView+iOS.swift`, `MarkdownLabelView+macOS.swift`, `MarkdownTextInput+iOS.swift`, `MarkdownSelection.swift`, `MarkdownTableOverlay.swift` | TextKit setup and native platform behavior only |
| Semantics | new `AccessibilityNode.swift`, `MarkdownAccessibility+iOS.swift`, `MarkdownAccessibility+macOS.swift`, `MarkdownCopyResult.swift` | Semantic tree, stable lineage, platform exposure, exact/source copy |
| SwiftUI/API | `MarkdownText.swift`, `MarkdownStreamingText.swift`, renderer modifiers; new image/link modifiers | High-level immutable configuration |
| Tests | focused suites named in each task plus Example UI tests | Behavior, lifecycle, budgets, accessibility, runtime gates |
| Docs/resources | README, CHANGELOG, CONTRIBUTING, DocC comments, `Resources/*/Localizable.strings` | 0.2.0 migration, security/privacy, commands, localized actions |

---

### Task 1A: Apply the dedicated mechanical formatting baseline

**Files:**
- Modify: tracked Swift files under `Package.swift`, `Sources/`, `Tests/`, `Example/Sources/`, `Example/ExampleTests/`, and `Example/ExampleUITests/`

**Interfaces:**
- Consumes: current source behavior.
- Produces: one formatter-only commit that later diffs can review semantically.

- [ ] **Step 1: Record the failing lint result**

```bash
swiftformat --lint Package.swift Sources Tests Example/Sources Example/ExampleTests Example/ExampleUITests
```

Expected: nonzero exit with the audited formatting violations.

- [ ] **Step 2: Apply only SwiftFormat's mechanical rewrite**

```bash
swiftformat Package.swift Sources Tests Example/Sources Example/ExampleTests Example/ExampleUITests
```

Do not change `.swiftformat`, declarations, tests, deployment targets, or behavior in this task.

- [ ] **Step 3: Verify behavior and commit only formatting**

```bash
swiftformat --lint Package.swift Sources Tests Example/Sources Example/ExampleTests Example/ExampleUITests
swift test
swift build -c release -Xswiftc -warnings-as-errors
xcodebuild build -scheme MarkdownKit -destination 'generic/platform=iOS Simulator'
git diff --check
git add Package.swift Sources Tests Example/Sources Example/ExampleTests Example/ExampleUITests
git commit -m "style: establish SwiftFormat baseline"
```

- [ ] **Step 4: Review Task 1A**

Dispatch `superpowers-reviewer` over only this commit and require formatter-only changes, passing existing tests, and no semantic/manual edits.

### Task 1B: Establish platform, CI, test, and repository-command gates

**Files:**
- Modify: `Package.swift`
- Modify: `.gitignore`
- Create: `.github/workflows/ci.yml`
- Create: `Scripts/check-platform-floors.sh`
- Create: `Scripts/assert-xcresult-tests.sh`
- Create: `Tests/runtime-test-manifest.json`
- Create: `RTK.md`
- Modify: `Example/Example.xcodeproj/project.pbxproj`
- Replace: `Example/ExampleTests/ExampleTests.swift`
- Replace: `Example/ExampleUITests/ExampleUITests.swift`

**Interfaces:**
- Consumes: real schemes `MarkdownKit-Package`, `MarkdownKit`, `MarkdownMath`, and `Example`.
- Produces: iOS 18/macOS 15 targets, non-template smoke tests, deterministic floor checks, an explicit runtime test manifest, xcresult execution assertions, and mandatory actual-runtime CI evidence.

- [ ] **Step 1: Record missing delivery gates**

```bash
test -f RTK.md
test -f .github/workflows/ci.yml
test -x Scripts/check-platform-floors.sh
```

Expected: all three checks fail before the files are created.

- [ ] **Step 2: Lower package and Example deployment targets**

Set `platforms: [.iOS(.v18), .macOS(.v15)]`, `IPHONEOS_DEPLOYMENT_TARGET = 18.0`, and `MACOSX_DEPLOYMENT_TARGET = 15.0`. Implement `check-platform-floors.sh` to parse `swift package dump-package` and the Xcode build settings, failing unless all exact floors match.

Add `.artifacts/` to `.gitignore`; all local/CI result bundles and extracted test reports go there and never dirty the release worktree.

- [ ] **Step 3: Replace empty tests with executable smoke assertions**

Make the Example unit test parse `# Smoke` and assert one heading. Give the root demo `markdownkit.example.root` and make the UI test launch and locate it. Run the two focused test commands and expect PASS.

Create `Tests/runtime-test-manifest.json` as the checked-in test plan for both runtime jobs. It names the required targets (`MarkdownKitTests`, `MarkdownMathTests`, `ExampleTests`, `ExampleUITests`) and required platform behavior suites/cases, initially including smoke tests and later extended by Tasks 10/11 with accessibility and Dynamic Type cases. `Scripts/assert-xcresult-tests.sh <manifest-section> <xcresult...>` reads `xcrun xcresulttool get test-results tests`, fails on zero executed tests, missing required target/case names, skips, or unexpected failures, and prints the observed counts/names into evidence.

- [ ] **Step 4: Add mandatory actual-runtime CI**

Use a self-hosted runner labelled `[self-hosted, macOS, ARM64, macos-15, xcode-26]` for the macOS 15 job. Before testing, require `sw_vers -productVersion` to start with `15.`, `swift --version` to report 6.2, and selected Xcode to report 26.x. For iOS, require `xcrun simctl list runtimes available` to contain iOS 18.0 and run both package and Example schemes on `iPhone 16 Pro,OS=18.0`, each with a deterministic `-resultBundlePath`. Run `assert-xcresult-tests.sh ios18` over both result bundles. The macOS 15 job likewise saves a result bundle and checks the `macos15` manifest section. A missing label/runtime, required case, or zero execution count fails; no job uses `continue-on-error`.

Each runtime job writes `runtime-metadata.txt` containing `host_os`, `xcode_version`, `swift_version`, `simulator_runtime`, `scheme`, `git_sha`, and `result`, and uploads it together with `.xcresult`/test logs. `RTK.md` documents identical local/VM commands and the artifact schema.

- [ ] **Step 5: Run the green delivery gate and commit**

```bash
chmod +x Scripts/check-platform-floors.sh Scripts/assert-xcresult-tests.sh
mkdir -p .artifacts
HARDENING_RESULT_DIR="$(mktemp -d .artifacts/platform-gate.XXXXXX)"
Scripts/check-platform-floors.sh
swift test
swift build -c release -Xswiftc -warnings-as-errors
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro' -resultBundlePath "$HARDENING_RESULT_DIR/MarkdownKit-iOS18.xcresult"
xcodebuild test -project Example/Example.xcodeproj -scheme Example -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro' -resultBundlePath "$HARDENING_RESULT_DIR/Example-iOS18.xcresult"
Scripts/assert-xcresult-tests.sh ios18 "$HARDENING_RESULT_DIR/MarkdownKit-iOS18.xcresult" "$HARDENING_RESULT_DIR/Example-iOS18.xcresult"
git add .gitignore Package.swift .github/workflows/ci.yml Scripts/check-platform-floors.sh Scripts/assert-xcresult-tests.sh Tests/runtime-test-manifest.json RTK.md Example
git commit -m "ci: enforce MarkdownKit minimum runtimes"
```

The macOS 15 CI run must finish and upload matching metadata before Task 1B is marked complete; running on the current macOS 26 workstation is not substitute evidence.

- [ ] **Step 6: Review checkpoint 1**

Dispatch `superpowers-reviewer` over Task 1B and require exact floor assertions, real-runtime metadata, non-optional jobs, non-template tests, and reproducible `RTK.md` commands.

### Task 2: Introduce immutable render boundaries with compatibility

**Files:**
- Create: `Sources/MarkdownRenderKit/RenderConfiguration.swift`
- Create: `Sources/MarkdownRenderKit/RenderInput.swift`
- Create: `Sources/MarkdownRenderKit/RenderDisplayModel.swift`
- Create: `Sources/MarkdownRenderKit/ResolvedResource.swift`
- Create: `Sources/MarkdownRenderKit/RenderSnapshot.swift`
- Create: `Sources/MarkdownRenderKit/RenderPreparer.swift`
- Create: `Sources/MarkdownRenderKit/RenderMaterializer.swift`
- Create: `Sources/MarkdownRenderKit/AccessibilityNode.swift`
- Modify: `Sources/MarkdownRenderKit/RenderStyle.swift`
- Modify: `Sources/MarkdownRenderKit/MathRendering.swift`
- Modify: `Sources/MarkdownRenderKit/SVGBlockRendering.swift`
- Modify: `Sources/MarkdownKit/MarkdownText.swift`
- Modify: `Sources/MarkdownKit/MarkdownEditor.swift`
- Test: `Tests/MarkdownKitTests/RenderIsolationTests.swift`
- Test: `Tests/MarkdownKitTests/RenderConfigurationTests.swift`
- Create: `Tests/CompileFail/PlatformStateRequiresMainActor.swift`
- Create: `Scripts/check-api-isolation.sh`

**Interfaces:**
- Consumes: `MarkdownDocument`, `BlockNode`, existing style values.
- Produces: `RenderConfigurationSnapshot`, `RenderInput`, `RenderDisplayModel`, and `@MainActor RenderSnapshot`; Task 3 session depends on these exact types.

- [ ] **Step 1: Write compile-time isolation and value-semantic tests**

Define tests that pass `RenderInput` and `RenderDisplayModel` through `Task.detached` as `Sendable`, mutate a source `RenderStyle` after snapshot creation, and assert the snapshot remains unchanged. Wrap two custom styles independently and prove they get different IDs/cache namespaces by default; prove sharing happens only with the same explicit semantic ID. Add a main-actor test proving `RenderSnapshot` owns platform attributed content. Add a negative typecheck fixture that synchronously reads `snapshot.attributedString` inside a detached closure; `Scripts/check-api-isolation.sh` succeeds only when `swiftc -typecheck -strict-concurrency=complete` rejects that access with a main-actor isolation diagnostic. A positive fixture performs the same read through `await MainActor.run`.

Run:

```bash
swift test --filter 'RenderIsolationTests|RenderConfigurationTests'
```

Expected: FAIL because the new types and snapshot API do not exist.

- [ ] **Step 2: Define immutable cross-actor inputs and pure display output**

Implement the core signatures:

```swift
public struct ColorToken: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double
}

public struct ColorTokens: Sendable, Equatable {
    public let body: ColorToken
    public let secondary: ColorToken
    public let code: ColorToken
    public let link: ColorToken
}

public enum MarkdownTextRole: Hashable, Sendable {
    case body, code, heading(level: Int), listMarker, table, caption
}

public struct TypographyTokens: Sendable, Equatable {
    public let pointSizes: [MarkdownTextRole: Double]
    public let usesPreferredMetrics: Bool
}

public struct SpacingTokens: Sendable, Equatable {
    public let paragraph: Double
    public let block: Double
    public let codeInsets: Double
}

public struct MarkdownConfigurationID: Hashable, Sendable {
    public let rawValue: String
    private init(rawValue: String) { self.rawValue = rawValue }
    public static func uniqueInstance() -> Self { Self(rawValue: "instance:\(UUID().uuidString)") }
    public static func semantic(namespace: String, version: UInt) -> Self {
        Self(rawValue: "semantic:\(namespace):\(version)")
    }
}

public struct RenderConfigurationSnapshot: Sendable, Equatable {
    public let id: MarkdownConfigurationID
    public let typography: TypographyTokens
    public let colors: ColorTokens
    public let spacing: SpacingTokens
    public let generation: UInt64
}

@MainActor
public struct MarkdownRenderConfiguration {
    package let style: RenderStyle
    public let configurationID: MarkdownConfigurationID

    public init(
        style: RenderStyle,
        configurationID: MarkdownConfigurationID = .uniqueInstance()
    )
}

public struct RenderInput: Sendable {
    public let document: MarkdownDocument
    public let source: String?
    public let availableWidth: Double
    public let configuration: RenderConfigurationSnapshot
    public let placeholderMode: PlaceholderMode
}

public struct RenderDisplayModel: Sendable, Equatable {
    public let runs: [DisplayRun]
    public let blocks: [DisplayBlock]
    public let resources: [UnresolvedResource]
    public let accessibility: AccessibilityTree
}

public struct ResourceID: Hashable, Sendable { public let rawValue: String }

public enum UnresolvedResource: Sendable, Equatable {
    case image(id: ResourceID, source: String, alt: String?)
    case math(id: ResourceID, latex: String, display: Bool)
    case svg(id: ResourceID, source: String)
}

public struct DisplayRun: Sendable, Equatable {
    public let text: String
    public let role: MarkdownTextRole
    public let sourceRange: MarkdownSourceRange?
    public let resourceID: ResourceID?
}

public struct DisplayBlock: Sendable, Equatable {
    public let lineage: UInt64
    public let runs: [DisplayRun]
    public let sourceRange: MarkdownSourceRange?
}

public enum AccessibilityRole: Hashable, Sendable {
    case text, heading(level: Int), listItem, link, image, math, code
    case table, row, columnHeader, rowHeader, cell
}

public struct AccessibilityNodeID: Hashable, Sendable {
    public let sourceGeneration: UInt64
    public let role: AccessibilityRole
    public let startAnchor: Int
    public let lineage: UInt64
}

public enum AccessibilityActivation: Sendable, Equatable {
    case link(URL, sessionGeneration: UInt64)
}

public struct AccessibilityTree: Sendable, Equatable {
    public let roots: [AccessibilityNode]
}

public struct AccessibilityNode: Sendable, Equatable {
    public let id: AccessibilityNodeID
    public let role: AccessibilityRole
    public let label: String?
    public let sourceRange: MarkdownSourceRange?
    public let children: [AccessibilityNode]
    public let activation: AccessibilityActivation?
}

@MainActor
package struct ResolvedResourceSnapshot {
    package let values: [ResourceID: ResolvedPlatformResource]
}

@MainActor
package protocol ResourceResidencyOwner: AnyObject {}

@MainActor
package final class LegacyResourceOwner: ResourceResidencyOwner {
    package let retainedObject: AnyObject
    package init(retaining object: AnyObject)
}

package struct ImmutableCGImageBacking: @unchecked Sendable {
    package let frames: [CGImage]
    package let accountedPixelBytes: Int
}

@MainActor
package enum ResolvedPlatformResource {
    case image(PlatformImage, owner: any ResourceResidencyOwner)
    case math(image: PlatformImage, baselineOffset: Double, owner: any ResourceResidencyOwner)
    case svg(PlatformImage, owner: any ResourceResidencyOwner)
}

@MainActor
public final class RenderSnapshot {
    public let attributedString: NSAttributedString
    public let displayModel: RenderDisplayModel
    package let resourceOwners: [any ResourceResidencyOwner]
}
```

Use numeric RGBA/color tokens and named typography roles off-main; resolve `UIFont`/`NSFont`, platform colors, attachments, and TextKit objects only during main-actor materialization.

`ImmutableCGImageBacking` is the only unchecked adapter planned for 0.2.0. Its initializer validates that every Core Graphics frame is immutable/read-only after construction; concurrency tests exercise repeated cross-actor reads and all platform-image creation remains in `RenderMaterializer` on `MainActor`.

`MarkdownRenderConfiguration` owns cache identity rather than trusting a custom `RenderStyle` to report one. Each custom wrapper gets `.uniqueInstance()` by default; only an explicit caller-supplied semantic ID may share completed entries. Built-in configurations derive a deterministic semantic ID from every normalized style token. Define `LegacyResourceOwner` in `ResolvedResource.swift` as a temporary main-actor retention adapter introduced for Task 4B. Task 4C replaces its math/SVG uses with explicit rendered-resource leases; remote images continue using it until Task 7 installs budgeted image leases and deletes the adapter.

Run `swift test --filter RenderConfigurationTests`; expected PASS for immutable snapshots while compatibility consumers still compile.

- [ ] **Step 3: Add immutable preparation/materialization beside the legacy renderer**

Introduce new types without changing existing consumers:

```swift
public struct RenderPreparer: Sendable {
    public init(configuration: RenderConfigurationSnapshot)
    public func prepare(_ input: RenderInput) throws -> RenderDisplayModel
}

@MainActor
package struct RenderMaterializer {
    package init(configuration: RenderConfigurationSnapshot)
    @MainActor
    package func materialize(
        _ model: RenderDisplayModel,
        resources: ResolvedResourceSnapshot
    ) -> RenderSnapshot
}
```

Keep the current `AttributedStringRenderer`, its cache/generation properties, its `@unchecked Sendable`, `RenderStyle` conformance, and glyph producer signatures unchanged in this checkpoint so every existing consumer remains green. Mark the legacy surface deprecated only after Task 4B moves view rendering to `RenderPreparer`/`RenderMaterializer`. Task 4C then deletes the old surface and replaces platform-image-bearing cross-actor glyphs with immutable encoded/vector descriptions or the audited adapter.

Replace underscored umbrella re-exports with Swift 6 access-level imports:

```swift
public import MarkdownCore
public import MarkdownPlatformView
public import MarkdownRenderKit
```

Add temporary `MathRendererConfiguration` and `SVGRendererConfiguration` wrappers whose initializers assign `.uniqueInstance()` by default and accept an explicit semantic ID for intentional completed-cache sharing. Do not take identity from custom renderer protocols or `ObjectIdentifier`. Task 4C makes these wrappers the only configuration entry points, gives built-in configurations deterministic IDs derived from all normalized settings, and either isolates producer mutation in an actor/lock-backed private box with a documented invariant or removes the conformance.

```swift
public struct MathRendererConfiguration: Sendable {
    package let renderer: any MathRendering
    public let configurationID: MarkdownConfigurationID
    public init(
        renderer: any MathRendering,
        configurationID: MarkdownConfigurationID = .uniqueInstance()
    )
}

public struct SVGRendererConfiguration: Sendable {
    package let renderer: any SVGBlockRendering
    public let configurationID: MarkdownConfigurationID
    public init(
        renderer: any SVGBlockRendering,
        configurationID: MarkdownConfigurationID = .uniqueInstance()
    )
}
```

Run `swift test --filter RenderIsolationTests` and `bash Scripts/check-api-isolation.sh`; expected PASS before style conversion.

- [ ] **Step 4: Add explicit style snapshot conversion without changing legacy isolation**

Add an `@MainActor snapshot(generation:) -> RenderConfigurationSnapshot` conversion that copies every platform font/color into immutable tokens. Keep the legacy `RenderStyle` and `AttributedStringRenderer` isolation declarations until Task 4C deletes their mutable cross-actor use. Document that custom fixed fonts opt out of automatic scaling until Task 11 applies the scaling helper.

- [ ] **Step 5: Run focused and regression tests, then commit**

```bash
swift test --filter 'RenderIsolationTests|RenderConfigurationTests|MarkdownRenderKitTests|MathRenderingTests|SVGBlockRenderingTypesTests'
chmod +x Scripts/check-api-isolation.sh
Scripts/check-api-isolation.sh
swift build -c release -Xswiftc -warnings-as-errors
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
git add Sources/MarkdownRenderKit Sources/MarkdownKit/MarkdownText.swift Sources/MarkdownKit/MarkdownEditor.swift Tests/MarkdownKitTests/RenderIsolationTests.swift Tests/MarkdownKitTests/RenderConfigurationTests.swift Tests/CompileFail/PlatformStateRequiresMainActor.swift Scripts/check-api-isolation.sh
git commit -m "refactor: make render boundaries actor-safe"
```

- [ ] **Step 6: Review checkpoint 2**

Dispatch `superpowers-reviewer` over the Task 2 commit. Require it to trace every new platform object to `MainActor`, verify the compatibility surface is unchanged and still compiles, and confirm Task 4C explicitly owns removal of all legacy unchecked/mutable contracts.

### Task 3: Add the bounded cmark executor and render session

**Files:**
- Create: `Sources/MarkdownPlatformView/RenderSessionTypes.swift`
- Create: `Sources/MarkdownPlatformView/ParseExecutor.swift`
- Create: `Sources/MarkdownPlatformView/MarkdownRenderSession.swift`
- Modify: `Sources/MarkdownCore/DocumentParser.swift`
- Test: `Tests/MarkdownKitTests/ParseExecutorTests.swift`
- Test: `Tests/MarkdownKitTests/MarkdownRenderSessionTests.swift`

**Interfaces:**
- Consumes: Task 2 `RenderInput`, `RenderDisplayModel`, `RenderSnapshot`.
- Produces: `ParseExecutor.shared`, `RenderSessionEvent`, async `MarkdownRenderSession` commands, weak `RenderSessionSinkRegistry`, and synchronous main-actor `MarkdownRenderSessionDriver` used by Task 4.

- [ ] **Step 1: Write deterministic blocking-parser tests**

Use an injected parser closure blocked by `NSCondition` or `DispatchSemaphore`; use Swift Testing `confirmation` only to observe asynchronous state transitions. Assert two active jobs globally, one active plus one replaceable pending input per token, 64 waiting tokens, latest-revision coalescing, three attempts/two-second deadline through an injected clock, and `.parseBusy` after exhaustion. While the fake parser blocks, release strong driver/view/session references and assert all weak references become nil and every `enqueue` caller has already returned.

Run:

```bash
swift test --filter 'ParseExecutorTests|MarkdownRenderSessionTests'
```

Expected: FAIL because executor/session types do not exist.

- [ ] **Step 2: Implement executor tokens, admission, and tombstones**

Implement:

```swift
package struct ParseSessionToken: Hashable, Sendable { let rawValue: UUID }
package struct ParseSubmission: Hashable, Sendable {
    let id: UUID
    let sessionToken: ParseSessionToken
    let commitToken: RenderCommitToken
    let attempt: UInt8
}
package struct ParseJob: Sendable {
    let submission: ParseSubmission
    let source: String
}

package enum ParseExecutorResult: Sendable {
    case parsed(submission: ParseSubmission, document: MarkdownDocument)
    case busy(submission: ParseSubmission)
    case stale(submission: ParseSubmission)
}

package enum ParseAdmission: Sendable, Equatable {
    case started, queued, replacedPending, busy
}

package struct ParseExecutorDiagnostics: Sendable, Equatable {
    let activeCount: Int
    let waitingTokenCount: Int
    let registryCount: Int
}

package struct RenderSessionID: Hashable, Sendable { let rawValue: UUID }

package typealias SynchronousParser = @Sendable (ParseJob) -> MarkdownDocument

package struct ParseWorkerOutput: Sendable {
    let job: ParseJob
    let document: MarkdownDocument
}

package struct ActiveParse {
    let worker: Task<ParseWorkerOutput, Never>
    let monitor: Task<Void, Never>
}

package enum ParseTokenState {
    case waiting(latest: ParseJob)
    case active(ActiveParse, latestPending: ParseJob?, tombstoned: Bool)
}

package protocol ParseResultSink: Actor {
    func receive(_ result: ParseExecutorResult)
}

package final class WeakParseResultSink {
    weak var value: (any ParseResultSink)?
    init(_ value: any ParseResultSink) { self.value = value }
}

package actor ParseResultRegistry {
    func register(_ sink: any ParseResultSink, for token: ParseSessionToken)
    func unregister(_ token: ParseSessionToken)
    func publish(_ result: ParseExecutorResult, to token: ParseSessionToken) async
}

package actor ParseExecutor {
    static let shared = ParseExecutor(
        maxActive: 2,
        maxWaitingTokens: 64,
        parser: { MarkdownDocument(parsing: $0.source) }
    )
    init(maxActive: Int, maxWaitingTokens: Int, parser: @escaping SynchronousParser)
    func enqueue(_ job: ParseJob, sink: any ParseResultSink) -> ParseAdmission
    func tombstone(_ token: ParseSessionToken)
    private func start(_ job: ParseJob)
    private func complete(_ output: ParseWorkerOutput)
    package var diagnostics: ParseExecutorDiagnostics { get }
}
```

`enqueue` returns an admission value immediately; there are no suspended submit continuations. It registers a weak result sink, replaces the session token's pending job in place, and emits `.stale(submission:)` for the superseded submission through the registry. `start` creates `Task.detached { [parser, job] in ParseWorkerOutput(job: job, document: parser(job)) }`; the executor immediately stores that handle, so it is never unowned. A separate executor-owned monitor awaits `worker.value` and calls `complete`; synchronous cmark never blocks the actor. The worker captures exactly the immutable parser function and `ParseJob`, not a session/view/cache/callback. `complete` applies active→pending/idle, publishes the full submission token through the weak registry, and treats absent/tombstoned tokens as stale. Immediate `.busy` admission is converted by the session into `.busy(submission:)` for retry accounting; an asynchronous busy/stale result can never mutate retry state for a different submission ID/attempt. `tombstone` removes waiting work/result registration immediately or marks active state; active completion drops output and removes remaining registry state.

Run `swift test --filter ParseExecutorTests`; expected PASS for global/per-token limits, coalescing, actor responsiveness, and tombstone transitions.

- [ ] **Step 3: Implement session revision and retry state**

Create a session actor whose stored state is immutable/Sendable and whose publication sink is a weak main-actor registry token:

```swift
package actor MarkdownRenderSession: ParseResultSink {
    func handle(_ event: RenderSessionEvent) async
    func dismantle() async
}

package enum RenderSessionMutation: Sendable {
    case setSource(String, RenderConfigurationSnapshot)
    case append(String)
    case replaceConfiguration(RenderConfigurationSnapshot)
    case dismantle
}

package struct RenderCommitToken: Hashable, Sendable {
    let sessionID: RenderSessionID
    let sequence: UInt64
    let sourceRevision: UInt64
    let configurationGeneration: UInt64
}

package struct RenderSessionEvent: Sendable {
    let mutation: RenderSessionMutation
    let commitToken: RenderCommitToken
}

package enum RenderSessionError: Error, Sendable, Equatable {
    case parseBusy
    case preparationFailed
}

@MainActor
package protocol RenderSessionSink: AnyObject {
    func replaceSnapshot(_ snapshot: RenderSnapshot, token: RenderCommitToken)
    func receive(error: RenderSessionError)
}

@MainActor
package final class WeakRenderSessionSink {
    package weak var value: (any RenderSessionSink)?
    package init(_ value: any RenderSessionSink) { self.value = value }
}

@MainActor
package final class RenderSessionSinkRegistry {
    private var sinks: [RenderSessionID: WeakRenderSessionSink]
    private var authorizedTokens: [RenderSessionID: RenderCommitToken]
    func register(_ sink: any RenderSessionSink, for id: RenderSessionID)
    func authorize(_ token: RenderCommitToken)
    func withAuthorizedSink(
        for token: RenderCommitToken,
        _ body: @MainActor (any RenderSessionSink) throws -> Void
    ) rethrows -> Bool
    func revokeAndUnregister(_ id: RenderSessionID)
}

@MainActor
package final class MarkdownRenderSessionDriver {
    private let session: MarkdownRenderSession
    private let continuation: AsyncStream<RenderSessionEvent>.Continuation
    private let pump: Task<Void, Never>
    package init(session: MarkdownRenderSession)
    package func send(_ mutation: RenderSessionMutation)
}
```

The main-actor driver is the authority for `RenderCommitToken`. `send(_:)` synchronously advances sequence plus the affected source/configuration counter, calls `registry.authorize(token)`, then yields the event carrying that exact token. Dismantle synchronously revokes/unregisters before yielding teardown. The session adopts, but never invents, these counters; every parse submission retains its originating commit token.

Every session command mutates state, calls `enqueue`, and returns without awaiting cmark completion. The driver is the sole strong owner of its session. Its pump is created with `Task { [weak session] in ... }`; each loop iteration promotes that weak reference only for one short actor command, then drops it before waiting for the next event. Thus the stored pump cannot keep either driver or session alive. The driver owns the pump; `deinit` revokes authorization, finishes/cancels the pump, and releases its strong session property. The session's one retry task uses `[weak self]` plus immutable token/input; it promotes `self` only after each clock tick and for one retry command, so the stored task never creates a session→task→session cycle. Gate received results on the complete commit token. Any MainActor side effect calls `withAuthorizedSink(for:)`; token equality, weak-sink promotion, and the synchronous body happen without suspension on `MainActor`. Teardown cancels retry, clears pending input, tombstones the executor token, and unregisters the parse result sink; the driver has already revoked the snapshot sink.

Run `swift test --filter MarkdownRenderSessionTests`; expected PASS for retry, weak sink, generation, driver teardown, and newest-only publication. Include a RED→GREEN case that keeps source revision unchanged, replaces only the configuration generation while parsing is active, and proves the old submission cannot publish or alter the new retry state. Add a gate-controlled race that pauses after the session's check but before the queued MainActor commit, authorizes a newer configuration token, then proves `withAuthorizedSink` rejects the old snapshot/error and never calls the sink.

- [ ] **Step 4: Prove lifecycle cleanup and stale rejection**

Add tests for 1,000 create/dismantle cycles returning executor/result registries to baseline; teardown during a permanently blocked worker releases driver/view/session, leaves no suspended enqueue caller, and produces no publication, callback, cache write, retry, or follow-up. Add rapid set/append/replace sequences and assert only the newest snapshot reaches the sink.

- [ ] **Step 5: Verify and commit**

```bash
swift test --filter 'ParseExecutorTests|MarkdownRenderSessionTests|MarkdownCoreIncrementalParseTests'
swift test
swift build -c release -Xswiftc -warnings-as-errors
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
git add Sources/MarkdownCore/DocumentParser.swift Sources/MarkdownPlatformView/RenderSessionTypes.swift Sources/MarkdownPlatformView/ParseExecutor.swift Sources/MarkdownPlatformView/MarkdownRenderSession.swift Tests/MarkdownKitTests/ParseExecutorTests.swift Tests/MarkdownKitTests/MarkdownRenderSessionTests.swift
git commit -m "feat: add bounded markdown render sessions"
```

- [ ] **Step 6: Review checkpoint 3A**

Dispatch `superpowers-reviewer` over Task 3 with critical-concurrency focus. Require evidence for no view/session retention across blocking cmark, global/per-token limits, stale-result rejection, retry bounds, and registry reclamation.

### Task 4A: Extract platform files without changing behavior

**Files:**
- Create: `Sources/MarkdownPlatformView/MarkdownLabelView+iOS.swift`
- Create: `Sources/MarkdownPlatformView/MarkdownLabelView+macOS.swift`
- Create: `Sources/MarkdownPlatformView/MarkdownTextInput+iOS.swift`
- Create: `Sources/MarkdownPlatformView/MarkdownSelection.swift`
- Create: `Sources/MarkdownPlatformView/MarkdownTableOverlay.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView.swift`
- Test: existing render-mode, copy, input, and table suites

**Interfaces:**
- Consumes: existing platform view behavior unchanged.
- Produces: focused platform files with the same public API and no session migration yet.

- [ ] **Step 1: Run the extraction safety net**

```bash
swift test --filter 'MarkdownLabelViewRenderModeTests|ReadOnlyCopyOriginalSourceTests|TableMeasurementLaidOutEquivalenceTests'
```

Expected: PASS before extraction.

- [ ] **Step 2: Move shared helpers one responsibility at a time**

Move source-selection helpers, table overlay/layout helpers, and iOS `UITextInput` helper types to their named files without renaming symbols or changing public/package API. Implementation-only declarations may be minimally promoted to `internal` only when cross-file access objectively requires it; audit each promotion with its cross-file callsite. After each move rerun the Step 1 command; each run must remain green.

- [ ] **Step 3: Move the conditional UIKit and AppKit class bodies**

Leave only cross-platform value/helper declarations in `MarkdownLabelView.swift`. Move the class declarations/extensions under their existing `#if canImport` guards. Run `swiftformat` over the six files; do not alter state ownership in this task.

- [ ] **Step 4: Verify, commit, and review extraction**

```bash
swift test
swift build -c release -Xswiftc -warnings-as-errors
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
git add Sources/MarkdownPlatformView/MarkdownLabelView.swift Sources/MarkdownPlatformView/MarkdownLabelView+iOS.swift Sources/MarkdownPlatformView/MarkdownLabelView+macOS.swift Sources/MarkdownPlatformView/MarkdownTextInput+iOS.swift Sources/MarkdownPlatformView/MarkdownSelection.swift Sources/MarkdownPlatformView/MarkdownTableOverlay.swift
git commit -m "refactor: split markdown platform view files"
```

Dispatch `superpowers-reviewer` over only this commit and require behavior-only extraction, complete symbol moves, and both platform branches compiling.

### Task 4B: Route both platform views through the session driver

**Files:**
- Modify: `Sources/MarkdownRenderKit/RenderPreparer.swift`
- Modify: `Sources/MarkdownRenderKit/RenderMaterializer.swift`
- Modify: `Sources/MarkdownRenderKit/RenderDisplayModel.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView+iOS.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView+macOS.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownRenderSession.swift`
- Modify: `Sources/MarkdownKit/MarkdownText.swift`
- Modify: `Sources/MarkdownKit/MarkdownStreamingText.swift`
- Test: `Tests/MarkdownKitTests/PlatformSessionWiringTests.swift`
- Test: `Tests/MarkdownKitTests/RenderMigrationParityTests.swift`

**Interfaces:**
- Consumes: Task 3 `MarkdownRenderSessionDriver` and Task 2 snapshots.
- Produces: thin platform views that synchronously enqueue `RenderSessionEvent` values and receive snapshots through the weak sink registry.
- Prerequisite to either consumer switch: complete legacy rendering parity in the Task 2 preparer/materializer. Task 2 intentionally supplies only the boundary and basic runs/resources; its initial implementation is not a production replacement for `AttributedStringRenderer`.

- [ ] **Step 1: Establish differential migration tests while both views still use the legacy renderer**

Add `RenderMigrationParityTests` that render the same source/programmatic IR, style, width, placeholder mode, and deterministic resolved-resource fixtures through the legacy renderer and the new preparation/materialization path. Assert attributed text and normalized attributes, measured TextKit layout, and semantic metadata/results; do not compare platform object identity or update expected output from the new implementation. Include explicit expected strings/URLs/source selections and attachment geometry so a shared omission cannot make both paths pass.

The fixture matrix must cover emphasis/strong/strikethrough; link labels and destinations; inline/fenced code highlighting and backgrounds; nested quotes, ordered/unordered/task lists, table alignment/overflow; headings/body/custom fonts, all existing colors and paragraph styling; source-present and programmatic-source-absent copy mapping; static/streaming placeholders; resolved/missing/failed image/math/SVG resources; and narrow/wide `availableWidth` values. Compare attachment dimensions and baselines, line/fragment bounds, table measurements and overlays, rendered/source text mapping, and link activation metadata handed to the platform. Use the existing rendering, placeholder, SVG degradation, copy, table-measurement, and resource-relayout regression suites as the compatibility baseline on UIKit and AppKit.

Run `swift test --filter RenderMigrationParityTests`; expected FAIL on the Task 2 implementation's missing styling/layout/semantic behavior. Keep both views on the legacy path during this RED phase and the following implementation step.

- [ ] **Step 2: Complete legacy rendering semantics and pass the hard pre-switch gate**

Extend `RenderPreparer`, `RenderDisplayModel`, and `RenderMaterializer` to preserve every existing output-affecting behavior in that matrix: emphasis/strong/strikethrough traits; link destinations and activation metadata handoff; code highlighting/backgrounds; quote/list/table formatting; existing source/copy mapping; placeholder and resolved-resource geometry, baseline/scale handling, and width-dependent layout; and typography/color/paragraph styling. Keep preparation values Sendable and resolve platform fonts/colors/attachments/TextKit state on MainActor. Preserve legacy resource adapters until Task 4C replaces them.

This step migrates existing behavior only. Task 8 still owns the new typed link policy, handler configuration, and policy-generation activation checks; Task 9 owns the exact rendered-selection versus explicit source-copy behavior, typed granularity, and localized commands; Task 10 owns the semantic accessibility tree, virtual platform elements, focus, and announcements; Task 11 owns preferred-metric scaling, new trait-driven adaptation, and maximum-category layout policies. Preserve the current native accessibility exposure and the immutable accessibility data boundary here, but do not implement Task 10's tree/platform accessibility work. Preserve the legacy copy behavior in differential tests until Task 9 intentionally changes it.

**Hard gate:** neither platform view may switch to the session's new snapshots until all differential attributed-string, layout, and semantic tests pass on both platforms and all existing pre-migration regression suites remain green. Missing parity cannot be waived as follow-up work in Tasks 8–11; those tasks add the enhanced policies above. Run these commands before adding driver wiring or changing either consumer:

```bash
swift test --filter 'RenderMigrationParityTests|MarkdownRenderKitTests|PlaceholderModeRendererTests|TableMeasurementLaidOutEquivalenceTests|ReadOnlyCopyOriginalSourceTests|AsyncMathWritebackRelayoutTests'
swift test
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
```

Record the differential tests and pre-migration suite results as checkpoint evidence. Expected: PASS while both views still use the legacy renderer. Only then proceed to driver wiring.

- [ ] **Step 3: Write and run the failing driver wiring tests**

Inject a `RecordingSessionDriver` conforming to:

```swift
@MainActor
package protocol RenderSessionDriving: AnyObject {
    func send(_ mutation: RenderSessionMutation)
}

extension MarkdownRenderSessionDriver: RenderSessionDriving {}
```

Assert set, append, style/renderer change, scale change, and teardown each emit one ordered event; old sink tokens cannot apply snapshots. Run `swift test --filter PlatformSessionWiringTests`; expected FAIL because views do not accept the driver.

- [ ] **Step 4: Install the driver and weak sink after the parity gate passes**

Replace duplicated parse tasks/revision fields/direct source update pipelines with one driver. The main-actor driver/registry authorization is the final authority for the current commit token; the session carries that token through work but cannot authorize publication. Views keep only a diagnostic mirror, not an acceptance guard. Apply snapshots only through:

```swift
func replaceSnapshot(_ snapshot: RenderSnapshot, token: RenderCommitToken) {
    precondition(currentCommitToken.map { token.sequence >= $0.sequence } ?? true)
    currentCommitToken = token
    let previousSnapshot = currentSnapshot
    contentStorage.attributedString = NSAttributedString()
    currentSnapshot = nil
    currentSnapshot = snapshot
    contentStorage.attributedString = snapshot.attributedString
    synchronizePlatformSelectionAndOverlays(snapshot)
    withExtendedLifetime(previousSnapshot) {}
}
```

Both platform views conform to `RenderSessionSink` and strongly retain the current snapshot for at least as long as TextKit retains its attachments. The monotonic assertion is diagnostic only; it is not a second acceptance guard. Dismantle clears TextKit content/current snapshot, sends `.dismantle`, unregisters the sink ID, and releases the driver. Wrap every legacy image/math/SVG object referenced by the published attributed string in Task 2's `LegacyResourceOwner`; add regression coverage proving those resources do not disappear during the migration. Keep old resource cache adapter calls until Task 4C.

- [ ] **Step 5: Run focused green and commit**

```bash
swift test --filter 'RenderMigrationParityTests|PlatformSessionWiringTests|MarkdownLabelViewRenderModeTests|TableMeasurementLaidOutEquivalenceTests'
swift test
swift build -c release -Xswiftc -warnings-as-errors
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
git add Sources/MarkdownRenderKit/RenderPreparer.swift Sources/MarkdownRenderKit/RenderMaterializer.swift Sources/MarkdownRenderKit/RenderDisplayModel.swift Sources/MarkdownPlatformView Sources/MarkdownKit/MarkdownText.swift Sources/MarkdownKit/MarkdownStreamingText.swift Tests/MarkdownKitTests/PlatformSessionWiringTests.swift Tests/MarkdownKitTests/RenderMigrationParityTests.swift
git commit -m "refactor: route platform views through render sessions"
```

- [ ] **Step 6: Review session migration**

Dispatch `superpowers-reviewer` over Task 4B with event ordering, weak sink ownership, stale snapshot rejection, driver task ownership, and UIKit/AppKit parity focus. Require recorded pre-switch differential and full regression evidence; inspect every legacy rendering/semantic behavior listed above and block a consumer switch that still relies on the incomplete Task 2 implementation. Confirm Tasks 8–11 retain ownership of their enhanced policies.

### Task 4C: Migrate math/SVG resources and remove compatibility render APIs

**Files:**
- Modify: `Sources/MarkdownPlatformView/MathLoadCoordinator.swift`
- Modify: `Sources/MarkdownPlatformView/SVGBlockLoadCoordinator.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownRenderSession.swift`
- Create: `Sources/MarkdownPlatformView/RenderedResourceLease.swift`
- Delete: `Sources/MarkdownRenderKit/AttributedStringRenderer.swift`
- Modify: `Sources/MarkdownRenderKit/RenderStyle.swift`
- Modify: `Sources/MarkdownRenderKit/MarkdownSourceHighlighter.swift`
- Modify: `Sources/MarkdownRenderKit/MathRendering.swift`
- Modify: `Sources/MarkdownRenderKit/SVGBlockRendering.swift`
- Modify: `Sources/MarkdownMath/MathJaxRenderer.swift`
- Modify: `Sources/MarkdownMath/SVGRasterizer.swift`
- Modify: `Sources/MarkdownMath/SwiftDrawSVGBlockRenderer.swift`
- Modify: `Sources/MarkdownRenderKit/SyntaxHighlighter.swift`
- Create: `Scripts/check-unchecked-sendable.sh`
- Test: existing math/SVG coordinator, renderer, streaming, and cache suites

**Interfaces:**
- Consumes: Task 2 compatibility adapter and Task 4B session ownership.
- Produces: wrapper-owned renderer configuration IDs, session-owned in-flight work, bounded completed/negative caches, injected clocks, explicit math/SVG cache/in-flight/publication leases, and no old mutable renderer cache surface.

- [ ] **Step 1: Write and run failing identity/ownership tests**

Add cases proving equal semantic renderer IDs share completed results, different/unique IDs isolate them, two sessions do not share in-flight tasks, replacement bumps generation, and cancellation/transient failures are not negative-cached. Run the focused math/SVG suites; expect new cases to fail.

```bash
swift test --filter 'MathLoadCoordinatorTests|SVGBlockLoadCoordinatorTests|SharedCoordinatorTests'
```

Expected: FAIL on identity, cross-session ownership, or bounded-negative-cache assertions.

- [ ] **Step 2: Move in-flight work into the session and make math/SVG ownership explicit**

Remove `.shared` task ownership. Keep completed caches injectable with 256-entry LRU bounds. Keep deterministic failures for 60 seconds in a 128-entry LRU using an injected clock. Include `MarkdownConfigurationID` in every key and gate completion/cache writes by generation.

Add main-actor `RenderedResourceRecord` and idempotent `RenderedResourceLease: ResourceResidencyOwner`. A successful math/SVG materialization first owns an in-flight lease; completed-cache insertion acquires a separate cache lease; snapshot construction acquires a publication lease before releasing the in-flight lease. Cache eviction releases only its cache lease, snapshot destruction/replacement releases only its publication lease, and failure/cancellation/configuration replacement releases the in-flight lease. Add deterministic owner-count tests for success, cache hit, eviction while published, rejected stale completion, cancellation, snapshot replacement, and teardown. `LegacyResourceOwner` remains only on remote-image compatibility values after this task.

```swift
@MainActor
package final class RenderedResourceRecord {
    let id: UUID
    let image: PlatformImage
    func acquireLease() -> RenderedResourceLease
}

@MainActor
package final class RenderedResourceLease: ResourceResidencyOwner {
    let record: RenderedResourceRecord
    func release()
}
```

The record's idempotent internal token decrements its owner count on explicit release or lease deinitialization. Coordinators create records only after current-generation materialization on `MainActor`; neither cache nor snapshot ever receives a naked record/image.

- [ ] **Step 3: Migrate all producers and delete the Task 2 adapter**

Make `MathRendererConfiguration` and `SVGRendererConfiguration` own identity: custom instances remain unique unless the caller explicitly supplies a versioned semantic ID, while built-in MathJax/SwiftDraw/SVGRasterizer configurations derive deterministic IDs from all normalized settings. Replace platform-image cross-actor outcomes with immutable render descriptions or Task 2's single audited `ImmutableCGImageBacking`; materialize images on `MainActor`. Move source-highlighter style access to immutable configuration snapshots. After every consumer compiles, delete the complete legacy `AttributedStringRenderer` file, mutable renderer caches/generation fields, and compatibility overloads. Replace every math/SVG `LegacyResourceOwner` with `RenderedResourceLease`; do not delete the adapter type yet because Task 7 still owns remote-image migration.

Dispose of the current production unchecked types explicitly: convert `MathJaxRenderer` and `SwiftDrawSVGBlockRenderer` to actors behind async rendering protocols; replace `MathRenderedGlyph`/`SVGBlockGlyph` with immutable encoded/vector result values; move `SyntaxHighlighter.CachedSpans`, compiled regexes, and their bounded dictionaries wholly inside a `SyntaxHighlightCache` actor that returns only immutable `Sendable` highlight spans; snapshot `RenderStyle`; and delete `AttributedStringRenderer`. `Scripts/check-unchecked-sendable.sh` runs `rg -n '@unchecked Sendable' Sources` and fails unless the sole match is the declaration of `ImmutableCGImageBacking` in `ResolvedResource.swift` (or its final Task 2 file). Test-only doubles are outside this production gate.

- [ ] **Step 4: Replace touched sleeps and run green**

Replace the four product debounce sleeps with one driver/session-owned task using an injected clock. Convert touched math/SVG test polling to gates/confirmations.

```bash
swift test --filter 'MathLoadCoordinatorTests|SVGBlockLoadCoordinatorTests|SharedCoordinatorTests|AsyncMathWritebackRelayoutTests|StreamingMathCacheSurvivesRendererRecreationTests|StreamingSVGBlockCacheSurvivesRendererRecreationTests'
swift test
swift build -c release -Xswiftc -warnings-as-errors
chmod +x Scripts/check-unchecked-sendable.sh
Scripts/check-unchecked-sendable.sh
Scripts/check-api-isolation.sh
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
git add Sources/MarkdownPlatformView Sources/MarkdownRenderKit Sources/MarkdownMath Tests Scripts/check-unchecked-sendable.sh
git commit -m "refactor: move rendered resources into sessions"
```

- [ ] **Step 5: Review checkpoint 3B**

Dispatch `superpowers-reviewer` from Task 4B head through Task 4C head. Require the old `AttributedStringRenderer` and all math/SVG compatibility APIs to be removed, all MarkdownMath producers to compile, renderer identities to be stable, caches to be bounded, and in-flight work/clocks to be session-owned. The sole intentional compatibility remainder is remote-image `LegacyResourceOwner`; the review must verify its uses are image-only and Task 7 owns its deletion.

### Task 5: Make safe streaming work near-linear

**Files:**
- Create: `Sources/MarkdownCore/IncrementalParseState.swift`
- Create: `Sources/MarkdownCore/IncrementalSourceBuffer.swift`
- Create: `Sources/MarkdownCore/ParseWorkMetrics.swift`
- Modify: `Sources/MarkdownCore/DocumentParser.swift`
- Modify: `Sources/MarkdownCore/MathScanner.swift`
- Modify: `Sources/MarkdownCore/MathSentinel.swift`
- Create: `Sources/MarkdownRenderKit/RenderDisplayDelta.swift`
- Modify: `Sources/MarkdownRenderKit/RenderPreparer.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownRenderSession.swift`
- Test: `Tests/MarkdownKitTests/IncrementalParseDifferentialTests.swift`
- Test: `Tests/MarkdownKitTests/IncrementalWorkBudgetTests.swift`
- Test: existing scanner/incremental suites

**Interfaces:**
- Consumes: session append chunks and immutable render preparation.
- Produces: `IncrementalSourceBuffer`, `IncrementalParseState`, package `IncrementalParseResult`, `RenderDisplayDelta`, and package `ParseWorkMetrics` returned through the session diagnostics sink.

- [ ] **Step 1: Add exhaustive differential tests and prove a failure**

For small fixtures, append at every UTF-8 boundary and compare incremental `blocks`, source ranges, and fingerprints to `MarkdownDocument(parsing:)`. Cover math delimiters, fenced/inline/indented code, Unicode, references, setext/thematic ambiguity, HTML blocks, lazy list/blockquote continuation, tables, CR/LF/CRLF splits, malformed input, and missing final newline. Use fixed seeds for larger chunk sequences.

Run:

```bash
swift test --filter IncrementalParseDifferentialTests
```

Expected: at least the known non-local/fallback or work-observation tests fail before stateful parsing exists.

- [ ] **Step 2: Define scanner state and conservative invalidation reasons**

Implement:

```swift
package struct FenceState: Sendable, Equatable {
    let marker: UInt8
    let length: Int
    let startByte: Int
}

package enum MathDelimiterState: Sendable, Equatable { case closed, dollar, doubleDollar, paren, bracket }

package struct LineContext: Sendable, Equatable {
    let lineStart: Int
    let containerStart: Int?
    let endsInCarriageReturn: Bool
}

package struct IncrementalParseState: Sendable, Equatable {
    let safeUTF8Boundary: Int
    let fence: FenceState?
    let inlineCodeDelimiterLength: Int?
    let math: MathDelimiterState
    let lineContext: LineContext
}

package enum FullParseReason: Sendable, Equatable {
    case nonPrefixEdit, missingState, referenceDefinition, setextOrThematicBreak
    case htmlBlock, lazyContainer, splitCRLF, missingFinalNewline, inconsistentPrefix
}

package struct BlockLineage: Sendable, Equatable {
    let oldIndex: Int?
    let newIndex: Int
    let lineage: UInt64
}

package struct IncrementalParseResult: Sendable, Equatable {
    let document: MarkdownDocument
    let state: IncrementalParseState
    let fullParseReason: FullParseReason?
    let changedBlockRange: Range<Int>
    let lineageMapping: [BlockLineage]
    let metrics: ParseWorkMetrics
}
```

Implement this invalidation matrix in tests and code: non-prefix edit, inconsistent prefix, or an appended reference definition invalidates from byte 0; setext/thematic ambiguity invalidates from the preceding line start; an open HTML block invalidates from its opener; lazy list/blockquote continuation invalidates from the container start; a split CRLF invalidates from the preceding CR; missing final newline invalidates from the final open block start. If the recorded start cannot be validated, fall back to byte 0 and emit the matching `FullParseReason`.

- [ ] **Step 3: Instrument every source-proportional phase**

Implement a test-injectable counter:

```swift
package struct ParseWorkMetrics: Sendable, Equatable {
    public var scannerBytes = 0
    public var mappingBytes = 0
    public var materializationBytes = 0
    public var cmarkInputBytes = 0
    public var renderPreparationBytes = 0
    public var total: Int { scannerBytes + mappingBytes + materializationBytes + cmarkInputBytes + renderPreparationBytes }
}
```

Count UTF-8 construction, prefix checks, suffix copies, math substitution, source mapping, cmark input, and display-model preparation. Do not leave a source-sized loop or copy outside a counter category.

`IncrementalSourceBuffer` stores immutable appended chunks plus cumulative UTF-8 offsets, compares only the required prefix boundary, and materializes only the invalidated parser tail. `MarkdownRenderSession.append` accepts a chunk, updates this buffer, receives `IncrementalParseResult`, adds session-side merge/copy work to its metrics, and forwards the combined value to a package diagnostics sink used by tests.

Run `swift test --filter IncrementalWorkBudgetTests`; expected the source-buffer/metric accounting cases to pass while the final budgets remain red until tail parsing is implemented.

- [ ] **Step 4: Implement tail-only scanning/parsing/render preparation**

Replace complete-source `MathScanner.scan`/`codeRegionMask` calls on safe append with state resumption. Parse only the invalidated tail, offset its source ranges, preserve stable prefix blocks, and have `MarkdownRenderSession` invoke the production delta entry point for only `changedBlockRange`. Reuse the prior lineage when a reparsed block has the same immutable start anchor and semantic role, even if a paragraph/list/table end grows; allocate new lineage only for inserted/reclassified blocks. Check cancellation at fixed byte/block intervals in owned loops.

Add these contracts in Task 5, after `ParseWorkMetrics` exists:

```swift
package struct RenderDisplayDelta: Sendable, Equatable {
    let replacedPreviousBlocks: Range<Int>
    let changedDocumentBlocks: Range<Int>
    let replacementBlocks: [DisplayBlock]
    let replacementRuns: [DisplayRun]
    let replacementResources: [UnresolvedResource]
    let removedResourceIDs: Set<ResourceID>
    let replacementAccessibilityRoots: [AccessibilityNode]

    func applying(to previous: RenderDisplayModel) -> RenderDisplayModel
}

package extension RenderPreparer {
    func prepareDelta(
        _ input: RenderInput,
        replacing previousBlocks: Range<Int>,
        with changedBlocks: Range<Int>,
        metrics: inout ParseWorkMetrics
    ) throws -> RenderDisplayDelta
}
```

The delta contains no unchanged prefix/suffix runs, blocks, resources, or accessibility roots. `applying(to:)` splices block-aligned runs, removes exactly `removedResourceIDs`, merges replacement resources by `ResourceID`, and replaces accessibility roots for the replaced lineage range while preserving all surviving node IDs. The session owns the previous complete model and performs this merge before materialization. Differential tests compare the merged complete model—including runs, blocks, resources, removed resources, and accessibility—to a fresh full `prepare(_:)` result at every append boundary. A production session spy/counter proves append reaches `prepareDelta`, and metrics prove unchanged prefix preparation bytes are zero; no direct-helper-only test satisfies the gate.

Run `swift test --filter IncrementalParseDifferentialTests`; expected PASS for all boundary/fallback and growing-lineage fixtures.

- [ ] **Step 5: Enforce deterministic budgets**

Define budget-safe fixtures as append-only sequences of complete newline-terminated blocks, each open/reparsed tail no larger than 8 KiB, with no reference definitions, open HTML/container continuation, split CRLF, or missing-final-newline ambiguity. For 1 KB chunks on safe 10 KB, 100 KB, and 1 MB fixtures, assert scanner `≤ 3N`, mapping `≤ 3N`, materialization/substitution/session merge `≤ 4N`, cmark input `≤ 4N`, render preparation `≤ 4N`, total `≤ 16N`. Growing single-paragraph/list/table fixtures are differential/lineage tests but are reported outside the 16N safe set because their cmark tail grows. Report every fallback fixture by reason/boundary and add one warm-up plus five-run median diagnostic.

Run focused tests after implementing state, metrics, buffer/session integration, and lineage respectively; each new slice must turn its named failing cases green before the next slice.

- [ ] **Step 6: Verify and commit**

```bash
swift test --filter 'IncrementalParseDifferentialTests|IncrementalWorkBudgetTests|MarkdownCoreIncrementalParseTests|MathScannerTests|MathScannerCodeRegionHardStopTests|MathScannerCurrencyDollarTests'
swift test
swift build -c release -Xswiftc -warnings-as-errors
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
git add Sources/MarkdownCore Sources/MarkdownRenderKit/RenderDisplayDelta.swift Sources/MarkdownRenderKit/RenderPreparer.swift Sources/MarkdownPlatformView/MarkdownRenderSession.swift Tests/MarkdownKitTests
git commit -m "perf: bound incremental markdown work"
```

- [ ] **Step 7: Review checkpoint 4**

Dispatch `superpowers-reviewer` with correctness/performance focus. Require it to inspect every counted phase, differential fallback coverage, cancellation intervals, and proof that no full-source work moved outside instrumentation.

### Task 6: Implement the isolated opt-in image transport

**Files:**
- Create: `Sources/MarkdownPlatformView/ResourceConfiguration.swift`
- Create: `Sources/MarkdownPlatformView/MarkdownImageLoader.swift`
- Create: `Sources/MarkdownPlatformView/URLSessionImageTransport.swift`
- Create: `Sources/MarkdownPlatformView/ValidatedImageFactory.swift`
- Create: `Scripts/check-validated-image-construction.sh`
- Modify: `Sources/MarkdownPlatformView/RenderSessionTypes.swift`
- Modify: `Sources/MarkdownKit/MarkdownText.swift`
- Modify: `Sources/MarkdownKit/MarkdownStreamingText.swift`
- Create: `Sources/MarkdownKit/MarkdownResourceModifiers.swift`
- Test: `Tests/MarkdownKitTests/MarkdownImageLoaderTests.swift`
- Test: `Tests/MarkdownKitTests/ResourceConfigurationTests.swift`

**Interfaces:**
- Consumes: Task 4 session configuration events and Task 2 `MarkdownConfigurationID`.
- Produces: `MarkdownImageLoading`, untrusted `MarkdownImagePayload`, package-validated `MarkdownEncodedImage`, default disabled policy, sanitized failures, and SwiftUI `.markdownRemoteImages(_:)` configuration used by Task 7.

- [ ] **Step 1: Write protocol, opt-in, generation, and cache-namespace tests**

Tests assert remote URLs stay placeholders by default; enabling the built-in loader starts HTTPS only; equal built-in settings have equal semantic IDs; custom instances receive unique IDs; and explicit versioned semantic IDs compare equal for the cache seam added in Task 7. Replacement increments session generation, and a late old transport/validation result cannot invoke the current callback or advance session resource state. Cache-write and final publication assertions deliberately begin as Task 7 RED tests, where those components exist.

Run `swift test --filter 'MarkdownImageLoaderTests|ResourceConfigurationTests'`. Expected: FAIL because the loader/configuration contracts do not exist.

- [ ] **Step 2: Define immutable public contracts**

```swift
public protocol MarkdownImageLoading: Sendable {
    func load(_ request: MarkdownImageRequest) async throws -> MarkdownImagePayload
}

public struct MarkdownImageRequest: Sendable {
    public let url: URL
    public let requestTimeout: Duration
    public let resourceTimeout: Duration
}

public struct MarkdownImageMetadata: Sendable, Equatable {
    public let mimeType: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frameCount: Int
    public let cumulativePixels: UInt64
    public init(mimeType: String, pixelWidth: Int, pixelHeight: Int, frameCount: Int, cumulativePixels: UInt64)
}

public struct MarkdownImagePayload: Sendable {
    public let data: Data
    public let declaredMIMEType: String?
    public init(data: Data, declaredMIMEType: String?)
}

package struct MarkdownEncodedImage: Sendable {
    package let data: Data
    package let metadata: MarkdownImageMetadata
    fileprivate init(validatedData: Data, metadata: MarkdownImageMetadata)
}

package enum ValidatedImageFactory {
    package static func validate(
        _ payload: MarkdownImagePayload
    ) throws -> MarkdownEncodedImage
}

public enum MarkdownResourceError: Error, Sendable, Equatable {
    case disabled, invalidScheme, redirectRejected, status(Int), typeMismatch
    case encodedLimit, metadataLimit, timedOut, cancelled, transport
}

public struct SanitizedMarkdownOrigin: Sendable, Equatable {
    public let scheme: String
    public let host: String
    public let port: Int?
}

public struct MarkdownResourceFailure: Sendable, Equatable {
    public let category: MarkdownResourceError
    public let origin: SanitizedMarkdownOrigin?
}

public typealias MarkdownResourceErrorHandler =
    @MainActor @Sendable (MarkdownResourceFailure) -> Void

public struct MarkdownRemoteImageConfiguration: Sendable {
    package let loader: (any MarkdownImageLoading)?
    public let configurationID: MarkdownConfigurationID
    public static let disabled: Self
    public static var defaultHTTPS: Self
    public init(
        loader: any MarkdownImageLoading,
        configurationID: MarkdownConfigurationID = .uniqueInstance()
    )
    package init(
        optionalLoader: (any MarkdownImageLoading)?,
        configurationID: MarkdownConfigurationID
    )
}

public actor DefaultHTTPSImageLoader: MarkdownImageLoading {
    public init(requestTimeout: Duration = .seconds(15), resourceTimeout: Duration = .seconds(30))
    public func load(_ request: MarkdownImageRequest) async throws -> MarkdownImagePayload
}
```

Every loader result is untrusted `MarkdownImagePayload`. The session always passes it through the one package `ValidatedImageFactory`, including custom-loader results, before handing the opaque validated value to Task 7. `MarkdownEncodedImage` and its `fileprivate` initializer live in `ValidatedImageFactory.swift`; no other source file can construct it. Add a mechanical source gate that fails if `MarkdownEncodedImage(` occurs outside that file. It contains at most 20 MiB encoded bytes and validated MIME/ImageIO metadata, never a platform image. Error callbacks have the exact `MarkdownResourceErrorHandler` signature and receive only a typed category plus scheme/host/port—never a raw URL, path, query, headers, response body, or underlying error.

The configuration wrapper, not a loader conformer, owns namespace identity. Custom loader wrappers get `.uniqueInstance()` by default even if two conformers are otherwise identical. `.defaultHTTPS` derives a deterministic semantic ID from the complete normalized built-in settings (timeouts, redirect/MIME policy, byte/metadata limits). Sharing requires an explicit caller-supplied versioned semantic ID. Task 6 tests only ID inequality/equality because no image cache exists yet; Task 7 Step 1 uses two custom loaders with the same internal label to prove default wrappers isolate actual cache entries and an explicit shared semantic ID permits completed-cache reuse.

Expose `.markdownRemoteImages(_:)` and `.onMarkdownResourceError(_:)` from `MarkdownResourceModifiers.swift`. The environment default is `.disabled`; `.defaultHTTPS` constructs the deterministic built-in semantic configuration.

Add `RenderSessionEvent.replaceImageConfiguration(MarkdownRemoteImageConfiguration)`; every event increments session generation even when its cache namespace ID remains semantically equal.

- [ ] **Step 3: Implement an isolated URLSession transport**

Build an ephemeral configuration with `httpCookieStorage = nil`, `urlCredentialStorage = nil`, `urlCache = nil`, `requestCachePolicy = .reloadIgnoringLocalCacheData`, and no implicit authentication. Use 15-second request and 30-second resource defaults, configurable within 1...120 seconds. Reject non-HTTPS initial/final/redirect URLs, non-2xx status, cross-host forwarded authorization/custom headers, disallowed MIME, and bodies beyond byte 20 MiB + 1 while streaming.

Run the scheme/status/redirect/cookie/credential/timeout subset of `MarkdownImageLoaderTests`; expected PASS before adding ImageIO metadata cases.

- [ ] **Step 4: Validate metadata before decode**

Use an incremental `CGImageSource` only for type and properties. Require declared MIME, detected UTI/type, and selected decoder agreement. With overflow-safe arithmetic reject either side over 8,192 px, more than 32 frames, or cumulative source pixels over 40 MP. Ensure rejected inputs never reach Task 7's full decoder.

Run the MIME/metadata/byte-limit subset immediately; include custom loaders returning forged MIME/signature pairs, oversized dimensions, more than 32 frames, cumulative pixels over 40 MP, and bodies over 20 MiB. Assert every case is rejected by `ValidatedImageFactory` before Task 7 receives a value. Expected PASS before proceeding to full transport verification.

- [ ] **Step 5: Verify with a controlled URLProtocol and commit**

Cover redirects, status, MIME/signature mismatch, cookies/credentials/cache isolation, sanitized errors, exact byte boundary, timeout, and cancellation using a custom `URLProtocol`; assert decoder invocation count remains zero for rejected cases.

```bash
swift test --filter 'MarkdownImageLoaderTests|ResourceConfigurationTests'
swift test
swift build -c release -Xswiftc -warnings-as-errors
chmod +x Scripts/check-validated-image-construction.sh
Scripts/check-validated-image-construction.sh
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
git add Package.swift Sources/MarkdownPlatformView Sources/MarkdownKit Scripts/check-validated-image-construction.sh Tests/MarkdownKitTests/MarkdownImageLoaderTests.swift Tests/MarkdownKitTests/ResourceConfigurationTests.swift
git commit -m "feat: add secure opt-in markdown image transport"
```

- [ ] **Step 6: Review checkpoint 5A**

Dispatch `superpowers-reviewer` with network/privacy focus. Require verification of no ambient credentials, every redirect/final URL check, predecode limits, cancellation, sanitized error payloads, configuration generations, and namespace semantics.

### Task 7: Enforce image concurrency, pixel budgets, and residency leases

**Files:**
- Create: `Sources/MarkdownPlatformView/ImageResourceCoordinator.swift`
- Create: `Sources/MarkdownPlatformView/ImageResidencyLedger.swift`
- Create: `Sources/MarkdownPlatformView/ImageDecoder.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownRenderSession.swift`
- Modify: `Sources/MarkdownRenderKit/RenderSnapshot.swift`
- Modify: `Sources/MarkdownRenderKit/ResolvedResource.swift`
- Test: `Tests/MarkdownKitTests/ImageResourceCoordinatorTests.swift`
- Test: `Tests/MarkdownKitTests/ImageResidencyLedgerTests.swift`
- Test: `Tests/MarkdownKitTests/ImageAdversarialTests.swift`

**Interfaces:**
- Consumes: validated `MarkdownEncodedImage`, session revisions/configuration generations, unresolved display resources.
- Produces: explicit transfer/encoded/decode reservation tokens, main-actor backing/cache/publication leases conforming to Task 2 `ResourceResidencyOwner`, atomic snapshot replacement, bounded completed LRU, and resolved-resource snapshots.

- [ ] **Step 1: Write concurrency and hold-and-wait regressions**

With controllable transports/decoders, assert per-session maximum two transfers/one decode, process maximum four transfers/two decodes, and exactly 20 MiB reserved before each network start from an 80 MiB ledger. Two 17 MiB and four 9 MiB bodies must finish or remain unstarted; none may pause while holding a partial body. Use two custom loaders with the same internal label to prove default wrapper IDs isolate completed-cache entries; then give them the same explicit semantic ID and prove completed-cache reuse. Add generation integration cases proving a replaced configuration's late result cannot publish or write completed/negative caches, while the current generation can. Add the complete 100-image adversarial fixture here, before production implementation, covering permit limits, reservation ceilings, promotion, cache publication/eviction, snapshot commit/cancel, memory pressure, and teardown-to-baseline.

Run `swift test --filter 'ImageResourceCoordinatorTests|ImageResidencyLedgerTests|ImageAdversarialTests'`. Expected: FAIL because permit/reservation/ownership tokens do not exist; preserve this RED output as the Task 7 TDD checkpoint.

- [ ] **Step 2: Implement permit and encoded-reservation actors**

```swift
package actor ImageResourceCoordinator {
    static let shared = ImageResourceCoordinator(
        globalTransfers: 4, globalDecodes: 2,
        encodedReservationBytes: 80 * 1024 * 1024
    )
    func acquireTransferPermit(session: RenderSessionID) async throws -> TransferPermit
    func reserveEncodedBody(session: RenderSessionID) async throws -> EncodedBodyReservation
    func acquireDecodePermit(session: RenderSessionID) async throws -> DecodePermit
    func cancelQueued(session: RenderSessionID)
}

package actor TransferPermit { func release() }
package actor DecodePermit { func release() }

package actor EncodedBodyReservation {
    let byteLimit: Int
    func attach(_ image: MarkdownEncodedImage) throws -> ReservedEncodedImage
    func rejectAndRelease()
    package func consumedByDecoder()
}

package struct ReservedEncodedImage: Sendable {
    let image: MarkdownEncodedImage
    let reservation: EncodedBodyReservation
}
```

Acquire the 20 MiB `EncodedBodyReservation` and a transfer permit before invoking transport. Release the transfer permit when network activity ends, but move the encoded reservation into `ReservedEncodedImage`; only decoder consumption or explicit rejection releases it. Queue without starting network or retaining response bytes, and remove queued entries on source/configuration replacement and teardown. Add a focused green run for two 17 MiB and four 9 MiB cases before implementing decode.

- [ ] **Step 3: Implement downsampling and conservative pixel accounting**

Normalize ImageIO thumbnails to 8-bit BGRA/sRGB. Reserve `alignUp(width * 4, 64) * height` summed over retained frames with overflow checks; cap output at 4,096 px/side and 64 MiB. Reconcile against actual `CGImage.bytesPerRow * height` before publication; when reconciliation exceeds remaining budget, discard and retry smaller once, otherwise keep the accessible placeholder.

Obtain the decoded reservation before acquiring a decode permit, so a waiter holds neither a decode slot nor decoded backing:

```swift
@MainActor
package final class DecodedPixelReservation {
    let reservedBytes: Int
    func reconcile(actualBytes: Int) -> Bool
    func promote(_ decoded: DecodedImage) -> OwnedImage?
    func cancel()
}
```

The decoder consumes `ReservedEncodedImage`, explicitly calls the package-visible `consumedByDecoder()` after ImageIO no longer needs the bytes, and always releases `DecodePermit` in cancellation/error/success paths. All permit/reservation release methods are idempotent. Tests exercise success, validation rejection, decoder failure, cancellation before/after consumption, and double-release attempts so the encoded ledger returns exactly to baseline.

Run the decode reservation/reconciliation subset of `ImageResidencyLedgerTests`; expected PASS before owner-lease implementation.

- [ ] **Step 4: Implement unique backing records and owner leases**

```swift
@MainActor
package final class ImageOwnerLease: ResourceResidencyOwner {
    let backingID: UUID
    let accountedPixelBytes: Int
    private let token: ResidencyRecordToken
    func release()
}

@MainActor
package final class ResidencyRecordToken {
    let backingID: UUID
    func release()
}

package struct DecodedImage: Sendable {
    let backingID: UUID
    let backing: ImmutableCGImageBacking
}

@MainActor
package final class ImageBacking {
    let backingID: UUID
    let image: PlatformImage
    let accountedPixelBytes: Int
}

@MainActor
package struct OwnedImage {
    let backing: ImageBacking
    let inFlightOwner: ImageOwnerLease
}

package struct ImageCacheKey: Hashable, Sendable {
    let source: URL
    let pixelWidth: Int
    let pixelHeight: Int
    let configurationID: MarkdownConfigurationID
}

@MainActor
package final class SnapshotLeaseTransaction {
    let owners: [any ResourceResidencyOwner]
    func commit(
        _ install: ([any ResourceResidencyOwner]) throws -> Void
    ) rethrows
    func cancel()
}

@MainActor
package final class ImageResidencyLedger {
    static let shared = ImageResidencyLedger(hardLimit: 192 << 20, cacheLimit: 128 << 20)
    func reserveDecodedPixelBytes(_ bytes: Int) -> DecodedPixelReservation?
    func completedImage(for key: ImageCacheKey) -> OwnedImage?
    func acquireCacheLease(for backingID: UUID, key: ImageCacheKey) -> ImageOwnerLease?
    func evictCacheEntry(for key: ImageCacheKey)
    func handleMemoryPressure()
    func prepareSnapshotReplacement(
        session: RenderSessionID,
        oldSnapshotID: UUID?,
        newSnapshotID: UUID,
        images: [OwnedImage]
    ) -> SnapshotLeaseTransaction?
}
```

Identity is the physical decoded backing allocation, not merely the semantic cache key. `DecodedPixelReservation.promote` atomically transfers predecode cost into one backing record plus an in-flight owner after successful reconciliation; it never returns a naked `ImageBacking`. A completed-cache hit also acquires and returns an `OwnedImage` before exposing its backing, so cache eviction cannot create an unowned interval. `prepareSnapshotReplacement` consumes those in-flight owners and admits new publication owners while the old snapshot's independent publication leases remain charged. `commit(_:)` synchronously invokes its install closure on `MainActor` while retaining the new owners; the closure must build a `RenderSnapshot` that retains those same owners and install it into the sink. Only after the closure returns does the transaction release its temporary references. It never explicitly releases the old snapshot's owners. `cancel` releases only newly prepared owners. If concurrent sessions decode the same key into two backings, charge both unless canonicalization discards one before exposure. Cache eviction/memory pressure explicitly release only cache-owner leases. Final owner release alone uncharges the backing.

Every `ImageOwnerLease` delegates to one idempotent `ResidencyRecordToken`; explicit `release()` is the normal path and token `deinit` is the safety fallback, so rejection, cancellation, thrown materialization, or an abandoned transaction cannot strand ledger cost or decrement twice. Tests trace exact owner counts for decode→promotion→cache insertion, direct publication, rejected publication, cache hit followed by eviction, snapshot replacement commit/cancel, memory pressure, and session teardown.

After all remote-image paths use `ImageOwnerLease`, delete Task 2's `LegacyResourceOwner` declaration from `Sources/MarkdownRenderKit/ResolvedResource.swift`. Math/SVG keep their Task 4C `RenderedResourceLease`; all three resource kinds therefore enter every published snapshot with an explicit owner.

On `MainActor`, the session brings the originating `RenderCommitToken` and prepared transaction to `RenderSessionSinkRegistry.withAuthorizedSink(for:)`. The registry compares against its currently authorized token and promotes the weak sink in that same synchronous operation. Only inside the authorized closure does the session call `transaction.commit`, materialize `RenderSnapshot` with its owners, and invoke `sink.replaceSnapshot(_:token:)`; there is no suspension between token comparison, lease commit, and installation. The view first clears old TextKit content, installs/strongly retains the new snapshot, then returns; only then may the old snapshot deinitialize and release its own leases. If authorization fails, materialization throws, or no current sink exists, the transaction cancels and no snapshot is exposed. Completed/negative-cache writes and resource error callbacks use the same registry authorization primitive, so a driver-authorized replacement invalidates all old-token side effects even before the session actor processes its replacement event. Teardown first revokes authorization/cancels in-flight transactions, then clears TextKit/current snapshot on `MainActor`; snapshot lifetime—not a ledger-side early release—determines when publication cost is removed.

Add a gate-controlled test that pauses after session preparation but before the MainActor authorization closure, authorizes a new configuration token, and proves the old token cannot install, write either cache, invoke the callback, or commit leases. A second gate pauses inside replacement and proves the old backing remains alive/charged until old TextKit content is cleared and the old snapshot is released. Also cover a disappearing sink before commit, thrown materialization, stale publication, an externally retained old snapshot, and teardown; in every case charge persists exactly as long as a snapshot/attachment owner exists and eventually returns to baseline.

`DecodedImage` wraps Task 2's single audited `ImmutableCGImageBacking`; it never contains `UIImage`/`NSImage`. Materialize the platform image inside `DecodedPixelReservation.promote` on `MainActor` and reconcile the backing's accounted bytes before promotion.

Keep deterministic image failures in a separate 128-entry LRU with a five-minute TTL. Scheme/MIME/metadata violations may enter it; cancellation, timeout, admission busy, connectivity, and budget/downsample deferral may not. Include configuration ID in the key and clear expired entries through the injected clock.

Run `swift test --filter ImageResidencyLedgerTests`; expected PASS for owner counts, eviction, memory pressure, transaction commit/cancel, physical-backing double charge, and last-owner release.

- [ ] **Step 5: Exercise 100-image ownership transitions**

Publish valid images, evict their cache ownership while attachments still display them, and assert ledger cost stays charged. Request additional images and assert smaller thumbnails/placeholders preserve the 192 MiB limit. Replace snapshots and dismantle views; assert ledger and queued work return to baseline. Measure process peak separately so allocator/framework overhead is reported but not confused with the decoded-pixel contract.

Use the Step 1 100-image fixture to assert transfer/decode concurrency, 80 MiB encoded reservations, 192/128 MiB decoded/cache limits, cache eviction while published, memory-pressure cache-owner release, failed transaction rollback, atomic snapshot commit, and teardown baseline. Rerun it after each lifecycle slice until the original RED cases pass.

- [ ] **Step 6: Verify and commit**

```bash
swift test --filter 'ImageResourceCoordinatorTests|ImageResidencyLedgerTests|ImageAdversarialTests|MarkdownImageLoaderTests'
swift test
swift build -c release -Xswiftc -warnings-as-errors
test -z "$(rg -n '\bLegacyResourceOwner\b' Sources)"
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
git add Sources/MarkdownPlatformView Sources/MarkdownRenderKit/RenderSnapshot.swift Sources/MarkdownRenderKit/ResolvedResource.swift Tests/MarkdownKitTests
git commit -m "feat: bound markdown image residency"
```

- [ ] **Step 7: Review checkpoint 5B**

Dispatch `superpowers-reviewer` with critical resource-ownership focus. Require proof of deadlock freedom, hard accounted-pixel limits across cache and published attachments, physical-backing identity, atomic snapshot swaps, and teardown reclamation.

### Task 8: Add a typed link policy and main-actor activation

**Files:**
- Create: `Sources/MarkdownPlatformView/MarkdownLinkPolicy.swift`
- Modify: `Sources/MarkdownPlatformView/RenderSessionTypes.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownRenderSession.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView+iOS.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView+macOS.swift`
- Modify: `Sources/MarkdownKit/MarkdownText.swift`
- Modify: `Sources/MarkdownKit/MarkdownStreamingText.swift`
- Test: `Tests/MarkdownKitTests/MarkdownLinkPolicyTests.swift`

**Interfaces:**
- Consumes: configuration ID/generation rules and platform bridge.
- Produces: `MarkdownLinkPolicy`, `MarkdownLinkDisposition`, and `@MainActor MarkdownLinkHandler` configured through SwiftUI.

- [ ] **Step 1: Write allow/reject, actor, and replacement tests**

Assert default HTTP/HTTPS allow, other schemes reject, invalid URLs remain readable non-interactive text, policy evaluation is pure/Sendable, activation runs on `MainActor`, and policy/handler replacement prevents an old decision from activating.

Run `swift test --filter MarkdownLinkPolicyTests`. Expected: FAIL because typed policy/handler contracts do not exist.

- [ ] **Step 2: Implement pure policy and isolated handler contracts**

```swift
public protocol MarkdownLinkPolicy: Sendable {
    func disposition(for request: MarkdownLinkRequest) -> MarkdownLinkDisposition
}

public struct MarkdownLinkRequest: Sendable {
    public let url: URL
    public let sourceRange: MarkdownSourceRange?
    public let sessionGeneration: UInt64
}

public enum MarkdownLinkDisposition: Sendable, Equatable {
    case allow(URL)
    case reject
}

@MainActor
public protocol MarkdownLinkHandler: AnyObject {
    func open(_ url: URL)
}

@MainActor
public struct MarkdownLinkConfiguration {
    package let policy: any MarkdownLinkPolicy
    package let handler: any MarkdownLinkHandler
    public let policyID: MarkdownConfigurationID
    public let handlerID: MarkdownConfigurationID
    public init(
        policy: any MarkdownLinkPolicy,
        handler: any MarkdownLinkHandler,
        policyID: MarkdownConfigurationID = .uniqueInstance(),
        handlerID: MarkdownConfigurationID = .uniqueInstance()
    )
}

public struct WebOnlyMarkdownLinkPolicy: MarkdownLinkPolicy {
    public static let `default` = Self()
    public func disposition(for request: MarkdownLinkRequest) -> MarkdownLinkDisposition
}

public extension MarkdownLinkPolicy where Self == WebOnlyMarkdownLinkPolicy {
    static var webOnly: Self { .default }
}

@MainActor
public final class PlatformMarkdownLinkHandler: MarkdownLinkHandler {
    public init()
    public func open(_ url: URL)
}
```

Include the current session generation in activation metadata. Revalidate generation immediately before calling the handler. Default handler delegates only an allowed HTTP/HTTPS URL to `UIApplication`/`NSWorkspace`. The configuration wrapper owns both identities: custom policy/handler instances are unique by default, even if conformers expose identical internal labels; the `.webOnly` convenience supplies the built-in policy's deterministic semantic ID while leaving a custom handler uniquely identified unless the caller explicitly opts into semantic sharing. Add collision regressions for two custom policy and handler instances.

Run the pure policy and main-actor handler subset of `MarkdownLinkPolicyTests`; expected PASS before view wiring.

- [ ] **Step 3: Wire platform and SwiftUI APIs**

Replace direct `UIApplication.shared.open`/`NSWorkspace.shared.open` calls with session policy evaluation and handler activation. Add `.markdownLinkPolicy(_:handler:)`; expose `WebOnlyMarkdownLinkPolicy.default` as `.webOnly` convenience. Policy or handler replacement bumps the session generation; revalidate both IDs and generation immediately before activation. Document that a custom scheme needs both explicit policy permission and handler support.

Add `RenderSessionEvent.replaceLinkConfiguration(policyID:handlerID:)` and store the actual policy/handler in the main-actor driver; the event carries immutable IDs/generation into the session while activation returns through the driver after revalidation.

Run `swift test --filter MarkdownLinkPolicyTests`; expected PASS, including replacement and bypass-search assertions.

- [ ] **Step 4: Verify and commit**

```bash
swift test --filter MarkdownLinkPolicyTests
swift test
swift build -c release -Xswiftc -warnings-as-errors
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
git add Sources/MarkdownPlatformView Sources/MarkdownKit Tests/MarkdownKitTests/MarkdownLinkPolicyTests.swift
git commit -m "feat: enforce markdown link policy"
```

- [ ] **Step 5: Review checkpoint 5C**

Dispatch `superpowers-reviewer` for Task 8, focusing on TOCTOU generation checks, actor isolation, readable rejected links, and absence of direct opener bypasses.

### Task 9: Make normal Copy exact and source copy explicit

**Files:**
- Create: `Sources/MarkdownPlatformView/MarkdownCopyResult.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownSelection.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView+iOS.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView+macOS.swift`
- Modify: `Sources/MarkdownRenderKit/RenderDisplayModel.swift`
- Create: `Sources/MarkdownKit/MarkdownSelectionProxy.swift`
- Create: `Sources/MarkdownKit/MarkdownSelectionReader.swift`
- Create: `Sources/MarkdownPlatformView/Resources/en.lproj/Localizable.strings`
- Create: `Sources/MarkdownPlatformView/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Package.swift` to process localization resources
- Test: `Tests/MarkdownKitTests/MarkdownCopyTests.swift`
- Test: `Tests/MarkdownMathTests/ReadOnlyCopyOriginalSourceTests.swift`

**Interfaces:**
- Consumes: precise display/source mapping and current native selection.
- Produces: `MarkdownCopyResult`, `MarkdownCopyGranularity`, `copyRenderedSelection()`, `copyMarkdownSourceSelection()`, `MarkdownSelectionProxy`, and localized source-copy command.

- [ ] **Step 1: Encode the complete copy matrix as failing tests**

Cover partial plain/styled text, unresolved image placeholder, resolved image alt/source fallback, inline/display math without object-replacement characters, table TSV, cross-block partial ranges, and programmatic IR without source. Assert normal Copy never expands to a full source block; explicit source copy returns exact syntax or reports `.blockExpanded`/`.renderedFallback`.

Run `swift test --filter 'MarkdownCopyTests|ReadOnlyCopyOriginalSourceTests'`. Expected: new matrix cases FAIL under the existing block-expanded Copy behavior.

- [ ] **Step 2: Define typed results and semantic text runs**

```swift
public enum MarkdownCopyGranularity: Sendable, Equatable {
    case exact, blockExpanded, renderedFallback
}

public struct MarkdownCopyResult: Sendable, Equatable {
    public let text: String
    public let granularity: MarkdownCopyGranularity
}
```

Add source ranges and semantic copy representations to display runs. Attachments provide semantic rendered text separately from original Markdown syntax. Tables expose ordered cell text so rendered selection serializes cells with tabs and rows with newlines.

Run the pure serialization subset of `MarkdownCopyTests`; expected PASS for text, attachment, math, table, cross-block, and fallback granularity.

- [ ] **Step 3: Separate platform commands**

Make native `copy(_:)`/Cmd-C serialize exact rendered selection. Add a context-menu/command entry backed by `copyMarkdownSourceSelection()`. Put `Copy Markdown Source` and `复制 Markdown 源码` in target resources and allow host title overrides.

Expose the same operation to SwiftUI without pasteboard coupling:

```swift
@MainActor
public final class MarkdownSelectionProxy {
    package weak var view: MarkdownLabelView?
    public var renderedSelection: MarkdownCopyResult? { view?.renderedSelectionResult() }
    public var markdownSourceSelection: MarkdownCopyResult? { view?.markdownSourceSelectionResult() }
    public func copyMarkdownSourceToPasteboard() { view?.copyMarkdownSource(nil) }
}
```

Define `MarkdownSelectionReader<Content: View>` in its named file, mirroring the editor reader's `@State` proxy ownership and environment/platform attachment, so programmatic clients can inspect granularity before copying.

Run `swift test --filter 'MarkdownCopyTests|ReadOnlyCopyOriginalSourceTests'`; expected PASS for platform commands and proxy results.

- [ ] **Step 4: Verify and commit**

```bash
swift test --filter 'MarkdownCopyTests|ReadOnlyCopyOriginalSourceTests'
swift test
swift build -c release -Xswiftc -warnings-as-errors
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
git add Package.swift Sources/MarkdownPlatformView Sources/MarkdownRenderKit/RenderDisplayModel.swift Sources/MarkdownKit/MarkdownSelectionProxy.swift Sources/MarkdownKit/MarkdownSelectionReader.swift Tests/MarkdownKitTests/MarkdownCopyTests.swift Tests/MarkdownMathTests/ReadOnlyCopyOriginalSourceTests.swift
git commit -m "feat: separate rendered and source copying"
```

- [ ] **Step 5: Review checkpoint 6**

Dispatch `superpowers-reviewer` over Task 9. Require exact selection boundaries, attachment/math/table semantics, explicit fallback reporting, localized commands, and 0.1.x behavior-change coverage.

### Task 10: Build a stable, non-duplicating accessibility tree

**Files:**
- Modify: `Sources/MarkdownRenderKit/AccessibilityNode.swift`
- Modify: `Sources/MarkdownRenderKit/RenderDisplayModel.swift`
- Create: `Sources/MarkdownPlatformView/MarkdownAccessibility+iOS.swift`
- Create: `Sources/MarkdownPlatformView/MarkdownAccessibility+macOS.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView+iOS.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView+macOS.swift`
- Test: `Tests/MarkdownKitTests/MarkdownAccessibilityModelTests.swift`
- Test: `Tests/MarkdownKitTests/MarkdownAccessibilityPlatformTests.swift`
- Modify: `Example/ExampleUITests/ExampleUITests.swift`
- Modify: `Tests/runtime-test-manifest.json`

**Interfaces:**
- Consumes: display blocks/runs, source generation, parser lineage, TextKit layout frames.
- Produces: `AccessibilityTree`, stable `AccessibilityNodeID`, platform virtual elements, focus restoration, and optional coalesced streaming announcements.

- [ ] **Step 1: Write semantic-tree and golden traversal failures**

Build a fixture containing headings, lists, a paragraph with two links plus image and inline math, code metadata, and a table. Assert exact exposed-leaf order and speech strings: container labels exclude interactive child ranges, links/images/math are independently focusable, and table cells carry headers/coordinates without a duplicate aggregate overlay.

Run `swift test --filter 'MarkdownAccessibilityModelTests|MarkdownAccessibilityPlatformTests'`. Expected: FAIL because the semantic tree builder and platform virtual elements do not exist.

- [ ] **Step 2: Populate the stable lineage types introduced in Task 2**

```swift
public enum AccessibilityTreeBuilder {
    public static func build(
        blocks: [DisplayBlock],
        sourceGeneration: UInt64,
        linkGeneration: UInt64
    ) -> AccessibilityTree
}
```

Never include a growing end offset in identity. Preserve lineage for safe streaming append; start a new source generation on replacement. Split non-interactive paragraph text into exposed leaves around interactive descendants.

Run `swift test --filter MarkdownAccessibilityModelTests`; expected PASS for the golden semantic tree and growing-tail IDs.

- [ ] **Step 3: Map semantic leaves to platform accessibility objects**

On UIKit use virtual `UIAccessibilityElement`s owned by the label; on AppKit use `NSAccessibilityElement`s. Derive frames from TextKit layout fragments and provide hit testing/activation metadata. Diff by node ID and reuse platform objects. Exclude visual table overlay objects from accessibility exposure.

Localize generic image/math/error fallback labels in English and Simplified Chinese through the Task 9 resource bundle, and expose host overrides. Alt text always takes precedence over a generic image label.

Run the frame/hit-test/traversal subset of `MarkdownAccessibilityPlatformTests`; expected PASS on macOS, then run the same suite through the iOS package scheme.

- [ ] **Step 4: Preserve focus during streaming**

If the focused ID survives, keep the same platform object even when its end range grows. If removed, choose the nearest surviving semantic neighbor. Add repeated-append tests for a focused growing final paragraph and table. Keep streaming announcements off by default; when enabled, coalesce to one polite new-content announcement per committed batch through an injected clock.

Run `swift test --filter 'MarkdownAccessibilityModelTests|MarkdownAccessibilityPlatformTests'`; expected PASS for focus reuse/fallback and announcement coalescing.

- [ ] **Step 5: Run platform tests and commit**

```bash
swift test --filter 'MarkdownAccessibilityModelTests|MarkdownAccessibilityPlatformTests'
swift test
swift build -c release -Xswiftc -warnings-as-errors
mkdir -p .artifacts
HARDENING_RESULT_DIR="$(mktemp -d .artifacts/accessibility.XXXXXX)"
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro' -only-testing:MarkdownKitTests/MarkdownAccessibilityPlatformTests -resultBundlePath "$HARDENING_RESULT_DIR/Accessibility-iOS18.xcresult"
xcodebuild test -project Example/Example.xcodeproj -scheme Example -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro' -only-testing:ExampleUITests
Scripts/assert-xcresult-tests.sh ios18-accessibility "$HARDENING_RESULT_DIR/Accessibility-iOS18.xcresult"
git add Sources/MarkdownRenderKit Sources/MarkdownPlatformView Tests/MarkdownKitTests Tests/runtime-test-manifest.json Example/ExampleUITests
git commit -m "feat: expose structured markdown accessibility"
```

- [ ] **Step 6: Review checkpoint 7A**

Dispatch `superpowers-reviewer` for semantic correctness and focus stability. Require a non-duplicating exposed-leaf sequence, immutable identity anchors, correct table relationships, real layout frames, and platform activation tests.

### Task 11: Add Dynamic Type and adaptive attachment/layout behavior

**Files:**
- Modify: `Sources/MarkdownRenderKit/RenderStyle.swift`
- Modify: `Sources/MarkdownRenderKit/RenderConfiguration.swift`
- Modify: `Sources/MarkdownRenderKit/RenderPreparer.swift`
- Modify: `Sources/MarkdownRenderKit/RenderMaterializer.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView+iOS.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView+macOS.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownTableOverlay.swift`
- Test: `Tests/MarkdownKitTests/DynamicTypeTests.swift`
- Test: `Tests/MarkdownKitTests/AdaptiveLayoutTests.swift`
- Modify: `Example/ExampleUITests/ExampleUITests.swift`
- Modify: `Tests/runtime-test-manifest.json`

**Interfaces:**
- Consumes: immutable typography roles and session configuration replacement.
- Produces: preferred-style default typography, custom-font scaling helper, trait-driven snapshot rebuilds, and non-overlapping maximum-size layouts.

- [ ] **Step 1: Write scaling and maximum-layout failures**

Assert default body/code/h1–h6 metrics grow monotonically from `.large` to accessibility categories; custom fixed fonts remain fixed unless wrapped by the scaling helper. At maximum category, render long paragraphs, code, wide tables, image/math attachments, and assert positive/non-overlapping fragment bounds with horizontal table scrolling retained.

Run `swift test --filter 'DynamicTypeTests|AdaptiveLayoutTests'`. Expected: FAIL because current fixed default point sizes do not scale.

- [ ] **Step 2: Define semantic typography tokens and scaling helper**

```swift
public enum MarkdownContentSizeCategory: Sendable, Equatable {
    case extraSmall, small, medium, large, extraLarge, extraExtraLarge, extraExtraExtraLarge
    case accessibilityMedium, accessibilityLarge, accessibilityExtraLarge
    case accessibilityExtraExtraLarge, accessibilityExtraExtraExtraLarge
}

@MainActor
public struct MarkdownScaledFont {
    public init(base: PlatformFont, relativeTo role: MarkdownTextRole)
    public func resolve(contentSizeCategory: MarkdownContentSizeCategory) -> PlatformFont
}
```

Build default iOS fonts from preferred text styles/metrics. Scale line spacing, paragraph spacing, heading borders, code insets, attachment bounds, and table chrome from the same category snapshot. Preserve documented fixed custom styles unless explicitly scaled.

Run `swift test --filter DynamicTypeTests`; expected PASS for default monotonic metrics and custom-font opt-in behavior.

- [ ] **Step 3: Rebuild through session configuration on trait changes**

Observe iOS content-size-category and relevant display-scale/color traits. Produce a new immutable render configuration generation and send one replacement event; do not mutate cached renderers or replace host custom style objects. On macOS, respond to accessibility text/display changes supported by the target runtime.

Run `swift test --filter 'DynamicTypeTests|AdaptiveLayoutTests'`; expected PASS for generation replacement and non-overlapping maximum-size layout.

- [ ] **Step 4: Capture and inspect required screenshots**

Run the Example on the iOS 18 simulator at normal and maximum Dynamic Type in light/dark modes and capture normal content, wide table, loading image, math, and SVG screens. Dispatch the configured `ios-visual-reviewer` with screenshot paths and source files; fix clipping, overlap, hierarchy, or polish findings before proceeding.

- [ ] **Step 5: Verify and commit**

```bash
swift test --filter 'DynamicTypeTests|AdaptiveLayoutTests'
swift test
swift build -c release -Xswiftc -warnings-as-errors
mkdir -p .artifacts
HARDENING_RESULT_DIR="$(mktemp -d .artifacts/dynamic-type.XXXXXX)"
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro' -only-testing:MarkdownKitTests/DynamicTypeTests -only-testing:MarkdownKitTests/AdaptiveLayoutTests -resultBundlePath "$HARDENING_RESULT_DIR/DynamicType-iOS18.xcresult"
xcodebuild test -project Example/Example.xcodeproj -scheme Example -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro' -only-testing:ExampleUITests
Scripts/assert-xcresult-tests.sh ios18-dynamic-type "$HARDENING_RESULT_DIR/DynamicType-iOS18.xcresult"
git add Sources/MarkdownRenderKit Sources/MarkdownPlatformView Tests/MarkdownKitTests Tests/runtime-test-manifest.json Example/ExampleUITests
git commit -m "feat: support adaptive markdown typography"
```

- [ ] **Step 6: Review checkpoint 7B**

Dispatch `superpowers-reviewer` over Task 11 after visual findings are resolved. Require Dynamic Type through accessibility sizes, preserved custom-style semantics, and layout/screenshot evidence.

### Task 12: Finish deterministic tests, documentation, migration, and release gates

**Carried from Task 7 (checkpoint 5B), disclosed rather than fixed there:**

- ~~`Scripts/run-static-gates.sh` cannot exit 0 while `Sources/MarkdownRenderKit/RenderConfiguration.swift` fails `swiftformat --lint`.~~ Cleared during Task 8 (commit `249cad0`, labelled `style:`); `run-static-gates.sh` now exits 0 and is wirable as a CI gate. What was checked, precisely: `git diff -w` on that commit is *not* empty — it leaves 18 insertions / 8 deletions, all brace expansion, trailing-paren placement, and `self.` on three unshadowed stored properties (`resolvedDefault` correctly did not get one, being an `if let` rebinding). The file contains no `"""` literals, so `-w` cannot be hiding a semantic whitespace change inside a multiline string, and `MarkdownConfigurationID`'s `"instance:…"` / `"semantic:…"` raw-value formats — the values link-configuration replacement detection compares — are byte-identical. Note the cost: `RenderConfiguration.swift` is a Task 11 modify-target, so the reformat widens Task 11's conflict surface.
- `SnapshotLeaseTransaction.commit` releases the owners an install declined. Deleting that release loop leaves every image test green, because `ResidencyRecordToken`'s `deinit` uncharges once the last reference drops — so the uncharge would silently move from deterministic-at-commit to whenever ARC runs. The over-release direction is covered by tests; the positive direction needs one that holds a strong reference to a declined owner and asserts it is already uncharged.
- `Scripts/check-image-ownership.sh` is a lexical, name-based gate and two bypasses are known open: a container that erases or parameterizes its element type (`[String: Any]`, `Store<PlatformImage>`) names no forbidden symbol, and the residency-owner inventory matches on name only, so a same-named type in another module would pass. Neither yields a platform image outside the ten audited files.
- `eventually`'s anti-hang budget is 180 s and `settle`'s is 400 rounds because two pre-existing tests run 60–120 s on the iOS simulator. Replacing the polling with deterministic gates is this task's item; the budgets can come back down with it.
- `Scripts/check-image-ownership.sh` uses a non-nesting block-comment pattern, so a nested block comment produces a false positive. Fail-closed, and `Sources` has no nested block comments today.
- Task 7's checkpoint review closed at **REVISE with "I would accept the checkpoint" and no merge-blocking findings**, not at a literal PASS. Six review rounds were spent (the brief allowed five; the sixth was user-authorised because round 5 was itself unreviewed). Final review notes are in `.superpowers/sdd/2026-09-07-library-hardening/task-7-report.md`, which is untracked — this list is the tracked record.

**Carried from Task 10 (checkpoint 7A), disclosed rather than fixed there:**

- **The SwiftUI path may expose the document as one element.** The view itself exposes one element per semantic leaf — measured on the iOS 18 simulator, four elements with distinct labels, distinct TextKit frames and working activation — but hosted inside `UIHostingController`, XCUITest's tree shows `_UIHostingView` with a single accessibility element and `app.staticTexts.count == 1`. Two documented remedies were tried and neither changed that count: `.accessibilityElement(children: .contain)` on the representable, and `accessibilityContainerType = .semanticGroup` on the view. Both were reverted rather than left in, since neither could be shown to do anything. **What is not established is which tree VoiceOver traverses**: XCUITest's element tree and VoiceOver's traversal are not the same thing, and this environment cannot run VoiceOver. So the UIKit-level capability is verified and the SwiftUI-level outcome is unknown — not known to be broken. Resolving it needs a device with VoiceOver, and if it is broken the fix is real subviews rather than virtual elements.
- Leaf identity is `(sourceGeneration, role, startAnchor, lineage, ordinal)`, where the ordinal counts leaves *within a block* and is advanced when a leaf begins rather than when it is emitted. That rule is mirrored in two places — `AccessibilityTreeBuilder` and `RenderPreparer`'s run tagging — because the tree says what a reader stops on and the runs say where that stop is on screen. Nothing but `everyLeafIsTaggedOnTheRunsThatRenderIt` stops them drifting, and a drift means an element pointing at the wrong place, which no other test would notice. It caught three real mismatches while being written: list markers, table-cell inlines, and the block separator, whose newline segment sits at the end of the *previous* line and stretched the next block's first element up into it.
- A table too wide for the view keeps only a placeholder character in the main document; its cells are laid out in the overlay's own text stack, so their frames are read from there and converted. That means element frames for an overflowing table depend on `_syncTableOverlays` having run, which is why the rebuild is called from there as well as from `replaceSnapshot`.
- Streaming announcements (plan Step 4's coalesced polite announcements through an injected clock) are **not implemented**. Focus preservation is: surviving leaves keep their platform object, pinned by `appendingReusesThePlatformObjectsOfSurvivingLeaves`. The announcement half is off by default per the plan, and nothing announces today.
- `AccessibilityTreeBuilder.roots` takes a `BlockNode` rather than the plan's `[DisplayBlock]`: `DisplayBlock` flattens a table to a list of cell texts with no rows or columns and drops a link's destination, so it cannot describe either. `MarkdownRenderKit` also gained its own resource bundle for the two fallback labels rather than reaching into the one Task 9 added to `MarkdownPlatformView`, which sits above it.

**Carried from Task 9 (checkpoint 6), disclosed rather than fixed there:**

- Task 9 closed at **REVISE with "nothing merge-blocking"** after **six** review rounds (the brief allowed five; the sixth was user-authorised). The round-6 fixes in `d20666f` are themselves unreviewed, and the user authorised proceeding to Task 10 with that outstanding — the same shape as Tasks 7 and 8. Rounds 1–4 each found a Critical living in the *previous round's fix*; every one was the same mistake, treating something that looked obvious as proved (index adjacency implies byte adjacency, a range includes its indentation, the last block reaches the end of the document, a new field has the same maintenance sites as an old one). Two of the regression tests written for those defects could not fail on them, and one review round had to point that out.

- `MarkdownCopyGranularity.exact` means the copy is the contiguous source region between the selection's endpoints, and is only claimed when **both** boundary bytes are provable. Contiguous is not the same as "only what the selection covers": source that belongs to no block — a reference definition between two selected paragraphs — stays in, deliberately, because dropping it would leave `[text][ref]` links in the copy unresolvable. The doc comment now says this instead of "nothing more". `.blockExpanded` means the selection cut into a block: `InlineNode` carries no source ranges — only blocks do — so a partial selection inside a block cannot be extracted. Giving inline runs real source offsets is a `MarkdownCore` change, out of this task's file list.
- Two facts about `sourceRange` make naive boundary arithmetic wrong, and both were found by review after being asserted as safe here. **A range starts at the block's *content column*, not its line start** — `IncrementalParseState` records the same fact and reparses the indentation — so taking the lower bound verbatim drops an indented code block's indent and the copy stops parsing as code. The boundary now walks back over spaces and tabs to the line start. **Source can belong to no block at all**: a link reference definition produces no `ParsedBlockNode`, so index adjacency does not imply byte adjacency, and bracketing to a neighbour's bound handed over a URL the document renders nowhere. The start boundary now comes from `sourceAnchor`, which math backfill preserves from the block a rebuilt block came from, and never from a neighbour.
- **Deviation from this task's file list:** `MarkdownCore` was not in it, and `ParsedBlockNode` gained `sourceAnchorEnd` anyway. (Nine other files outside the literal list were touched — the two SwiftUI views, three `MarkdownRenderKit` files, four test files — but each is required by this task's own Steps 2 and 3, so `MarkdownCore` is the only real deviation.) Round 3 of review found the interim rule — treat "the last selected block is the last block" as proof that its bytes reach the end of the document — copying a trailing reference definition and calling it `.exact`, which is the same defect as the one before it. Both the leak and the capability loss came from a rebuilt block having no recorded end, and `MathBackfill.resolve` already had `node.sourceRange` in scope while deliberately nil'ing it, so carrying the end costs one stored property with the same lifetime as `sourceAnchor` (`IncrementalParseState` shifts it with the anchor). Degrading the product to stay inside a file list was the worse trade. A rebuilt run shares one anchor and one end, so both are usable only when the run starts and ends where the selection does — and a *run* is the pieces of one origin block, identified by that `(anchor, end)` pair, not merely adjacent source-less blocks. Grouping by adjacency alone (as the first version did) merged two neighbouring formulas and left neither copyable although each had both boundaries of its own.

- **The deviation cost one site more than recorded.** The record first argued the new property was safe because it had "the same lifetime as `sourceAnchor`". That was false in the incremental path and is what hid the defect: `sourceAnchor` is maintained by **two** mechanisms — the window shift in `IncrementalParseState`, *and* `equivalentForSplice` via `lineage` — while the new field had only the first. A splice therefore kept nodes whose origin block's end had moved, so a streamed document copied different bytes than the same source parsed at once (measured: `"text $x$  "` came back as `"text $x$"`, dropping a hard line break, still labelled `.exact`). `sourceAnchorEnd` is now compared in the splice guard directly — not folded into `lineage`, which is a fixed-size identity key that deliberately hashes no end and which Task 10's accessibility IDs will inherit. Anyone adding another position field needs **three** sites, not two: the window shift, `MathBackfill.resolve`, and `MarkdownDocument.init(parsedBlocks:)`, which rebuilds through the package init and omits `sourceAnchorEnd`/`splitOrdinal` (harmless today because only placeholder-anchored nodes reach it). `streamedAnchorsMatchAFullParse` and `streamingProducesTheSameCopyAsSettingTheWholeSource` pin the invariant that `ParsedBlockNode ==` cannot see.
- `documentOrdinal` had the same gap one field later and was fixed the same way: it is the flag saying an anchor is a placeholder, and the window shift was dropping it, which would have turned a placeholder into a real-looking offset. Unreachable today — no construction site produces a nil range for a top-level block — so it is a defensive carry, pinned by `aPlaceholderAnchorIsNeverUsedAsABoundary`, which drives `markdownSourceCopy` directly because nothing reaches that shape through the views.
- The upper boundary's end proof is `runEnd(upper) == upper` plus the contiguity `equivalentForSplice` maintains; the `splitOrdinal` conjunct beside it proves the run *starts* at piece 0, not that it ends where claimed. `ParsedBlockNode` records no piece count, so nothing stronger is expressible, and removing `runEnd` would hand over a missing last piece's bytes. The conjunct also refuses a run that is a valid *suffix* of an origin block, which the previous round accepted: a deliberate fail-closed narrowing on a shape not reachable in production.
- A recorded syntax is substituted per *key* run, not per attribute-dictionary run. Judging dictionary runs let a selection clipped at an image placeholder's **start** paste the image's URL, because the `🖼 ` marker's `.markdownCopySkip` splits the syntax run and the second half looked complete on its own. Found by the test written for the opposite direction; the round before had recorded "nothing splits a syntax run today", which was false.
- Reconstruction (`$$latex$$`, `![alt](source)`, ```` ```svg ````) is approximate — emphasis and links have already lost their delimiters — and is **always** reported `.renderedFallback`; no path calls it source. It is clamped to the selection, like the plain fallback: reconstructing whole blocks pasted an image URL for a three-character selection. A recorded syntax stands in for a run only when the selection covers that run whole, for the same reason. It joins blocks with a blank line, because a single newline is one paragraph in Markdown.
- `.markdownCopyText` substitution is only valid for one-character runs, because `renderedCopyText` emits the whole value for any sub-range that touches it. The invariant is structural, not merely tested: every application goes through `attachment(...)`, which builds a one-character string, or the one-character overflow-table placeholder. `everyCopyTextRunIsExactlyOneCharacter` guards the two placeholder paths a headless test can reach; the resolved image/math/SVG paths never resolve headlessly. It still earned its place — it failed on its first run, when a fix for the load-state inconsistency had attached the key to a 6-character placeholder. Decorative text a reader *does* see — the `🖼 ` marker on an unloaded image — is dropped with `.markdownCopySkip` instead, so a copy does not change meaning depending on whether the image loaded.
- On iOS the localized source-copy command reaches the **main menu only** (iPad and Mac Catalyst menu bar). The iPhone selection callout is presented by `UITextInteraction`, not built from this responder's `buildMenu(with:)`. The concrete consequence: on iPhone, a UIKit host with no SwiftUI wrapper and no menu of its own has **no user-reachable way to copy source** — `canPerformAction` returns true but nothing presents it. Adding a `UIEditMenuInteraction` beside the one `UITextInteraction` manages was not attempted, because a double-presented callout cannot be verified headlessly here; it belongs in the runtime-verification list. macOS has a real context menu, which now *adds* to the host's rather than replacing it.
- `MarkdownSelectionProxy.copyMarkdownSourceToPasteboard()` is an untested seam. Both halves are covered — the result path by the copy suite, the selector's reachability by the command test — but the pasteboard write itself is not, deliberately: `ReadOnlyCopyOriginalSourceTests` records the decision not to touch the system pasteboard in tests because it is unreliable headless. What is uncovered is the weak-view nil case and the write.
- `MarkdownCopyCommandTitle` is a mutable `@MainActor` static: safe from data races, but process-global, so two hosts in one process cannot differ. An environment entry alongside `markdownSelectionProxy` would match the house pattern. `MarkdownCopyGranularity`/`MarkdownCopyResult` also live in `MarkdownPlatformView`, so a `MarkdownKit`-only consumer must add an import to name `.blockExpanded`.
- Rendered copy joins blocks with the single `"\n"` the materializer inserts, so copying two paragraphs yields `"a\nb"` rather than a blank-line-separated pair. Plan Step 2 specifies only cell and row separators, so this was a judgement call, but it is reader-visible.
- `Package.swift` gained `resources:` and `defaultLocalization`, so every consumer now gets a `MarkdownKit_MarkdownPlatformView` resource bundle. With the macOS context-menu change, that is the 0.1.x → 0.2.0 integration-surface list for this task.
- The parity goldens strip the three copy keys before comparing (`strippingCopyMetadata`): they change no glyph but do split runs at boundaries the fixtures never had. The goldens therefore no longer pin copy-run structure.
- `markdownSourceForRenderedSelection` is deleted. It had become a thin forwarder to `markdownSourceCopy`, so describing it as an insulated legacy path — as both its comment and this record did — was false: it carried every change made to the new algorithm. The two parity assertions call `markdownSourceCopy` directly with the fallbacks disabled. The per-view `_copiedStringForCurrentSelection*` seams are also gone, and the assertions that rested on them drive `markdownSourceSelectionResult()`.
- The first `xcodebuild test` of the Example scheme after `Package.swift` gained `resources:` failed every UI test with `Cannot launch simulated executable: no file found at …/Example.app`; two later runs passed unchanged. **The cause is unknown, and the log rules out the stale-install explanation first recorded here**: `ExampleTests/smokeMarkdownParsesOneHeading()` — hosted *in* `Example.app` — passed on Clone 1 in that same run, so the app was present and launchable. Only Clone 2, the UI-test runner, failed, and immediately before the first failure the log shows `IDELaunchParametersSnapshot: … DebuggerLLDB.DebuggerVersionStore.StoreError error 0` and `no debugger version`, suggesting launch-parameter resolution failed first and "no file found" is the downstream symptom. Logs: `.artifacts/task-9-example.log` (failing) and `.artifacts/task-9-example-retry.log`. It recurred once more, four fix rounds later, with a *different* signature — the UI-test **runner** was refused launch (`FBSOpenApplicationServiceErrorDomain Code=1`, `RequestDenied` from `SBMainWorkspace`) rather than the app being missing — and again passed on an unchanged retry (`.artifacts/task-9-r4-example.log`, `…-retry.log`). Two different signatures, both at simulator launch, both transient: treat the Example UI suite as needing a retry on this host rather than as a signal about the package.

**Carried from Task 8 (checkpoint 5C), disclosed rather than fixed there:**

- Task 8 closed at **REVISE with "nothing I found is merge-blocking"**, not a literal PASS, after **six** review rounds (the brief allowed five; the sixth was user-authorised). The round-6 fixes in `8f9b633` are themselves unreviewed — the user authorised proceeding to Task 9 with that outstanding. Same shape as Task 7's close.
- The review reports for Tasks 7 and 8 are gone: `.superpowers/sdd/2026-09-07-library-hardening/` and `.artifacts/` were destroyed when a review subagent passed the worktree path as the fixture root of `prove-link-activation-gate.sh`, whose `rm -rf "$root"` was unguarded. Committed work was untouched. The script now lives in `Scripts/` with a guard refusing any root outside the scratchpad. These carried blocks are the only surviving record of both tasks' findings, which is why they are here and not there.

- Deviation from this task's Step 3: the plan specifies `RenderSessionEvent.replaceLinkConfiguration(policyID:handlerID:)`. The implemented case carries no payload, because the driver is the sole owner of the live policy/handler and shipping the IDs into the session would create a second copy that can disagree with it. The session generation *is* still bumped by the mutation, as the plan requires — what deviates is the plan's "revalidate both IDs and generation immediately before activation": activation revalidates `linkConfigurationRevision` instead, a counter bumped by every link-configuration install and by nothing else. `configurationGeneration` also moves on width and style changes, so a generation-based guard rejected in-flight decisions that no replacement had invalidated.
- `send(.replaceLinkConfiguration)` fires only when an identity differs, but when it does fire the session performs a full document reparse for state it never reads. Deliberate: the session's mutation channel has no cheaper "driver-only" lane today, identity-equal installs are already filtered out before the send, and adding a lane touches Task 4's mutation contract. If Task 12 measures reparse cost on link-configuration churn, this is the first candidate.
- The SwiftUI representables forward the link configuration on every body evaluation, so `linkConfigurationRevision` bumps on every update and a body evaluation landing inside an in-flight decision voids that tap, with no feedback to the reader. This is the deliberate fail-closed side of the round-3 Critical (suppressing the forward on equal identities left a superseded policy deciding). The window is one executor hop: measured over 200 activations, 30 µs median, 47 µs p95, 197 µs max. Comparing that to a 120 Hz cadence of 8.3 ms would understate it, because the two events are **not** independent — a streaming chunk or a scroll updates the body precisely when the main actor is free, which is exactly the window; `MarkdownStreamingText` under active streaming is the exposed case. Reviewer-proposed alternative, deliberately not taken in Task 8: on a revision mismatch, re-decide against the *current* configuration with a bounded retry instead of returning. It drops nothing and stays fail-closed (a tightened policy simply rejects on the retry), but it changes activation semantics that this task's plan specifies and that two tests pin — `replacementDuringEvaluationPreventsTheOldDecisionFromActivating` and `anInFlightDecisionDoesNotSurviveAnEqualIdentityReplacement`, both in `Tests/MarkdownKitTests/MarkdownLinkPolicyTests.swift`, which a retry would break by opening through the current handler. Whichever task takes this must rewrite those two first. Note also that the *drop rate* is unmeasured: the 30 µs figure is decision latency, not observed dropped activations, so measure before changing semantics.
- Clearing the environment entry now reverts a view to `.platformDefault`, on the non-nil→nil edge only. Round 5 found the third shape of the round-3 fail-open here — a host writing `trusted ? config : nil` against one stable view identity kept the permissive configuration it had installed earlier (measured: the revoked policy opened a `myapp://` link a second time). Edge-triggered rather than `?? .platformDefault`, so a view that never had a configuration does not re-install one on every body evaluation and take on the revision-bump window above. Pinned by `clearingTheConfigurationRevertsTheViewToTheWebOnlyDefault`.
- `MarkdownLabelView.linkConfiguration` is non-optional, so a UIKit/AppKit host has no "clear" and revokes by assigning `.platformDefault`; only the SwiftUI environment entry reverts by itself. The `package convenience init(frame:driver:)` also installs a driver without seeding it from the view's configuration, so the two can disagree from birth — test-reachable only, fails closed, and it is the "second source of truth" shape the payload-free mutation case exists to avoid.
- `MarkdownLinkRequest.configurationGeneration` is carried for a policy's own use and is **not** revalidated; the public doc previously promised the opposite. Activation gates on `linkConfigurationRevision` alone, so a host policy must not assume that a width change, a style change or a source replacement voids an in-flight tap.
- Two protections that no test or gate names, and that a plausible refactor would silently remove. `MarkdownLabelView.canPerformAction` returns `false` for every action except `copy(_:)`, which is what keeps the iOS edit menu from offering Share / Look Up / Translate on a rendered link; widening it to `super` reopens that. And both editor highlight passes use `setAttributes` over the whole document, which *replaces* attributes and therefore erases any `.link` run a detector or a paste left behind; changing it to `addAttributes` removes a backstop nobody documented. Both now carry a one-line comment saying so.
- `MarkdownLinkRequest.sourceRange` is always `nil`: the rendered attributed string carries no source mapping at activation time. The field is in the public shape the plan specifies, and Task 9 introduces the display/source mapping that could fill it. A policy must not treat `nil` as "no such range".
- Links inside a horizontally-scrolling wide table cannot be activated at all: `MarkdownTableOverlay` puts a draw-only `TableContentView` inside a scroll view that intercepts the tap before the label's recognizer. Fail-closed, so not a security gap, but it is an activation gap alongside the pre-existing double-activation notes below, and it belongs to whichever task revisits table overlays.
- `Scripts/check-link-activation.sh` is a regression tripwire, not a proof. Its material limit is **name coverage**: an opener whose name is not in the inventory is invisible, and every review round so far has found names that were missing — round 2 found four, round 3 found seven more (`NSTextField`, SwiftUI `Text` carrying a `.link` run, `Process`/`posix_spawn`, `UIDocumentInteractionController`, `UIActivityViewController`, `SFAuthenticationSession`, `NSSharingService`), all now inventoried. The `Text` family is the instructive one: SwiftUI opens a `.link` run through the environment's `OpenURLAction` with no opener identifier in the source at all, so it is reachable only by confining the *views* that can render such a run — which works here only because `Sources` uses SwiftUI `Text` nowhere outside the one inventoried file. Round 4 found seven more (`NSAppleScript`, `NSDocumentController`, `NSHelpManager`, `SKStoreProductViewController`, `MFMailComposeViewController`, `dataDetectorTypes`, and `_LSOpenURLsWithRole` — the last a *pattern* hole rather than a missing name: a leading `\b` does not match an underscore-prefixed identifier, which is house style in this package). Round 5 added four names (`popen`, `ShareLink`, `TextEditor`, `TextField`) and round 6 added the rest of the field-editor family (`NSSearchField`, `NSComboBox`, `NSTokenField`, `UISearchBar`, `UISearchTextField`), which reach a text view under other names for the same reason `NSTextField` does. `system` is deliberately left out: the word is too common to inventory without false positives. **The macOS link-detection pair is *not* in the inventory** — `isAutomaticLinkDetectionEnabled` and `toggleAutomaticLinkDetection` are pinned by `theEditorStorageNeverCarriesALinkAttribute` alone, because a lexical gate cannot tell `= true` from `= false`. Do not read the gate as covering them. The proof runs 36 probes across five rounds of families. Secondary limits: a call assembled from string interpolation, a name reached through `NSClassFromString`, and a **function-typed indirection** such as `var open: ((URL) -> Void)?` — which names nothing at all, and is the shape `MarkdownLinkHandler` itself has, so a second one is a natural thing to write. `Tests` is out of scope by design. All of these are stated in the script.
- The gate exempts `MarkdownEditorTextView.swift` from the text-view inventory. That exemption rested on a comment claiming `isRichText = false` neutralises a `.link` run, which review measured to be false: `isRichText` governs user-applied attributes, not `setAttributedString`. The invariant that actually holds is that `MarkdownSourceHighlighter` styles links with `.foregroundColor` and never emits `.link`, and it is now pinned by `theEditorStorageNeverCarriesALinkAttribute` rather than by a comment. That test also asserts the runtime values a lexical gate cannot judge, because it cannot tell an enabling assignment from a disabling one: `dataDetectorTypes` empty and `allowsEditingTextAttributes`/`isRichText` false. Note the asymmetry this leaves: `dataDetectorTypes` *is* in the gate's inventory, so a maintainer writing the defensive `dataDetectorTypes = []` will be rejected by the gate — that rejection is the instrument working, not a bug in their change.
- Round 5 found that the exemption's macOS half was still open, and the measurement is worth keeping: `isRichText = false` does not gate NSTextView link detection, and the standard **Edit > Substitutions > Smart Links** menu item calls `toggleAutomaticLinkDetection` on a plain-text view. After that, typing a URL puts a real `.link` run in the storage (measured: one run at `{4, 19}`), which AppKit's default click handling opens — no code change and no host cooperation required. Closed three ways on macOS: the delegate implements `textView(_:clickedOnLink:at:)` returning `true`, `applyOptions()` sets `isAutomaticLinkDetectionEnabled = false` (there rather than in `commonInit`, so the `editorOptions` `didSet` re-asserts it on every options change), and `PlatformEditorTextView` overrides `toggleAutomaticLinkDetection` to a no-op. Round 6 added the iOS counterpart the first fix lacked: `textView(_:primaryActionFor:defaultAction:)` returning `nil`. iOS needed it for a reason macOS does not — on iOS the exported class *is* the `UITextView`, so a host can set `dataDetectorTypes` on it directly, and `dataDetectorTypes` takes effect exactly when `isEditable == false`, which `MarkdownEditorOptions` makes a supported configuration. All four are pinned by `theEditorStorageNeverCarriesALinkAttribute` and each was mutation-tested individually.
- `PlatformMarkdownLinkHandler` reports a policy/handler scheme mismatch with `assertionFailure` rather than `onMarkdownResourceError`. Considered and declined: `.shared` is a process-wide singleton with no session affinity, so it has no error sink to report to, and `MarkdownResourceFailure` categorises resource *loads* (transport, timeout, type mismatch). A policy that allows a scheme its handler refuses is a host wiring mistake with no runtime recovery, which is what a debug trap is for.
- Pre-existing platform behaviours this task did not change, confirmed non-blocking in review: a double tap on iOS activates twice, and on macOS `mouseUp` after a drag-selection that ends inside a link activates it. Rejected links keep their link styling and stay readable, which is the specified behaviour, not a defect.

**Files:**
- Modify: remaining files under `Tests/MarkdownKitTests` and `Tests/MarkdownMathTests` containing `Task.sleep`
- Modify: `Example/Sources/ContentView.swift`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `CONTRIBUTING.md`
- Modify: public declarations under `Sources/`
- Modify: `.github/workflows/ci.yml`
- Modify: `Tests/runtime-test-manifest.json`
- Create: `docs/release/0.2.0-accessibility-checklist.md`
- Create: `docs/release/0.2.0-runtime-evidence.md`
- Create: `docs/release/0.2.0-migration.md`

**Interfaces:**
- Consumes: all prior public APIs and gates.
- Produces: deterministic full suite, complete changed-API documentation, migration guide, archived runtime/manual evidence, and release-ready CI.

- [ ] **Step 1: Remove every remaining timing-polling test**

Run `rg -n 'Task\.sleep' Sources Tests Example`. Retain the single randomized sleep in `Example/Sources/ContentView.swift` as deliberate user-visible token pacing and document it beside the call. Replace every test poll with actor gates, `confirmation`, injected clocks, or explicit session drain APIs. Add a repository test that fails if `Task.sleep` occurs under `Tests/`.

- [ ] **Step 2: Complete public API and migration documentation**

Document parameters, isolation, errors, replacement semantics, security limits, complexity, and configuration IDs for every new/changed public declaration. In the migration guide cover removed renderer caches/unchecked contracts, remote-image opt-in, link policy, normal Copy reversal, explicit source-copy granularity, Dynamic Type custom-font behavior, and iOS 18/macOS 15 floors.

- [ ] **Step 3: Update README, CHANGELOG, CONTRIBUTING, and Example**

Show secure opt-in code:

```swift
MarkdownText(markdown)
    .markdownRemoteImages(.defaultHTTPS)
    .markdownLinkPolicy(.webOnly, handler: PlatformMarkdownLinkHandler())
```

Document real CI commands and runtime fallback evidence. Add Example controls for image opt-in, Dynamic Type/accessibility fixtures, source copy, link rejection, and streaming stress. Ensure errors shown in the demo use category/sanitized origin only.

- [ ] **Step 4: Execute full automated verification**

```bash
swiftformat --lint Package.swift Sources Tests Example/Sources Example/ExampleTests Example/ExampleUITests
swift test
swift build -c release -Xswiftc -warnings-as-errors
mkdir -p .artifacts
HARDENING_RESULT_DIR="$(mktemp -d .artifacts/final-ios18.XXXXXX)"
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro' -resultBundlePath "$HARDENING_RESULT_DIR/MarkdownKit-iOS18-final.xcresult"
xcodebuild test -project Example/Example.xcodeproj -scheme Example -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro' -resultBundlePath "$HARDENING_RESULT_DIR/Example-iOS18-final.xcresult"
Scripts/assert-xcresult-tests.sh ios18-final "$HARDENING_RESULT_DIR/MarkdownKit-iOS18-final.xcresult" "$HARDENING_RESULT_DIR/Example-iOS18-final.xcresult"
Scripts/check-unchecked-sendable.sh
Scripts/check-validated-image-construction.sh
test -z "$(rg -n '\bLegacyResourceOwner\b' Sources)"
test -z "$(rg -n 'Task\.sleep' Tests)"
```

Expected: format clean, 0 test failures, release build succeeds without warnings, the manifest's required package/Example targets and iOS-only behavior cases execute with nonzero counts and zero skips on iOS 18, production has exactly the approved unchecked adapter, validated image construction has no bypass, and no test sleep remains. Each invocation creates a fresh result directory, so Step 7 and post-review reruns cannot collide with an existing bundle. Record that run's directory/artifact hashes, asserted target/case list, and Xcode/Swift/OS/runtime identifiers in the runtime evidence document; run and assert the manifest's macOS section on macOS 15.

On the `[self-hosted, macOS, ARM64, macos-15, xcode-26]` runner execute this mandatory gate and upload its log:

```bash
set -o pipefail
sw_vers -productVersion | rg '^15\.'
swift --version | rg 'Swift version 6\.2'
swift test 2>&1 | tee macos15-swift-test.log
swift build -c release -Xswiftc -warnings-as-errors 2>&1 | tee macos15-release.log
mkdir -p .artifacts
HARDENING_RESULT_DIR="$(mktemp -d .artifacts/final-macos15.XXXXXX)"
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=macOS' -resultBundlePath "$HARDENING_RESULT_DIR/MarkdownKit-macOS15-final.xcresult"
Scripts/assert-xcresult-tests.sh macos15 "$HARDENING_RESULT_DIR/MarkdownKit-macOS15-final.xcresult"
```

`docs/release/0.2.0-runtime-evidence.md` records the artifact names and SHA-256 hashes. Missing OS assertions, logs, hashes, or a nonzero command makes the release gate fail.

- [ ] **Step 5: Complete manual accessibility and visual evidence**

On the actual supported runtimes, record VoiceOver traversal/speech, Voice Control Show Names/Numbers, Full Keyboard Access, representative Switch Control traversal, focus continuity during streaming, source-copy commands, and maximum Dynamic Type. Attach screenshot paths and the visual-review result to release documentation.

- [ ] **Step 6: Commit documentation and final gates**

```bash
git add Sources Tests Example README.md CHANGELOG.md CONTRIBUTING.md .github docs/release
git commit -m "docs: prepare MarkdownKit 0.2 release"
```

- [ ] **Step 7: Assert committed evidence and a clean tree**

Use `superpowers:verification-before-completion` to rerun the Step 4 automated commands and compare their outputs with the already committed evidence. Do not edit evidence after this point. Require `test -z "$(git status --porcelain)"` before review.

- [ ] **Step 8: Run final complete-diff review until stable**

Dispatch `superpowers-reviewer` with node `finishing-a-development-branch`, the pre-implementation `BASE_SHA`, final `HEAD_SHA`, the spec/plan paths, committed runtime evidence, and screenshot review. Process feedback via `superpowers:receiving-code-review`. After any code/document change, rerun all affected focused gates plus the complete Step 4/macOS 15 gates, update evidence, commit a new HEAD, assert a clean tree, and dispatch the reviewer again. Continue until the latest HEAD receives non-`BLOCK` approval and all evidence matches that HEAD.

- [ ] **Step 9: Finish the branch and open the PR**

Use `superpowers:finishing-a-development-branch`, select the user-approved integration option, open the PR with the migration/security summary and evidence, then immediately use `auto-fix-pr-after-implementation` for the review/fix/threaded-reply loop.

## Checkpoint-to-Audit Coverage

| Checkpoint | Audit IDs | Primary proof |
|---|---|---|
| 1A–1B | E1, E2, T1, S1, R1 | Dedicated formatting commit, CI, real runtime, non-template tests, `RTK.md` |
| 2 + 4C | C2, M1 | Compile-time actor/value boundaries plus removal of every legacy unchecked/mutable render path |
| 3, 4A–4C | C1, M2, T2 | Blocking parser, teardown/churn, behavior-only extraction, thin platform views, session-owned resources |
| 4 | P1 | Differential fixtures and byte-work budgets |
| 5A–5C | N1 | Transport security, deadlock-free budgets, residency leases, links |
| 6 | U1 | Exact rendered/source copy matrix |
| 7A–7B | A1, A2 | Golden semantic traversal, focus continuity, Dynamic Type screenshots |
| 8/final | D1 and all rows | Full gates, docs/migration, actual-runtime and manual evidence |
