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
- Create: `.github/workflows/ci.yml`
- Create: `Scripts/check-platform-floors.sh`
- Create: `RTK.md`
- Modify: `Example/Example.xcodeproj/project.pbxproj`
- Replace: `Example/ExampleTests/ExampleTests.swift`
- Replace: `Example/ExampleUITests/ExampleUITests.swift`

**Interfaces:**
- Consumes: real schemes `MarkdownKit-Package`, `MarkdownKit`, `MarkdownMath`, and `Example`.
- Produces: iOS 18/macOS 15 targets, non-template smoke tests, deterministic floor checks, and mandatory actual-runtime CI evidence.

- [ ] **Step 1: Record missing delivery gates**

```bash
test -f RTK.md
test -f .github/workflows/ci.yml
test -x Scripts/check-platform-floors.sh
```

Expected: all three checks fail before the files are created.

- [ ] **Step 2: Lower package and Example deployment targets**

Set `platforms: [.iOS(.v18), .macOS(.v15)]`, `IPHONEOS_DEPLOYMENT_TARGET = 18.0`, and `MACOSX_DEPLOYMENT_TARGET = 15.0`. Implement `check-platform-floors.sh` to parse `swift package dump-package` and the Xcode build settings, failing unless all exact floors match.

- [ ] **Step 3: Replace empty tests with executable smoke assertions**

Make the Example unit test parse `# Smoke` and assert one heading. Give the root demo `markdownkit.example.root` and make the UI test launch and locate it. Run the two focused test commands and expect PASS.

- [ ] **Step 4: Add mandatory actual-runtime CI**

Use a self-hosted runner labelled `[self-hosted, macOS, ARM64, macos-15, xcode-26]` for the macOS 15 job. Before testing, require `sw_vers -productVersion` to start with `15.`, `swift --version` to report 6.2, and selected Xcode to report 26.x. For iOS, require `xcrun simctl list runtimes available` to contain iOS 18.0 and run both package and Example schemes on `iPhone 16 Pro,OS=18.0`. A missing label/runtime fails; no job uses `continue-on-error`.

Each runtime job writes `runtime-metadata.txt` containing `host_os`, `xcode_version`, `swift_version`, `simulator_runtime`, `scheme`, `git_sha`, and `result`, and uploads it together with `.xcresult`/test logs. `RTK.md` documents identical local/VM commands and the artifact schema.

- [ ] **Step 5: Run the green delivery gate and commit**

```bash
chmod +x Scripts/check-platform-floors.sh
Scripts/check-platform-floors.sh
swift test
swift build -c release -Xswiftc -warnings-as-errors
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
xcodebuild test -project Example/Example.xcodeproj -scheme Example -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
git add Package.swift .github/workflows/ci.yml Scripts/check-platform-floors.sh RTK.md Example
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

`MarkdownRenderConfiguration` owns cache identity rather than trusting a custom `RenderStyle` to report one. Each custom wrapper gets `.uniqueInstance()` by default; only an explicit caller-supplied semantic ID may share completed entries. Built-in configurations derive a deterministic semantic ID from every normalized style token. `LegacyResourceOwner` is a temporary main-actor retention adapter used only by Task 4B so pre-migration image/math/SVG attachments remain alive; Task 4C deletes it after all resources use explicit owners.

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
package struct ParseJob: Sendable {
    let token: ParseSessionToken
    let revision: UInt64
    let configurationGeneration: UInt64
    let source: String
}

package enum ParseExecutorResult: Sendable {
    case parsed(revision: UInt64, document: MarkdownDocument)
    case busy
    case stale
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

`enqueue` returns an admission value immediately; there are no suspended submit continuations. It registers a weak result sink, replaces the token's pending job in place, and emits `.stale` for the superseded revision through the registry. `start` creates `Task.detached { [parser, job] in ParseWorkerOutput(job: job, document: parser(job)) }`; the executor immediately stores that handle, so it is never unowned. A separate executor-owned monitor awaits `worker.value` and calls `complete`; synchronous cmark never blocks the actor. The worker captures exactly the immutable parser function and `ParseJob`, not a session/view/cache/callback. `complete` applies active→pending/idle, publishes by token through the weak registry, and treats absent/tombstoned tokens as stale. `tombstone` removes waiting work/result registration immediately or marks active state; active completion drops output and removes remaining registry state.

Run `swift test --filter ParseExecutorTests`; expected PASS for global/per-token limits, coalescing, actor responsiveness, and tombstone transitions.

- [ ] **Step 3: Implement session revision and retry state**

Create a session actor whose stored state is immutable/Sendable and whose publication sink is a weak main-actor registry token:

```swift
package actor MarkdownRenderSession: ParseResultSink {
    func setSource(_ source: String, configuration: RenderConfigurationSnapshot) async
    func append(_ chunk: String) async
    func replaceConfiguration(_ configuration: RenderConfigurationSnapshot) async
    func dismantle() async
}

