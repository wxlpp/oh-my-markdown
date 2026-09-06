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
| Render boundary | new `RenderInput.swift`, `RenderDisplayModel.swift`, `ResolvedResource.swift`, `RenderSnapshot.swift`, `RenderConfiguration.swift`, `AccessibilityNode.swift`; modify `AttributedStringRenderer.swift`, `RenderStyle.swift`, math/SVG protocols | Pure background preparation and main-actor platform materialization |
| Session | new `ParseExecutor.swift`, `MarkdownRenderSession.swift`, `RenderSessionTypes.swift` | Revisions, coalescing, tombstones, task ownership, publication |
| Resources | new `ResourceConfiguration.swift`, `MarkdownImageLoader.swift`, `ImageResourceCoordinator.swift`, `ImageResidencyLedger.swift`, `MarkdownLinkPolicy.swift`; refactor math/SVG coordinators | Configuration generations, secure transport, permits, caches, leases, activation |
| Platform views | split `MarkdownLabelView.swift` into shared session bridge plus `MarkdownLabelView+iOS.swift`, `MarkdownLabelView+macOS.swift`, `MarkdownTextInput+iOS.swift`, `MarkdownSelection.swift`, `MarkdownTableOverlay.swift` | TextKit setup and native platform behavior only |
| Semantics | new `AccessibilityNode.swift`, `MarkdownAccessibility+iOS.swift`, `MarkdownAccessibility+macOS.swift`, `MarkdownCopyResult.swift` | Semantic tree, stable lineage, platform exposure, exact/source copy |
| SwiftUI/API | `MarkdownText.swift`, `MarkdownStreamingText.swift`, renderer modifiers; new image/link modifiers | High-level immutable configuration |
| Tests | focused suites named in each task plus Example UI tests | Behavior, lifecycle, budgets, accessibility, runtime gates |
| Docs/resources | README, CHANGELOG, CONTRIBUTING, DocC comments, `Resources/*/Localizable.strings` | 0.2.0 migration, security/privacy, commands, localized actions |

---

### Task 1: Establish a clean delivery and minimum-platform baseline

**Files:**
- Modify: `Package.swift`
- Modify: `.swiftformat`
- Create: `.github/workflows/ci.yml`
- Create: `RTK.md`
- Modify: `Example/Example.xcodeproj/project.pbxproj`
- Replace: `Example/ExampleTests/ExampleTests.swift`
- Replace: `Example/ExampleUITests/ExampleUITests.swift`
- Test: `Tests/MarkdownKitTests/PlatformBaselineTests.swift`

**Interfaces:**
- Consumes: current SwiftPM targets and Example scheme.
- Produces: iOS 18/macOS 15 deployment targets, reproducible local commands, zero-format gate, non-empty smoke tests, and CI jobs later tasks extend.

- [ ] **Step 1: Capture the failing baseline without changing sources**

Run:

```bash
swiftformat --lint Package.swift Sources Tests Example/Sources Example/ExampleTests Example/ExampleUITests
swift test
swift build -c release -Xswiftc -warnings-as-errors
test -f RTK.md
test -d .github/workflows
```

Expected: SwiftFormat reports the audited violations; Swift tests and release build pass; the last two checks fail because repository instructions and CI are missing.

- [ ] **Step 2: Lower every deployment target and add a manifest assertion**

Change the manifest header to:

```swift
let package = Package(
    name: "MarkdownKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
```

Add `PlatformBaselineTests` that reads `Package.swift` and asserts both exact floors so a later Xcode migration cannot silently raise them. Set `IPHONEOS_DEPLOYMENT_TARGET = 18.0` and `MACOSX_DEPLOYMENT_TARGET = 15.0` in every Example build configuration.

- [ ] **Step 3: Make formatting deterministic and remove template tests**

Run the formatter only over tracked Swift inputs:

```bash
swiftformat Package.swift Sources Tests Example/Sources Example/ExampleTests Example/ExampleUITests
swiftformat --lint Package.swift Sources Tests Example/Sources Example/ExampleTests Example/ExampleUITests
```

Replace template assertions with an Example unit test that constructs `MarkdownDocument(parsing: "# Smoke")`, and a UI test that launches the app and asserts the root Markdown demo identifier exists.

- [ ] **Step 4: Add CI and repository command documentation**

Create jobs for format lint, macOS 15 debug tests, macOS 15 release warnings-as-errors, iOS 18 package tests, and Example UI smoke. Pin runner/Xcode identifiers explicitly; if hosted images lack the actual minimum runtime, make the release job consume an archived self-hosted/local result rather than mark it optional. Document identical commands and expected artifacts in `RTK.md`.

Core workflow shape:

```yaml
jobs:
  format:
    steps:
      - run: swiftformat --lint Package.swift Sources Tests Example/Sources Example/ExampleTests Example/ExampleUITests
  macos15:
    steps:
      - run: swift test
      - run: swift build -c release -Xswiftc -warnings-as-errors
  ios18:
    steps:
      - run: xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
  example-smoke:
    steps:
      - run: xcodebuild test -project Example/Example.xcodeproj -scheme Example -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro'
```

- [ ] **Step 5: Verify and commit**

Run the Step 1 commands again plus both `xcodebuild` commands on installed minimum runtimes. Expected: zero format violations, all suites pass, both repository checks pass, and actual runtime metadata is archived.

```bash
git add Package.swift .swiftformat .github RTK.md Example Tests/MarkdownKitTests/PlatformBaselineTests.swift
git commit -m "ci: establish MarkdownKit 0.2 delivery baseline"
```

- [ ] **Step 6: Review checkpoint 1**

Dispatch `superpowers-reviewer` with node `executing-plans`, `BASE_SHA` before Task 1, `HEAD_SHA` after the commit, and focus on platform truthfulness, formatter-only churn, CI enforceability, and removal of empty tests. Resolve any `BLOCK`/`REVISE` before Task 2.

### Task 2: Replace unsafe render contracts with immutable values

**Files:**
- Create: `Sources/MarkdownRenderKit/RenderConfiguration.swift`
- Create: `Sources/MarkdownRenderKit/RenderInput.swift`
- Create: `Sources/MarkdownRenderKit/RenderDisplayModel.swift`
- Create: `Sources/MarkdownRenderKit/ResolvedResource.swift`
- Create: `Sources/MarkdownRenderKit/RenderSnapshot.swift`
- Create: `Sources/MarkdownRenderKit/AccessibilityNode.swift`
- Modify: `Sources/MarkdownRenderKit/RenderStyle.swift`
- Modify: `Sources/MarkdownRenderKit/AttributedStringRenderer.swift`
- Modify: `Sources/MarkdownRenderKit/MathRendering.swift`
- Modify: `Sources/MarkdownRenderKit/SVGBlockRendering.swift`
- Modify: `Sources/MarkdownKit/MarkdownText.swift`
- Modify: `Sources/MarkdownKit/MarkdownEditor.swift`
- Test: `Tests/MarkdownKitTests/RenderIsolationTests.swift`
- Test: `Tests/MarkdownKitTests/RenderConfigurationTests.swift`
- Create: `Tests/CompileFail/RenderSnapshotIsNotSendable.swift`
- Create: `Scripts/check-api-isolation.sh`

**Interfaces:**
- Consumes: `MarkdownDocument`, `BlockNode`, existing style values.
- Produces: `RenderConfigurationSnapshot`, `RenderInput`, `RenderDisplayModel`, and `@MainActor RenderSnapshot`; Task 3 session depends on these exact types.

- [ ] **Step 1: Write compile-time isolation and value-semantic tests**

Define tests that pass `RenderInput` and `RenderDisplayModel` through `Task.detached` as `Sendable`, mutate a source `RenderStyle` after snapshot creation, and assert the snapshot remains unchanged. Add a main-actor test proving `RenderSnapshot` owns platform attributed content. Add a negative typecheck fixture that captures `RenderSnapshot` in a detached `@Sendable` closure; `Scripts/check-api-isolation.sh` succeeds only when `swiftc -typecheck -strict-concurrency=complete` rejects that fixture with an actor-isolation diagnostic.

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

public struct RenderConfigurationID: Hashable, Sendable {
    public let rawValue: String
}

public struct RenderConfigurationSnapshot: Sendable, Equatable {
    public let id: RenderConfigurationID
    public let typography: TypographyTokens
    public let colors: ColorTokens
    public let spacing: SpacingTokens
    public let generation: UInt64
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
package enum ResolvedPlatformResource {
    case image(PlatformImage)
    case math(image: PlatformImage, baselineOffset: Double)
    case svg(PlatformImage)
}

@MainActor
public final class RenderSnapshot {
    public let attributedString: NSAttributedString
    public let displayModel: RenderDisplayModel
}
```

Use numeric RGBA/color tokens and named typography roles off-main; resolve `UIFont`/`NSFont`, platform colors, attachments, and TextKit objects only during main-actor materialization.

- [ ] **Step 3: Remove mutable renderer caches and unchecked public promises**

Turn `AttributedStringRenderer` into an immutable façade with:

```swift
public struct AttributedStringRenderer: Sendable {
    public init(configuration: RenderConfigurationSnapshot)
    public func prepare(_ input: RenderInput) throws -> RenderDisplayModel