package enum RenderSessionEvent: Sendable {
    case setSource(String, RenderConfigurationSnapshot)
    case append(String)
    case replaceConfiguration(RenderConfigurationSnapshot)
    case dismantle
}

package enum RenderSessionError: Error, Sendable, Equatable {
    case parseBusy
    case preparationFailed
}

@MainActor
package protocol RenderSessionSink: AnyObject {
    func receive(snapshot: RenderSnapshot, revision: UInt64)
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
    func register(_ sink: any RenderSessionSink, for id: RenderSessionID)
    func unregister(_ id: RenderSessionID)
    func publish(_ snapshot: RenderSnapshot, revision: UInt64, to id: RenderSessionID)
}

@MainActor
package final class MarkdownRenderSessionDriver {
    private let session: MarkdownRenderSession
    private let continuation: AsyncStream<RenderSessionEvent>.Continuation
    private let pump: Task<Void, Never>
    package init(session: MarkdownRenderSession)
    package func send(_ event: RenderSessionEvent) { continuation.yield(event) }
}
```

Every session command mutates state, calls `enqueue`, and returns without awaiting cmark completion. The driver is the sole strong owner of its session. Its pump is created with `Task { [weak session] in ... }`; each loop iteration promotes that weak reference only for one short actor command, then drops it before waiting for the next event. Thus the stored pump cannot keep either driver or session alive. The driver owns the pump; `deinit` finishes/cancels it and releases its strong session property. The session's one retry task uses `[weak self]` plus immutable token/input; it promotes `self` only after each clock tick and for one retry command, so the stored task never creates a session→task→session cycle. Gate received results on source revision/configuration generation. Teardown cancels retry, clears pending input, tombstones the executor token, and unregisters both result and snapshot sinks.

Run `swift test --filter MarkdownRenderSessionTests`; expected PASS for retry, weak sink, generation, driver teardown, and newest-only publication.

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

Move source-selection helpers, table overlay/layout helpers, and iOS `UITextInput` helper types to their named files without renaming symbols or changing access. After each move rerun the Step 1 command; each run must remain green.

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
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView+iOS.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView+macOS.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownRenderSession.swift`
- Modify: `Sources/MarkdownKit/MarkdownText.swift`
- Modify: `Sources/MarkdownKit/MarkdownStreamingText.swift`
- Test: `Tests/MarkdownKitTests/PlatformSessionWiringTests.swift`

**Interfaces:**
- Consumes: Task 3 `MarkdownRenderSessionDriver` and Task 2 snapshots.
- Produces: thin platform views that synchronously enqueue `RenderSessionEvent` values and receive snapshots through the weak sink registry.

- [ ] **Step 1: Write and run the failing driver wiring tests**

Inject a `RecordingSessionDriver` conforming to:

```swift
@MainActor
package protocol RenderSessionDriving: AnyObject {
    func send(_ event: RenderSessionEvent)
}

extension MarkdownRenderSessionDriver: RenderSessionDriving {}
```

Assert set, append, style/renderer change, scale change, and teardown each emit one ordered event; old sink tokens cannot apply snapshots. Run `swift test --filter PlatformSessionWiringTests`; expected FAIL because views do not accept the driver.

- [ ] **Step 2: Install the driver and weak sink**

Replace duplicated parse tasks/revision fields/direct source update pipelines with one driver. The session/result registries are the single authority for current revision and generation; a stale result is discarded before main-actor publication. Views therefore do not maintain an independent revision counter that can diverge. Apply snapshots only through:

```swift
func receive(snapshot: RenderSnapshot, revision: UInt64) {
    precondition(revision >= currentSnapshotRevision)
    currentSnapshotRevision = revision
    currentSnapshot = snapshot
    contentStorage.attributedString = snapshot.attributedString
    synchronizePlatformSelectionAndOverlays(snapshot)
}
```

Both platform views conform to `RenderSessionSink` and strongly retain the current snapshot for at least as long as TextKit retains its attachments. The monotonic assertion is diagnostic only; it is not a second acceptance guard. Dismantle clears TextKit content/current snapshot, sends `.dismantle`, unregisters the sink ID, and releases the driver. Wrap every legacy image/math/SVG object referenced by the published attributed string in Task 2's `LegacyResourceOwner`; add regression coverage proving those resources do not disappear during the migration. Keep old resource cache adapter calls until Task 4C.

- [ ] **Step 3: Run focused green and commit**

```bash
swift test --filter 'PlatformSessionWiringTests|MarkdownLabelViewRenderModeTests|TableMeasurementLaidOutEquivalenceTests'
swift test
swift build -c release -Xswiftc -warnings-as-errors
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
git add Sources/MarkdownPlatformView Sources/MarkdownKit/MarkdownText.swift Sources/MarkdownKit/MarkdownStreamingText.swift Tests/MarkdownKitTests/PlatformSessionWiringTests.swift
git commit -m "refactor: route platform views through render sessions"
```

- [ ] **Step 4: Review session migration**

Dispatch `superpowers-reviewer` over Task 4B with event ordering, weak sink ownership, stale snapshot rejection, driver task ownership, and UIKit/AppKit parity focus.

### Task 4C: Migrate math/SVG resources and remove compatibility render APIs

**Files:**
- Modify: `Sources/MarkdownPlatformView/MathLoadCoordinator.swift`
- Modify: `Sources/MarkdownPlatformView/SVGBlockLoadCoordinator.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownRenderSession.swift`
- Delete: `Sources/MarkdownRenderKit/AttributedStringRenderer.swift`
- Modify: `Sources/MarkdownRenderKit/RenderStyle.swift`
- Modify: `Sources/MarkdownRenderKit/MarkdownSourceHighlighter.swift`
- Modify: `Sources/MarkdownRenderKit/MathRendering.swift`
- Modify: `Sources/MarkdownRenderKit/SVGBlockRendering.swift`
- Modify: `Sources/MarkdownMath/MathJaxRenderer.swift`
- Modify: `Sources/MarkdownMath/SVGRasterizer.swift`
- Modify: `Sources/MarkdownMath/SwiftDrawSVGBlockRenderer.swift`
- Test: existing math/SVG coordinator, renderer, streaming, and cache suites

**Interfaces:**
- Consumes: Task 2 compatibility adapter and Task 4B session ownership.
- Produces: explicit renderer configuration IDs, session-owned in-flight work, bounded completed/negative caches, injected clocks, and no old mutable renderer cache surface.

- [ ] **Step 1: Write and run failing identity/ownership tests**

Add cases proving equal semantic renderer IDs share completed results, different/unique IDs isolate them, two sessions do not share in-flight tasks, replacement bumps generation, and cancellation/transient failures are not negative-cached. Run the focused math/SVG suites; expect new cases to fail.

```bash
swift test --filter 'MathLoadCoordinatorTests|SVGBlockLoadCoordinatorTests|SharedCoordinatorTests'
```

Expected: FAIL on identity, cross-session ownership, or bounded-negative-cache assertions.

- [ ] **Step 2: Move in-flight work into the session**

Remove `.shared` task ownership. Keep completed caches injectable with 256-entry LRU bounds. Keep deterministic failures for 60 seconds in a 128-entry LRU using an injected clock. Include `MarkdownConfigurationID` in every key and gate completion/cache writes by generation.

- [ ] **Step 3: Migrate all producers and delete the Task 2 adapter**

Make `MathRendererConfiguration` and `SVGRendererConfiguration` own identity: custom instances remain unique unless the caller explicitly supplies a versioned semantic ID, while built-in MathJax/SwiftDraw/SVGRasterizer configurations derive deterministic IDs from all normalized settings. Replace platform-image cross-actor outcomes with immutable render descriptions or Task 2's single audited `ImmutableCGImageBacking`; materialize images on `MainActor`. Move source-highlighter style access to main-actor snapshots. After every consumer compiles, delete `LegacyResourceOwner`, the complete legacy `AttributedStringRenderer` file, mutable renderer caches/generation fields, compatibility overloads, and unjustified `@unchecked Sendable` from `RenderStyle`.