    @MainActor
    public func materialize(
        _ model: RenderDisplayModel,
        resources: ResolvedResourceSnapshot
    ) -> RenderSnapshot
}
```

Delete public mutable `imageCache`, `mathCache`, `svgBlockCache`, and renderer-generation properties. Replace platform-image-bearing `MathRenderedGlyph`/`SVGBlockGlyph` cross-actor values with immutable encoded/vector descriptions or audited internal adapters; keep platform images main-actor isolated.

Replace underscored umbrella re-exports with Swift 6 access-level imports:

```swift
public import MarkdownCore
public import MarkdownPlatformView
public import MarkdownRenderKit
```

For `MathJaxRenderer`, `SwiftDrawSVGBlockRenderer`, and scanner caches, either isolate mutation in an actor/lock-backed private box with a documented invariant or remove the conformance; no publicly mutable platform object may rely on `@unchecked Sendable`.

- [ ] **Step 4: Make style conversion explicit**

Keep platform-facing `RenderStyle` as `@MainActor` and add `snapshot(generation:) -> RenderConfigurationSnapshot`. Remove `@unchecked Sendable` from it and from `AttributedStringRenderer`; add documentation explaining that custom fixed fonts opt out of automatic scaling until Task 11 applies the scaling helper.

- [ ] **Step 5: Run focused and regression tests, then commit**

```bash
swift test --filter 'RenderIsolationTests|RenderConfigurationTests|MarkdownRenderKitTests|MathRenderingTests|SVGBlockRenderingTypesTests'
chmod +x Scripts/check-api-isolation.sh
Scripts/check-api-isolation.sh
swift build -c release -Xswiftc -warnings-as-errors
git add Sources/MarkdownRenderKit Sources/MarkdownKit/MarkdownText.swift Sources/MarkdownKit/MarkdownEditor.swift Tests/MarkdownKitTests/RenderIsolationTests.swift Tests/MarkdownKitTests/RenderConfigurationTests.swift Tests/CompileFail/RenderSnapshotIsNotSendable.swift Scripts/check-api-isolation.sh
git commit -m "refactor: make render boundaries actor-safe"
```

- [ ] **Step 6: Review checkpoint 2**

Dispatch `superpowers-reviewer` over the Task 2 commit. Require it to trace every platform object to `MainActor`, reject public mutable unchecked containers, and verify Task 3 can consume the produced interfaces.

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
- Produces: `ParseExecutor.shared`, `MarkdownRenderSession.setSource`, `.append`, `.replaceConfiguration`, `.dismantle`, and a main-actor snapshot callback used by Task 4.

- [ ] **Step 1: Write deterministic blocking-parser tests**

Use an injected parser closure controlled by Swift Testing `confirmation` and an actor gate. Assert two active jobs globally, one active plus one replaceable pending input per token, 64 waiting tokens, latest-revision coalescing, three attempts/two-second deadline through an injected clock, and `.parseBusy` after exhaustion. While the fake parser blocks, release strong view/session references and assert weak references become nil.

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

package struct ParseExecutorDiagnostics: Sendable, Equatable {
    let activeCount: Int
    let waitingTokenCount: Int
    let registryCount: Int
}

package struct RenderSessionID: Hashable, Sendable { let rawValue: UUID }

package actor ParseExecutor {
    static let shared = ParseExecutor(maxActive: 2, maxWaitingTokens: 64)
    func submit(_ job: ParseJob) async -> ParseExecutorResult
    func replacePending(_ job: ParseJob)
    func tombstone(_ token: ParseSessionToken)
    package var diagnostics: ParseExecutorDiagnostics { get }
}
```

The worker closure captures only `ParseJob`; result delivery consults the token registry and never captures a session/view/callback. Remove registry state immediately after a token has no active/pending job. Treat absent-token completion as stale.

- [ ] **Step 3: Implement session revision and retry state**

Create a session actor whose stored state is immutable/Sendable and whose publication sink is a weak main-actor registry token:

```swift
package actor MarkdownRenderSession {
    func setSource(_ source: String, configuration: RenderConfigurationSnapshot) async
    func append(_ chunk: String) async
    func replaceConfiguration(_ configuration: RenderConfigurationSnapshot) async
    func dismantle() async
}
```

Maintain one cancellable preparation task and one replaceable retry task. Gate every parse/render/resource result on both source revision and configuration generation. Retry busy admission no more than three times within two seconds using an injected clock; teardown cancels retry, clears pending input, and tombstones the executor token.

- [ ] **Step 4: Prove lifecycle cleanup and stale rejection**

Add tests for 1,000 create/dismantle cycles returning executor registry counts to baseline; teardown during active parse produces no publication, callback, cache write, retry, or follow-up. Add rapid set/append/replace sequences and assert only the newest snapshot reaches the sink.

- [ ] **Step 5: Verify and commit**

```bash
swift test --filter 'ParseExecutorTests|MarkdownRenderSessionTests|MarkdownCoreIncrementalParseTests'
swift test
git add Sources/MarkdownCore/DocumentParser.swift Sources/MarkdownPlatformView/RenderSessionTypes.swift Sources/MarkdownPlatformView/ParseExecutor.swift Sources/MarkdownPlatformView/MarkdownRenderSession.swift Tests/MarkdownKitTests/ParseExecutorTests.swift Tests/MarkdownKitTests/MarkdownRenderSessionTests.swift
git commit -m "feat: add bounded markdown render sessions"
```

- [ ] **Step 6: Review checkpoint 3A**

Dispatch `superpowers-reviewer` over Task 3 with critical-concurrency focus. Require evidence for no view/session retention across blocking cmark, global/per-token limits, stale-result rejection, retry bounds, and registry reclamation.

### Task 4: Move duplicated UIKit/AppKit state machines behind the session

**Files:**
- Create: `Sources/MarkdownPlatformView/MarkdownLabelView+iOS.swift`
- Create: `Sources/MarkdownPlatformView/MarkdownLabelView+macOS.swift`
- Create: `Sources/MarkdownPlatformView/MarkdownTextInput+iOS.swift`
- Create: `Sources/MarkdownPlatformView/MarkdownSelection.swift`
- Create: `Sources/MarkdownPlatformView/MarkdownTableOverlay.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView.swift`
- Modify: `Sources/MarkdownPlatformView/MathLoadCoordinator.swift`
- Modify: `Sources/MarkdownPlatformView/SVGBlockLoadCoordinator.swift`
- Modify: `Sources/MarkdownKit/MarkdownText.swift`
- Modify: `Sources/MarkdownKit/MarkdownStreamingText.swift`
- Test: `Tests/MarkdownKitTests/PlatformSessionWiringTests.swift`
- Test: existing view/math/SVG/table suites

**Interfaces:**
- Consumes: Task 3 `MarkdownRenderSession` and Task 2 snapshots.
- Produces: thin platform views whose source/configuration calls forward to one session; later resource, copy, and accessibility tasks attach to this boundary.

- [ ] **Step 1: Write wiring tests before moving code**

Inject a `RecordingRenderSession` behind a package protocol and assert `setMarkdown`, `appendMarkdown`, style/renderer changes, window-scale changes, and dismantle each send exactly one typed event. Assert old callbacks cannot mutate content after a replacement.

```swift
package protocol MarkdownRenderSessionProtocol: AnyObject {
    func send(_ event: RenderSessionEvent)
    func dismantle()
}
```

Run `swift test --filter PlatformSessionWiringTests`; expect missing protocol/injection failures.

- [ ] **Step 2: Extract shared selection and table helpers without behavior changes**

Move source-selection mapping helpers to `MarkdownSelection.swift`, table overlay diff/layout to `MarkdownTableOverlay.swift`, and iOS `UITextInput` types/conformance to `MarkdownTextInput+iOS.swift`. Keep existing function signatures during extraction and run copy/table/input regression tests after each move.

- [ ] **Step 3: Split platform class bodies and install the session bridge**

Leave shared event/configuration/resource identities in `MarkdownLabelView.swift`. Move UIKit and AppKit class declarations/extensions to their named files. Replace duplicated parse tasks, revision fields, renderer caches, math/SVG in-flight dictionaries, and direct source update pipelines with one session reference and:

```swift
private func apply(snapshot: RenderSnapshot, revision: UInt64) {
    guard revision == sessionRevision else { return }
    contentStorage.attributedString = snapshot.attributedString
    synchronizePlatformSelectionAndOverlays(snapshot)
}
```

Retain only native TextKit setup, drawing, layout fragments, selection/input plumbing, native accessibility bridge hooks, and platform link activation.

- [ ] **Step 4: Convert math/SVG coordinators to session-owned tasks plus completed caches**

Remove `.shared` in-flight ownership. Define completed-cache protocols and inject them into sessions; keep renderer tasks session-owned and cancellable. Cache keys include configuration ID and generation gating prevents late writes. Replace existing shared-singleton tests with completed-cache sharing and cross-session in-flight isolation tests.

Use explicit completed LRU bounds of 256 entries for math and SVG. Keep only deterministic negative outcomes for 60 seconds with a 128-entry LRU cap; cancellation and transient failures never enter negative caches.

- [ ] **Step 5: Remove timing sleeps from touched platform paths**

Replace the four product-side `Task.sleep` debounce calls with an injected `Clock` and a single replaceable session task. Convert math/SVG tests touched by this task to actor gates or `confirmation`, so tests observe completion events instead of polling time.

- [ ] **Step 6: Verify behavior parity and commit**

```bash
swift test --filter 'PlatformSessionWiringTests|MarkdownLabelViewRenderModeTests|MathLoadCoordinatorTests|SVGBlockLoadCoordinatorTests|TableMeasurementLaidOutEquivalenceTests|SharedCoordinatorTests'
swift test
git add Sources/MarkdownPlatformView Sources/MarkdownKit/MarkdownText.swift Sources/MarkdownKit/MarkdownStreamingText.swift Tests
git commit -m "refactor: share platform render session state"
```

- [ ] **Step 7: Review checkpoint 3B**

Dispatch `superpowers-reviewer` with Task 3's base through Task 4's head. Require plan conformance, no duplicated orchestration, session-owned in-flight tasks, preserved platform behavior, and no timing polling in touched paths.

### Task 5: Make safe streaming work near-linear

**Files:**
- Create: `Sources/MarkdownCore/IncrementalParseState.swift`
- Create: `Sources/MarkdownCore/ParseWorkMetrics.swift`
- Modify: `Sources/MarkdownCore/DocumentParser.swift`
- Modify: `Sources/MarkdownCore/MathScanner.swift`
- Modify: `Sources/MarkdownCore/MathSentinel.swift`
- Modify: `Sources/MarkdownRenderKit/AttributedStringRenderer.swift`
- Test: `Tests/MarkdownKitTests/IncrementalParseDifferentialTests.swift`
- Test: `Tests/MarkdownKitTests/IncrementalWorkBudgetTests.swift`
- Test: existing scanner/incremental suites

**Interfaces:**
- Consumes: session append flow and immutable render preparation.
- Produces: `IncrementalParseState`, `IncrementalParseResult`, and test-only `ParseWorkMetrics` counters consumed by session and performance gates.

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
public struct IncrementalParseState: Sendable, Equatable {
    public let safeUTF8Boundary: Int
    public let fence: FenceState?
    public let inlineCodeDelimiterLength: Int?
    public let math: MathDelimiterState
    public let lineContext: LineContext
}

public enum FullParseReason: Sendable, Equatable {
    case nonPrefixEdit, missingState, referenceDefinition, setextOrThematicBreak
    case htmlBlock, lazyContainer, splitCRLF, missingFinalNewline, inconsistentPrefix
}
```

Return the reason in internal diagnostics whenever a full parse occurs. Resume from a proven safe boundary only; any uncertain construct chooses an enumerated fallback.

- [ ] **Step 3: Instrument every source-proportional phase**

Implement a test-injectable counter:

```swift
public struct ParseWorkMetrics: Sendable, Equatable {
    public var scannerBytes = 0
    public var mappingBytes = 0
    public var materializationBytes = 0
    public var cmarkInputBytes = 0
    public var renderPreparationBytes = 0
    public var total: Int { scannerBytes + mappingBytes + materializationBytes + cmarkInputBytes + renderPreparationBytes }
}
```

Count UTF-8 construction, prefix checks, suffix copies, math substitution, source mapping, cmark input, and display-model preparation. Do not leave a source-sized loop or copy outside a counter category.

- [ ] **Step 4: Implement tail-only scanning/parsing/render preparation**

Replace complete-source `MathScanner.scan`/`codeRegionMask` calls on safe append with state resumption. Parse only the invalidated tail, offset its source ranges, preserve stable prefix blocks/lineage, and prepare only changed display blocks. Check cancellation at fixed byte/block intervals in owned loops.

- [ ] **Step 5: Enforce deterministic budgets**

For 1 KB chunks on safe 10 KB, 100 KB, and 1 MB fixtures, assert scanner `≤ 3N`, mapping `≤ 3N`, materialization/substitution `≤ 4N`, cmark input `≤ 4N`, render preparation `≤ 4N`, total `≤ 16N`. Report documented fallback fixtures separately and add one warm-up plus five-run median diagnostics without making wall time the correctness gate.

- [ ] **Step 6: Verify and commit**

```bash
swift test --filter 'IncrementalParseDifferentialTests|IncrementalWorkBudgetTests|MarkdownCoreIncrementalParseTests|MathScannerTests|MathScannerCodeRegionHardStopTests|MathScannerCurrencyDollarTests'
swift test
git add Sources/MarkdownCore Sources/MarkdownRenderKit/AttributedStringRenderer.swift Tests/MarkdownKitTests
git commit -m "perf: bound incremental markdown work"
```

- [ ] **Step 7: Review checkpoint 4**

Dispatch `superpowers-reviewer` with correctness/performance focus. Require it to inspect every counted phase, differential fallback coverage, cancellation intervals, and proof that no full-source work moved outside instrumentation.

### Task 6: Implement the isolated opt-in image transport

**Files:**
- Create: `Sources/MarkdownPlatformView/ResourceConfiguration.swift`
- Create: `Sources/MarkdownPlatformView/MarkdownImageLoader.swift`
- Create: `Sources/MarkdownPlatformView/URLSessionImageTransport.swift`
- Modify: `Sources/MarkdownKit/MarkdownText.swift`
- Modify: `Sources/MarkdownKit/MarkdownStreamingText.swift`
- Create: `Sources/MarkdownKit/MarkdownResourceModifiers.swift`
- Test: `Tests/MarkdownKitTests/MarkdownImageLoaderTests.swift`
- Test: `Tests/MarkdownKitTests/ResourceConfigurationTests.swift`

**Interfaces:**
- Consumes: Task 4 session configuration events.
- Produces: `MarkdownImageLoading`, `MarkdownResourceConfigurationID`, `MarkdownImageRequest`, `MarkdownEncodedImage`, default disabled policy, and SwiftUI `.markdownRemoteImages(_:)` configuration used by Task 7.

- [ ] **Step 1: Write protocol, opt-in, generation, and cache-namespace tests**

Tests assert remote URLs stay placeholders by default; enabling the built-in loader starts HTTPS only; equal built-in settings have equal semantic IDs; custom instances receive unique IDs; explicit versioned semantic IDs share only completed entries; replacement increments session generation and a late old result cannot publish, callback, or write a cache.

- [ ] **Step 2: Define immutable public contracts**

```swift
public struct MarkdownResourceConfigurationID: Hashable, Sendable {
    public static func uniqueInstance() -> Self
    public static func semantic(namespace: String, version: UInt) -> Self
}

public protocol MarkdownImageLoading: Sendable {
    var configurationID: MarkdownResourceConfigurationID { get }
    func load(_ request: MarkdownImageRequest) async throws -> MarkdownEncodedImage
}

public struct MarkdownImageRequest: Sendable {
    public let url: URL
    public let requestTimeout: Duration
    public let resourceTimeout: Duration
}
```

`MarkdownEncodedImage` contains at most 20 MiB encoded bytes and validated MIME/ImageIO metadata, never a platform image. Error callbacks are `@MainActor` and receive a typed category plus sanitized origin only.

Expose `.markdownRemoteImages(_:)` and `.onMarkdownResourceError(_:)` from `MarkdownResourceModifiers.swift`. The environment default is `.disabled`; `.defaultHTTPS` constructs the deterministic built-in semantic configuration.

- [ ] **Step 3: Implement an isolated URLSession transport**

Build an ephemeral configuration with `httpCookieStorage = nil`, `urlCredentialStorage = nil`, `urlCache = nil`, `requestCachePolicy = .reloadIgnoringLocalCacheData`, and no implicit authentication. Use 15-second request and 30-second resource defaults, configurable within 1...120 seconds. Reject non-HTTPS initial/final/redirect URLs, non-2xx status, cross-host forwarded authorization/custom headers, disallowed MIME, and bodies beyond byte 20 MiB + 1 while streaming.

- [ ] **Step 4: Validate metadata before decode**

Use an incremental `CGImageSource` only for type and properties. Require declared MIME, detected UTI/type, and selected decoder agreement. With overflow-safe arithmetic reject either side over 8,192 px, more than 32 frames, or cumulative source pixels over 40 MP. Ensure rejected inputs never reach Task 7's full decoder.

- [ ] **Step 5: Verify with a controlled URLProtocol and commit**

Cover redirects, status, MIME/signature mismatch, cookies/credentials/cache isolation, sanitized errors, exact byte boundary, timeout, and cancellation using a custom `URLProtocol`; assert decoder invocation count remains zero for rejected cases.

```bash
swift test --filter 'MarkdownImageLoaderTests|ResourceConfigurationTests'
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
- Produces: process-wide permit coordinator, main-actor `ImageResidencyLease`, bounded completed LRU, and resolved-resource snapshots.

- [ ] **Step 1: Write concurrency and hold-and-wait regressions**

With controllable transports/decoders, assert per-session maximum two transfers/one decode, process maximum four transfers/two decodes, and exactly 20 MiB reserved before each network start from an 80 MiB ledger. Two 17 MiB and four 9 MiB bodies must finish or remain unstarted; none may pause while holding a partial body.

- [ ] **Step 2: Implement permit and encoded-reservation actors**

```swift
package actor ImageResourceCoordinator {
    static let shared = ImageResourceCoordinator(
        globalTransfers: 4, globalDecodes: 2,
        encodedReservationBytes: 80 * 1024 * 1024
    )
    func withTransferPermit<T: Sendable>(session: RenderSessionID, operation: @Sendable () async throws -> T) async throws -> T
    func withDecodePermit<T: Sendable>(session: RenderSessionID, operation: @Sendable () async throws -> T) async throws -> T
    func cancelQueued(session: RenderSessionID)
}
```

Reserve 20 MiB atomically before invoking transport; release only after rejection or decoder consumption. Queue without starting network or retaining response bytes, and remove queued entries on source/configuration replacement and teardown.

- [ ] **Step 3: Implement downsampling and conservative pixel accounting**

Normalize ImageIO thumbnails to 8-bit BGRA/sRGB. Reserve `alignUp(width * 4, 64) * height` summed over retained frames with overflow checks; cap output at 4,096 px/side and 64 MiB. Reconcile against actual `CGImage.bytesPerRow * height` before publication; when reconciliation exceeds remaining budget, discard and retry smaller once, otherwise keep the accessible placeholder.

- [ ] **Step 4: Implement unique backing records and owner leases**

```swift
@MainActor
package final class ImageResidencyLease {
    let backingID: UUID
    let image: PlatformImage
    let accountedPixelBytes: Int
}

package struct DecodedImage: @unchecked Sendable {
    let backingID: UUID
    let frames: [CGImage]
    let accountedPixelBytes: Int
}

@MainActor
package final class ImageResidencyLedger {
    static let shared = ImageResidencyLedger(hardLimit: 192 << 20, cacheLimit: 128 << 20)
    func admit(_ decoded: DecodedImage) -> ImageResidencyLease?
    func acquireCacheLease(for backingID: UUID)
    func acquirePublicationLease(for backingID: UUID, snapshotID: UUID)
    func releaseSnapshot(_ snapshotID: UUID)
}
```

Identity is the physical decoded backing allocation, not merely the semantic cache key. If concurrent sessions decode the same key into two backings, charge both unless publication canonicalizes to one and discards the other before exposure. Cache eviction releases only cache ownership. Snapshot publication admits added leases before atomically swapping and releasing removed leases; last owner removal alone uncharges the backing.

`DecodedImage` is the single audited unchecked adapter: it contains immutable `CGImage` frames only, never `UIImage`/`NSImage`, and no frame is mutated after construction. Materialize the platform image inside `ImageResidencyLedger.admit` on `MainActor`; document and concurrency-test this invariant.

Keep deterministic image failures in a separate 128-entry LRU with a five-minute TTL. Scheme/MIME/metadata violations may enter it; cancellation, timeout, admission busy, connectivity, and budget/downsample deferral may not. Include configuration ID in the key and clear expired entries through the injected clock.

- [ ] **Step 5: Exercise 100-image ownership transitions**

Publish valid images, evict their cache ownership while attachments still display them, and assert ledger cost stays charged. Request additional images and assert smaller thumbnails/placeholders preserve the 192 MiB limit. Replace snapshots and dismantle views; assert ledger and queued work return to baseline. Measure process peak separately so allocator/framework overhead is reported but not confused with the decoded-pixel contract.

- [ ] **Step 6: Verify and commit**

```bash
swift test --filter 'ImageResourceCoordinatorTests|ImageResidencyLedgerTests|ImageAdversarialTests|MarkdownImageLoaderTests'
swift test
git add Sources/MarkdownPlatformView Sources/MarkdownRenderKit/RenderSnapshot.swift Tests/MarkdownKitTests
git commit -m "feat: bound markdown image residency"
```

- [ ] **Step 7: Review checkpoint 5B**

Dispatch `superpowers-reviewer` with critical resource-ownership focus. Require proof of deadlock freedom, hard accounted-pixel limits across cache and published attachments, physical-backing identity, atomic snapshot swaps, and teardown reclamation.

### Task 8: Add a typed link policy and main-actor activation

**Files:**
- Create: `Sources/MarkdownPlatformView/MarkdownLinkPolicy.swift`
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

- [ ] **Step 2: Implement pure policy and isolated handler contracts**

```swift
public protocol MarkdownLinkPolicy: Sendable {
    var configurationID: MarkdownResourceConfigurationID { get }
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
```

Include the current session generation in activation metadata. Revalidate generation immediately before calling the handler. Default handler delegates only an allowed HTTP/HTTPS URL to `UIApplication`/`NSWorkspace`.

- [ ] **Step 3: Wire platform and SwiftUI APIs**

Replace direct `UIApplication.shared.open`/`NSWorkspace.shared.open` calls with session policy evaluation and handler activation. Add `.markdownLinkPolicy(_:handler:)`; document that a custom scheme needs both explicit policy permission and handler support.

- [ ] **Step 4: Verify and commit**

```bash
swift test --filter MarkdownLinkPolicyTests
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

Connect it through `MarkdownSelectionReader`, mirroring the editor proxy pattern, so programmatic clients can inspect granularity before copying.

- [ ] **Step 4: Verify and commit**

```bash
swift test --filter 'MarkdownCopyTests|ReadOnlyCopyOriginalSourceTests'
swift test
git add Package.swift Sources/MarkdownPlatformView Sources/MarkdownRenderKit/RenderDisplayModel.swift Sources/MarkdownKit/MarkdownSelectionProxy.swift Tests/MarkdownKitTests/MarkdownCopyTests.swift Tests/MarkdownMathTests/ReadOnlyCopyOriginalSourceTests.swift
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

- [ ] **Step 3: Map semantic leaves to platform accessibility objects**

On UIKit use virtual `UIAccessibilityElement`s owned by the label; on AppKit use `NSAccessibilityElement`s. Derive frames from TextKit layout fragments and provide hit testing/activation metadata. Diff by node ID and reuse platform objects. Exclude visual table overlay objects from accessibility exposure.

Localize generic image/math/error fallback labels in English and Simplified Chinese through the Task 9 resource bundle, and expose host overrides. Alt text always takes precedence over a generic image label.

- [ ] **Step 4: Preserve focus during streaming**

If the focused ID survives, keep the same platform object even when its end range grows. If removed, choose the nearest surviving semantic neighbor. Add repeated-append tests for a focused growing final paragraph and table. Keep streaming announcements off by default; when enabled, coalesce to one polite new-content announcement per committed batch through an injected clock.

- [ ] **Step 5: Run platform tests and commit**

```bash
swift test --filter 'MarkdownAccessibilityModelTests|MarkdownAccessibilityPlatformTests'
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
- Modify: `Sources/MarkdownRenderKit/AttributedStringRenderer.swift`
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

- [ ] **Step 3: Rebuild through session configuration on trait changes**

Observe iOS content-size-category and relevant display-scale/color traits. Produce a new immutable render configuration generation and send one replacement event; do not mutate cached renderers or replace host custom style objects. On macOS, respond to accessibility text/display changes supported by the target runtime.

- [ ] **Step 4: Capture and inspect required screenshots**

Run the Example at normal and maximum Dynamic Type in light/dark modes and capture normal content, wide table, loading image, math, and SVG screens. Dispatch the configured `ios-visual-reviewer` with screenshot paths and source files; fix clipping, overlap, hierarchy, or polish findings before proceeding.

- [ ] **Step 5: Verify and commit**

```bash
swift test --filter 'DynamicTypeTests|AdaptiveLayoutTests'
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

Run `rg -n 'Task\.sleep' Sources Tests Example`. Keep the Example's intentional randomized streaming demonstration only if it is user-visible demo behavior; replace every test poll with actor gates, `confirmation`, injected clocks, or explicit session drain APIs. Add a repository test that fails if `Task.sleep` occurs under `Tests/`.

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

- [ ] **Step 5: Complete manual accessibility and visual evidence**

On the actual supported runtimes, record VoiceOver traversal/speech, Voice Control Show Names/Numbers, Full Keyboard Access, representative Switch Control traversal, focus continuity during streaming, source-copy commands, and maximum Dynamic Type. Attach screenshot paths and the visual-review result to release documentation.

- [ ] **Step 6: Commit documentation and final gates**

```bash
git add Sources Tests Example README.md CHANGELOG.md CONTRIBUTING.md .github docs/release
git commit -m "docs: prepare MarkdownKit 0.2 release"
```

- [ ] **Step 7: Run final complete-diff review**

Use `superpowers:verification-before-completion` and save fresh outputs for every Step 4/5 gate. Then dispatch `superpowers-reviewer` with node `finishing-a-development-branch`, the pre-implementation `BASE_SHA`, final `HEAD_SHA`, the spec/plan paths, runtime evidence, and screenshot review. Process all feedback via `superpowers:receiving-code-review`; do not proceed on `BLOCK`.

- [ ] **Step 8: Finish the branch and open the PR**

Use `superpowers:finishing-a-development-branch`, select the user-approved integration option, open the PR with the migration/security summary and evidence, then immediately use `auto-fix-pr-after-implementation` for the review/fix/threaded-reply loop.

## Checkpoint-to-Audit Coverage

| Checkpoint | Audit IDs | Primary proof |
|---|---|---|
| 1 | E1, E2, T1, S1, R1 | Formatting, CI, real runtime, non-template tests, `RTK.md` |
| 2 | C2, M1 | Compile-time actor/value boundaries |
| 3A–3B | C1, M2, T2 | Blocking parser, teardown/churn, thin platform views |
| 4 | P1 | Differential fixtures and byte-work budgets |
| 5A–5C | N1 | Transport security, deadlock-free budgets, residency leases, links |
| 6 | U1 | Exact rendered/source copy matrix |
| 7A–7B | A1, A2 | Golden semantic traversal, focus continuity, Dynamic Type screenshots |
| 8/final | D1 and all rows | Full gates, docs/migration, actual-runtime and manual evidence |