- [ ] **Step 4: Replace touched sleeps and run green**

Replace the four product debounce sleeps with one driver/session-owned task using an injected clock. Convert touched math/SVG test polling to gates/confirmations.

```bash
swift test --filter 'MathLoadCoordinatorTests|SVGBlockLoadCoordinatorTests|SharedCoordinatorTests|AsyncMathWritebackRelayoutTests|StreamingMathCacheSurvivesRendererRecreationTests|StreamingSVGBlockCacheSurvivesRendererRecreationTests'
swift test
swift build -c release -Xswiftc -warnings-as-errors
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
git add Sources/MarkdownPlatformView Sources/MarkdownRenderKit Sources/MarkdownMath Tests
git commit -m "refactor: move rendered resources into sessions"
```

- [ ] **Step 5: Review checkpoint 3B**

Dispatch `superpowers-reviewer` from Task 4B head through Task 4C head. Require no compatibility API remains, all MarkdownMath producers compile, renderer identities are stable, caches are bounded, and in-flight work/clocks are session-owned.

### Task 5: Make safe streaming work near-linear

**Files:**
- Create: `Sources/MarkdownCore/IncrementalParseState.swift`
- Create: `Sources/MarkdownCore/IncrementalSourceBuffer.swift`
- Create: `Sources/MarkdownCore/ParseWorkMetrics.swift`
- Modify: `Sources/MarkdownCore/DocumentParser.swift`
- Modify: `Sources/MarkdownCore/MathScanner.swift`
- Modify: `Sources/MarkdownCore/MathSentinel.swift`
- Modify: `Sources/MarkdownRenderKit/RenderPreparer.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownRenderSession.swift`
- Test: `Tests/MarkdownKitTests/IncrementalParseDifferentialTests.swift`
- Test: `Tests/MarkdownKitTests/IncrementalWorkBudgetTests.swift`
- Test: existing scanner/incremental suites

**Interfaces:**
- Consumes: session append chunks and immutable render preparation.
- Produces: `IncrementalSourceBuffer`, `IncrementalParseState`, package `IncrementalParseResult`, and package `ParseWorkMetrics` returned through the session diagnostics sink.

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

Replace complete-source `MathScanner.scan`/`codeRegionMask` calls on safe append with state resumption. Parse only the invalidated tail, offset its source ranges, preserve stable prefix blocks, and have `MarkdownRenderSession` invoke the package `RenderPreparer.prepare(_:changedBlocks:metrics:)` production entry point for only `changedBlockRange`. Reuse the prior lineage when a reparsed block has the same immutable start anchor and semantic role, even if a paragraph/list/table end grows; allocate new lineage only for inserted/reclassified blocks. Check cancellation at fixed byte/block intervals in owned loops. Add a session-level spy/counter test proving append reaches this production entry point and that unchanged prefix blocks contribute zero preparation bytes; do not satisfy the test by invoking a helper directly.

Add this overload in Task 5, after `ParseWorkMetrics` exists:

```swift
package extension RenderPreparer {
    func prepare(
        _ input: RenderInput,
        changedBlocks: Range<Int>,
        metrics: inout ParseWorkMetrics
    ) throws -> RenderDisplayModel
}
```

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
git add Sources/MarkdownCore Sources/MarkdownRenderKit/RenderPreparer.swift Sources/MarkdownPlatformView/MarkdownRenderSession.swift Tests/MarkdownKitTests
git commit -m "perf: bound incremental markdown work"
```

- [ ] **Step 7: Review checkpoint 4**

Dispatch `superpowers-reviewer` with correctness/performance focus. Require it to inspect every counted phase, differential fallback coverage, cancellation intervals, and proof that no full-source work moved outside instrumentation.

### Task 6: Implement the isolated opt-in image transport

**Files:**
- Create: `Sources/MarkdownPlatformView/ResourceConfiguration.swift`
- Create: `Sources/MarkdownPlatformView/MarkdownImageLoader.swift`
- Create: `Sources/MarkdownPlatformView/URLSessionImageTransport.swift`
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

Tests assert remote URLs stay placeholders by default; enabling the built-in loader starts HTTPS only; equal built-in settings have equal semantic IDs; custom instances receive unique IDs; explicit versioned semantic IDs share only completed entries; replacement increments session generation and a late old result cannot publish, callback, or write a cache.

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
    package init(validatedData: Data, metadata: MarkdownImageMetadata)
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

Every loader result is untrusted `MarkdownImagePayload`. The session/coordinator always passes it through one package `ValidatedImageFactory`, including custom-loader results, before constructing `MarkdownEncodedImage`; the validated type has no public initializer. It contains at most 20 MiB encoded bytes and validated MIME/ImageIO metadata, never a platform image. Error callbacks have the exact `MarkdownResourceErrorHandler` signature and receive only a typed category plus scheme/host/port—never a raw URL, path, query, headers, response body, or underlying error.

The configuration wrapper, not a loader conformer, owns namespace identity. Custom loader wrappers get `.uniqueInstance()` by default even if two conformers are otherwise identical. `.defaultHTTPS` derives a deterministic semantic ID from the complete normalized built-in settings (timeouts, redirect/MIME policy, byte/metadata limits). Sharing requires an explicit caller-supplied versioned semantic ID. Add a regression with two custom loaders that intentionally report/carry the same internal label and prove their default wrappers cannot share cache entries.

Expose `.markdownRemoteImages(_:)` and `.onMarkdownResourceError(_:)` from `MarkdownResourceModifiers.swift`. The environment default is `.disabled`; `.defaultHTTPS` constructs the deterministic built-in semantic configuration.

Add `RenderSessionEvent.replaceImageConfiguration(MarkdownRemoteImageConfiguration)`; every event increments session generation even when its cache namespace ID remains semantically equal.

- [ ] **Step 3: Implement an isolated URLSession transport**

Build an ephemeral configuration with `httpCookieStorage = nil`, `urlCredentialStorage = nil`, `urlCache = nil`, `requestCachePolicy = .reloadIgnoringLocalCacheData`, and no implicit authentication. Use 15-second request and 30-second resource defaults, configurable within 1...120 seconds. Reject non-HTTPS initial/final/redirect URLs, non-2xx status, cross-host forwarded authorization/custom headers, disallowed MIME, and bodies beyond byte 20 MiB + 1 while streaming.

Run the scheme/status/redirect/cookie/credential/timeout subset of `MarkdownImageLoaderTests`; expected PASS before adding ImageIO metadata cases.

- [ ] **Step 4: Validate metadata before decode**

Use an incremental `CGImageSource` only for type and properties. Require declared MIME, detected UTI/type, and selected decoder agreement. With overflow-safe arithmetic reject either side over 8,192 px, more than 32 frames, or cumulative source pixels over 40 MP. Ensure rejected inputs never reach Task 7's full decoder.

Run the MIME/metadata/byte-limit subset immediately; expected PASS before proceeding to full transport verification.

- [ ] **Step 5: Verify with a controlled URLProtocol and commit**

Cover redirects, status, MIME/signature mismatch, cookies/credentials/cache isolation, sanitized errors, exact byte boundary, timeout, and cancellation using a custom `URLProtocol`; assert decoder invocation count remains zero for rejected cases.

```bash
swift test --filter 'MarkdownImageLoaderTests|ResourceConfigurationTests'
swift test
swift build -c release -Xswiftc -warnings-as-errors
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
git add Package.swift Sources/MarkdownPlatformView Sources/MarkdownKit Tests/MarkdownKitTests/MarkdownImageLoaderTests.swift Tests/MarkdownKitTests/ResourceConfigurationTests.swift
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
- Test: `Tests/MarkdownKitTests/ImageResourceCoordinatorTests.swift`
- Test: `Tests/MarkdownKitTests/ImageResidencyLedgerTests.swift`
- Test: `Tests/MarkdownKitTests/ImageAdversarialTests.swift`

**Interfaces:**
- Consumes: validated `MarkdownEncodedImage`, session revisions/configuration generations, unresolved display resources.
- Produces: explicit transfer/encoded/decode reservation tokens, main-actor backing/cache/publication leases conforming to Task 2 `ResourceResidencyOwner`, atomic snapshot replacement, bounded completed LRU, and resolved-resource snapshots.

- [ ] **Step 1: Write concurrency and hold-and-wait regressions**

With controllable transports/decoders, assert per-session maximum two transfers/one decode, process maximum four transfers/two decodes, and exactly 20 MiB reserved before each network start from an 80 MiB ledger. Two 17 MiB and four 9 MiB bodies must finish or remain unstarted; none may pause while holding a partial body. Add the complete 100-image adversarial fixture here, before production implementation, covering permit limits, reservation ceilings, promotion, cache publication/eviction, snapshot commit/cancel, memory pressure, and teardown-to-baseline.

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
    func commit()
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
    func releasePublishedSnapshots(session: RenderSessionID)
}
```

Identity is the physical decoded backing allocation, not merely the semantic cache key. `DecodedPixelReservation.promote` atomically transfers predecode cost into one backing record plus an in-flight owner after successful reconciliation; it never returns a naked `ImageBacking`. A completed-cache hit also acquires and returns an `OwnedImage` before exposing its backing, so cache eviction cannot create an unowned interval. `prepareSnapshotReplacement` consumes those in-flight owners, admits publication owners while the old snapshot remains charged, then releases the consumed owners. `commit` atomically swaps snapshot IDs and releases removed publication owners, while `cancel` releases only newly prepared publication owners. If concurrent sessions decode the same key into two backings, charge both unless canonicalization discards one before exposure. Cache eviction/memory pressure explicitly release only cache-owner leases. Final owner release alone uncharges the backing; session teardown calls `releasePublishedSnapshots`.

Every `ImageOwnerLease` delegates to one idempotent `ResidencyRecordToken`; explicit `release()` is the normal path and token `deinit` is the safety fallback, so rejection, cancellation, thrown materialization, or an abandoned transaction cannot strand ledger cost or decrement twice. Tests trace exact owner counts for decode→promotion→cache insertion, direct publication, rejected publication, cache hit followed by eviction, snapshot replacement commit/cancel, memory pressure, and session teardown.

On `MainActor`, the session prepares a transaction, materializes `RenderSnapshot` with `transaction.owners`, verifies the weak sink still exists/current, commits the ledger transaction, and synchronously publishes the snapshot; otherwise it cancels. The platform view retains that snapshot while TextKit retains its attributed string, so attachment backing cannot outlive its ownership lease unnoticed.

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
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
git add Sources/MarkdownPlatformView Sources/MarkdownRenderKit/RenderSnapshot.swift Tests/MarkdownKitTests
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
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
xcodebuild test -project Example/Example.xcodeproj -scheme Example -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro' -only-testing:ExampleUITests
git add Sources/MarkdownRenderKit Sources/MarkdownPlatformView Tests/MarkdownKitTests Example/ExampleUITests
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
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
xcodebuild test -project Example/Example.xcodeproj -scheme Example -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro' -only-testing:ExampleUITests
git add Sources/MarkdownRenderKit Sources/MarkdownPlatformView Tests/MarkdownKitTests Example/ExampleUITests
git commit -m "feat: support adaptive markdown typography"
```

- [ ] **Step 6: Review checkpoint 7B**

Dispatch `superpowers-reviewer` over Task 11 after visual findings are resolved. Require Dynamic Type through accessibility sizes, preserved custom-style semantics, and layout/screenshot evidence.

### Task 12: Finish deterministic tests, documentation, migration, and release gates

**Files:**
- Modify: remaining files under `Tests/MarkdownKitTests` and `Tests/MarkdownMathTests` containing `Task.sleep`
- Modify: `Example/Sources/ContentView.swift`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `CONTRIBUTING.md`
- Modify: public declarations under `Sources/`
- Modify: `.github/workflows/ci.yml`
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
xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
xcodebuild test -project Example/Example.xcodeproj -scheme Example -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
test -z "$(rg -n 'Task\.sleep' Tests)"
```

Expected: format clean, 0 test failures, release build succeeds without warnings, package and Example tests execute on iOS 18, and no test sleep remains. Record Xcode/Swift/OS/runtime identifiers and logs in the runtime evidence document; run the macOS suite on macOS 15.

On the `[self-hosted, macOS, ARM64, macos-15, xcode-26]` runner execute this mandatory gate and upload its log:

```bash
set -o pipefail
sw_vers -productVersion | rg '^15\.'
swift --version | rg 'Swift version 6\.2'
swift test 2>&1 | tee macos15-swift-test.log
swift build -c release -Xswiftc -warnings-as-errors 2>&1 | tee macos15-release.log
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
