# SVG Code-Block Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render a fenced code block whose language is `svg` as the rendered SVG image in read-only views, degrading to the existing syntax-highlighted code block when no renderer is injected or the SVG fails to parse.

**Architecture:** Independent `SVGBlockRendering` protocol + `.svgRenderer(_:)` modifier, structurally **mirroring the post-PR#4-hardened math subsystem** (view-owned cache + getter re-seed, `: AnyObject` renderer protocol, shared identity helper, optional modifier param, actor coordinator with LRU/3-state/generation, async write-back through the already-fixed `resetLayout()` discipline). Core/RenderKit stay zero-SwiftDraw-dependency; the SwiftDraw rasterizer lives only in `MarkdownMath` and is **self-contained** (no `SVGRasterizer` refactor — honors the spec §9.1 "math 路径零回归" hard gate).

**Tech Stack:** Swift 6.2 SwiftPM (MarkdownCore/RenderKit/PlatformView/Kit + optional MarkdownMath), TextKit2 `NSTextAttachment`, Swift Testing (`@Suite`/`@Test`/`#expect`), SwiftDraw (already pinned, MarkdownMath only).

**Authoritative spec:** `docs/superpowers/specs/2026-05-18-svg-code-block-rendering-design.md`. Where this plan and the spec differ, the plan's post-PR#4 hardening wins (the spec predates PR #4; rationale inline per task).

**Mirror sources (read these as the canonical template for each svg counterpart):**
- `Sources/MarkdownRenderKit/MathRendering.swift` → svg protocol/types
- `Sources/MarkdownPlatformView/MathLoadCoordinator.swift` → svg coordinator
- `Sources/MarkdownKit/MathRendererIdentity.swift` + `Sources/MarkdownKit/MathRendererModifier.swift` → svg identity + modifier
- `Sources/MarkdownPlatformView/MarkdownLabelView.swift` (`_mathCache`/`_imageCache` view-owned + `cachedRenderer` getter re-seed + `triggerMathLoads` + `mathRenderer` didSet, **both** `#if canImport(UIKit)` and AppKit branches) → svg wiring
- `Sources/MarkdownKit/MarkdownText.swift` / `MarkdownStreamingText.swift` (`@Environment` read + identity-guarded assignment) → svg representable wiring
- `Sources/MarkdownMath/SVGRasterizer.swift` (read-only reference for SwiftDraw parse/rasterize/point-size-contract idioms — **do not modify**) → SwiftDrawSVGBlockRenderer
- Test mirror sources: `Tests/MarkdownKitTests/MathRenderingTests.swift`, `MathLoadCoordinatorTests.swift`, `MathRendererModifierOptionalTests.swift`, `Tests/MarkdownMathTests/StreamingMathCacheSurvivesRendererRecreationTests.swift`, `MarkdownRenderKitTests.swift`

**Global rules every task obeys:** TDD (failing test first, run-it-fails, minimal impl, run-it-passes, commit). Swift 6 strict concurrency. Explicit `self.`. Bilingual comments matching each file's existing style. After any non-trivial Swift change run `swift build -Xswiftc -warnings-as-errors` (0/0) + `swift test`. Do **not** touch `MathLoadCoordinator`, `MathScanner`, `MathSentinel`, `DocumentParser`, the math `_mathCache`/identity/modifier, wide-table `TableMeasurement`, or any PR-#4 fix behavior. No diagnostic instrumentation. Commit per task.

---

### Task 1: `SVGBlockRendering` protocol, value types, attribute key (MarkdownRenderKit, zero-dep)

**Files:**
- Create: `Sources/MarkdownRenderKit/SVGBlockRendering.swift`
- Test: `Tests/MarkdownKitTests/SVGBlockRenderingTypesTests.swift`

Mirror `Sources/MarkdownRenderKit/MathRendering.swift` structure. **Delta vs spec §4:** protocol is `: AnyObject, Sendable` (NOT bare `Sendable`) — PR#4 round-1 proved value-type renderer identity via `as AnyObject` boxing is broken; the only conformer will be a `final class`, so constrain now.

- [ ] **Step 1: Write the failing test** — `Tests/MarkdownKitTests/SVGBlockRenderingTypesTests.swift`

```swift
import Testing
import CoreGraphics
@testable import MarkdownRenderKit

@Suite("SVG block rendering types")
struct SVGBlockRenderingTypesTests {
    @Test("SVGBlockCacheKey distinct on every dimension")
    func keyDimensions() {
        let base = SVGBlockCacheKey(svg: "<svg/>", availableWidth: 100, rasterScale: 2, rendererGeneration: 0)
        #expect(base == SVGBlockCacheKey(svg: "<svg/>", availableWidth: 100, rasterScale: 2, rendererGeneration: 0))
        #expect(base != SVGBlockCacheKey(svg: "<svg />", availableWidth: 100, rasterScale: 2, rendererGeneration: 0))
        #expect(base != SVGBlockCacheKey(svg: "<svg/>", availableWidth: 101, rasterScale: 2, rendererGeneration: 0))
        #expect(base != SVGBlockCacheKey(svg: "<svg/>", availableWidth: 100, rasterScale: 3, rendererGeneration: 0))
        #expect(base != SVGBlockCacheKey(svg: "<svg/>", availableWidth: 100, rasterScale: 2, rendererGeneration: 1))
    }

    @Test("markdownSVGBlockSource attribute key is stable")
    func attrKey() {
        #expect(NSAttributedString.Key.markdownSVGBlockSource.rawValue == "MarkdownKit.svgBlockSource")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SVGBlockRenderingTypesTests 2>&1 | tail -5`
Expected: FAIL — `Cannot find 'SVGBlockCacheKey' in scope` / `markdownSVGBlockSource` missing.

- [ ] **Step 3: Write minimal implementation** — `Sources/MarkdownRenderKit/SVGBlockRendering.swift`

```swift
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public extension NSAttributedString.Key {
    /// 未渲染 SVG 代码块占位标记，载荷为 SVG body 源串，对标 .markdownMathSource。
    /// Marks an un-rendered ```svg code block; payload is the SVG body source string.
    static let markdownSVGBlockSource = NSAttributedString.Key("MarkdownKit.svgBlockSource")
}

/// 已渲染的 SVG 块位图。`image.size` **必须**是点单位（与 MathRenderedGlyph 同契约）。
/// Rendered SVG block bitmap. `image.size` MUST be in points (same contract as MathRenderedGlyph).
public struct SVGBlockGlyph: Sendable {
    public init(image: PlatformImage) { self.image = image }
    public let image: PlatformImage
}

/// 三态结果（对标 MathRenderOutcome）。Tri-state outcome (mirrors MathRenderOutcome).
public enum SVGBlockOutcome: Sendable {
    case rendered(SVGBlockGlyph)
    case failed
    case cancelled
}

public struct SVGBlockCacheKey: Hashable, Sendable {
    public init(svg: String, availableWidth: CGFloat, rasterScale: CGFloat, rendererGeneration: Int) {
        self.svg = svg
        self.availableWidth = availableWidth
        self.rasterScale = rasterScale
        self.rendererGeneration = rendererGeneration
    }
    public let svg: String
    public let availableWidth: CGFloat
    public let rasterScale: CGFloat
    public let rendererGeneration: Int
}

/// 注入式 SVG 块渲染器。约束 `AnyObject`：注入身份比较须稳定，值类型经
/// `as AnyObject` 装箱不稳（PR #4 round-1 已在 MathRendering 验证）。
/// Injected SVG block renderer; class-constrained so injection identity is stable
/// (value types box unstably via `as AnyObject` — proven on MathRendering in PR #4 r1).
public protocol SVGBlockRendering: AnyObject, Sendable {
    func render(svg: String, availableWidth: CGFloat, scale: CGFloat) async -> SVGBlockOutcome
}
```

(If `PlatformImage`/`PlatformColor` typealias is not already visible in MarkdownRenderKit, reuse the exact same typealias declaration `MathRendering.swift` uses — read that file and copy its `PlatformImage` definition verbatim into a shared spot if needed; do not redefine if already module-visible.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SVGBlockRenderingTypesTests 2>&1 | tail -3`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownRenderKit/SVGBlockRendering.swift Tests/MarkdownKitTests/SVGBlockRenderingTypesTests.swift
git commit -m "feat(renderkit): SVGBlockRendering protocol + types + .markdownSVGBlockSource"
```

---

### Task 2: `renderSVGBlock` branch in `AttributedStringRenderer`

**Files:**
- Modify: `Sources/MarkdownRenderKit/AttributedStringRenderer.swift` (add 3 stored fields; branch `renderCodeBlock`; add `renderSVGBlock`)
- Test: `Tests/MarkdownKitTests/SVGBlockRenderTests.swift`

**Behavior (spec §4):** add `public var svgBlockCache: [SVGBlockCacheKey: SVGBlockGlyph] = [:]`, `public var svgRasterScale: CGFloat = 1`, `public var svgRendererGeneration: Int = 0` (mirror the existing `mathCache`/`mathRasterScale`/`mathRendererGeneration` declarations — read them, place the svg trio adjacently with the same access level). In `renderCodeBlock(language:body:)`, **before** existing logic: `if language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "svg" { return self.renderSVGBlock(svg: body) }`. `renderSVGBlock`: build `SVGBlockCacheKey(svg: body, availableWidth: self.availableWidth, rasterScale: self.svgRasterScale, rendererGeneration: self.svgRendererGeneration)`; **hit** → single centered `NSTextAttachment` (`attachment.image = glyph.image`; `attachment.bounds = CGRect(x: 0, y: 0, width: glyph.image.size.width, height: glyph.image.size.height)`; wrap in `NSAttributedString(attachment:)` with a paragraph style `alignment = .center` + the file's existing block paragraph spacing); **miss** → call the **existing** code-block rendering for `body`/`language` unchanged, then `addAttribute(.markdownSVGBlockSource, value: body, range: NSRange(location: 0, length: result.length))` on the produced string. No color injection. Non-`svg` languages: zero change (the early branch only triggers on exact `svg`).

- [ ] **Step 1: Write the failing test** — `Tests/MarkdownKitTests/SVGBlockRenderTests.swift`

```swift
import Testing
import Foundation
@testable import MarkdownRenderKit
@testable import MarkdownCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite("SVG code-block rendering branch")
struct SVGBlockRenderTests {
    private func render(_ block: BlockNode, cache: [SVGBlockCacheKey: SVGBlockGlyph] = [:],
                        width: CGFloat = 320) -> NSAttributedString {
        var r = AttributedStringRenderer(style: .default, availableWidth: width)
        r.svgBlockCache = cache
        return r.renderBlock(block)
    }

    @Test("language svg (case/space-insensitive), cache miss → highlighted code block + marker attr")
    func missKeepsHighlightedCodeWithMarker() {
        let out = render(.codeBlock(language: " SVG ", body: "<svg/>"))
        var found = false
        out.enumerateAttribute(.markdownSVGBlockSource, in: NSRange(location: 0, length: out.length)) { v, _, _ in
            if (v as? String) == "<svg/>" { found = true }
        }
        #expect(found)
        #expect(out.length > 0)
        #expect(!out.string.contains("\u{FFFC}"))   // not an attachment in the miss state
    }

    @Test("cache hit → single centered attachment sized to image, origin.y == 0")
    func hitProducesCenteredAttachment() {
        let img = PlatformImage()   // size .zero is fine for geometry assertions below if we set explicitly
        let sized = SVGBlockGlyph(image: makeImage(width: 200, height: 90))
        let key = SVGBlockCacheKey(svg: "<svg/>", availableWidth: 320, rasterScale: 1, rendererGeneration: 0)
        let out = render(.codeBlock(language: "svg", body: "<svg/>"), cache: [key: sized])
        var att: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { v, _, _ in
            att = v as? NSTextAttachment
        }
        let a = try! #require(att)
        #expect(a.bounds.size.width == 200)
        #expect(a.bounds.size.height == 90)
        #expect(a.bounds.origin.y == 0)
        let para = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(para?.alignment == .center)
        _ = img
    }

    @Test("non-svg code block unchanged (regression)")
    func nonSvgUnchanged() {
        let a = render(.codeBlock(language: "swift", body: "let x = 1"))
        let b: NSAttributedString = {
            let r = AttributedStringRenderer(style: .default, availableWidth: 320)
            return r.renderBlock(.codeBlock(language: "swift", body: "let x = 1"))
        }()
        #expect(a.isEqual(to: b))
    }
}

private func makeImage(width: CGFloat, height: CGFloat) -> PlatformImage {
    #if canImport(UIKit)
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in }
    #elseif canImport(AppKit)
    let i = NSImage(size: NSSize(width: width, height: height)); return i
    #else
    return PlatformImage()
    #endif
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SVGBlockRenderTests 2>&1 | tail -5`
Expected: FAIL — `svgBlockCache` unknown / no svg branch (miss/hit assertions fail).

- [ ] **Step 3: Write minimal implementation**

Read `AttributedStringRenderer.swift`: locate the `mathCache`/`mathRasterScale`/`mathRendererGeneration` declarations and the `renderCodeBlock(language:body:)` method. Add the svg trio adjacent to the math trio (same `public var ... = ...` form). At the very top of `renderCodeBlock`, add:

```swift
if language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "svg" {
    return self.renderSVGBlock(svg: body)
}
```

Add `private func renderSVGBlock(svg: String) -> NSAttributedString`:

```swift
private func renderSVGBlock(svg: String) -> NSAttributedString {
    let key = SVGBlockCacheKey(
        svg: svg,
        availableWidth: self.availableWidth,
        rasterScale: self.svgRasterScale,
        rendererGeneration: self.svgRendererGeneration
    )
    if let glyph = self.svgBlockCache[key] {
        let attachment = NSTextAttachment()
        attachment.image = glyph.image
        attachment.bounds = CGRect(
            x: 0, y: 0,
            width: glyph.image.size.width,
            height: glyph.image.size.height
        )
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = self.style.paragraphSpacing
        let m = NSMutableAttributedString(attachment: attachment)
        m.addAttribute(.paragraphStyle, value: para.copy() as! NSParagraphStyle,
                       range: NSRange(location: 0, length: m.length))
        return m
    }
    // Miss → keep the existing syntax-highlighted code-block rendering as the
    // (readable) degraded state, tagged so the platform layer can async-trigger.
    let highlighted = self.renderHighlightedCodeBlock(language: "svg", body: svg)
    let result = NSMutableAttributedString(attributedString: highlighted)
    result.addAttribute(.markdownSVGBlockSource, value: svg,
                        range: NSRange(location: 0, length: result.length))
    return result
}
```

Where `renderHighlightedCodeBlock(language:body:)` is whatever the existing `renderCodeBlock` body invokes to produce the highlighted code attributed string. **Read the existing `renderCodeBlock`**: if its highlighting logic is inline (not a callable helper), extract that inline logic into a `private func renderHighlightedCodeBlock(language:body:) -> NSAttributedString` and have the original non-svg path call it too (pure extraction, behavior identical — the `nonSvgUnchanged` test guards this). Do not change highlighting behavior.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SVGBlockRenderTests 2>&1 | tail -3`
Expected: PASS (3 tests).

- [ ] **Step 5: Run full suite (regression gate)**

Run: `swift test 2>&1 | tail -3`
Expected: all prior tests still pass (the extraction must be behavior-neutral).

- [ ] **Step 6: Commit**

```bash
git add Sources/MarkdownRenderKit/AttributedStringRenderer.swift Tests/MarkdownKitTests/SVGBlockRenderTests.swift
git commit -m "feat(renderkit): renderCodeBlock svg branch — cache-hit attachment / miss highlighted+marker"
```

---

### Task 3: `SVGBlockLoadCoordinator` actor (MarkdownPlatformView)

**Files:**
- Create: `Sources/MarkdownPlatformView/SVGBlockLoadCoordinator.swift`
- Test: `Tests/MarkdownKitTests/SVGBlockLoadCoordinatorTests.swift`

**Mirror `Sources/MarkdownPlatformView/MathLoadCoordinator.swift` verbatim**, substituting types: `MathRendering`→`SVGBlockRendering`, `MathCacheKey`→`SVGBlockCacheKey`, `MathRenderedGlyph`→`SVGBlockGlyph`, `MathRenderOutcome`→`SVGBlockOutcome`, `render(latex:display:pointSize:scale:color:)`→`render(svg:availableWidth:scale:)`. **Keep the documented intentional "stale-generation entry is unreachable / LRU-bounded — do NOT 'fix'" comment** (PR#4 round-1 reasoned-reject — same design applies). Same caps (`positiveCap=256`, `negativeCap=1024`), same `setRenderer`/`invalidateForScaleChange`/`glyph(for:)`/`isNegativeCached`/`loadIfNeeded`/`finish`/`awaitGlyph`/`drain` semantics. `loadIfNeeded` signature: `loadIfNeeded(key: SVGBlockCacheKey, svg: String, availableWidth: CGFloat, scale: CGFloat) -> Bool`.

- [ ] **Step 1: Write the failing test** — `Tests/MarkdownKitTests/SVGBlockLoadCoordinatorTests.swift`

Mirror `Tests/MarkdownKitTests/MathLoadCoordinatorTests.swift` test matrix exactly with svg types. Stub renderer must be a `final class ... @unchecked Sendable` (PR#4 round-1 lesson — protocol is AnyObject). Full code:

```swift
import Testing
import CoreGraphics
@testable import MarkdownRenderKit
@testable import MarkdownPlatformView
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private final class StubSVGRenderer: SVGBlockRendering, @unchecked Sendable {
    let outcome: SVGBlockOutcome
    init(_ o: SVGBlockOutcome) { self.outcome = o }
    func render(svg: String, availableWidth: CGFloat, scale: CGFloat) async -> SVGBlockOutcome { self.outcome }
}
private func key(_ s: String = "<svg/>") -> SVGBlockCacheKey {
    SVGBlockCacheKey(svg: s, availableWidth: 100, rasterScale: 1, rendererGeneration: 0)
}
private func glyph() -> SVGBlockGlyph {
    #if canImport(UIKit)
    return SVGBlockGlyph(image: UIGraphicsImageRenderer(size: .init(width: 10, height: 10)).image { _ in })
    #else
    return SVGBlockGlyph(image: NSImage(size: .init(width: 10, height: 10)))
    #endif
}

@Suite("SVGBlockLoadCoordinator")
struct SVGBlockLoadCoordinatorTests {
    @Test("nil renderer does not dispatch")
    func nilRenderer() async {
        let c = SVGBlockLoadCoordinator()
        let dispatched = await c.loadIfNeeded(key: key(), svg: "<svg/>", availableWidth: 100, scale: 1)
        #expect(dispatched == false)
    }
    @Test("rendered → positive cache, no re-dispatch, awaitGlyph returns it")
    func renderedCached() async {
        let c = SVGBlockLoadCoordinator()
        await c.setRenderer(StubSVGRenderer(.rendered(glyph())))
        #expect(await c.loadIfNeeded(key: key(), svg: "<svg/>", availableWidth: 100, scale: 1) == true)
        #expect(await c.awaitGlyph(for: key()) != nil)
        #expect(await c.loadIfNeeded(key: key(), svg: "<svg/>", availableWidth: 100, scale: 1) == false)
    }
    @Test("failed → negative cache, no re-dispatch")
    func failedNeg() async {
        let c = SVGBlockLoadCoordinator()
        await c.setRenderer(StubSVGRenderer(.failed))
        _ = await c.loadIfNeeded(key: key(), svg: "<svg/>", availableWidth: 100, scale: 1)
        _ = await c.awaitGlyph(for: key())
        #expect(await c.isNegativeCached(key()))
        #expect(await c.loadIfNeeded(key: key(), svg: "<svg/>", availableWidth: 100, scale: 1) == false)
    }
    @Test("cancelled → not cached, retryable")
    func cancelledRetry() async {
        let c = SVGBlockLoadCoordinator()
        await c.setRenderer(StubSVGRenderer(.cancelled))
        _ = await c.loadIfNeeded(key: key(), svg: "<svg/>", availableWidth: 100, scale: 1)
        _ = await c.awaitGlyph(for: key())
        #expect(await c.isNegativeCached(key()) == false)
        #expect(await c.glyph(for: key()) == nil)
    }
    @Test("setRenderer bumps generation and clears caches")
    func setRendererBumps() async {
        let c = SVGBlockLoadCoordinator()
        await c.setRenderer(StubSVGRenderer(.rendered(glyph())))
        _ = await c.loadIfNeeded(key: key(), svg: "<svg/>", availableWidth: 100, scale: 1)
        _ = await c.awaitGlyph(for: key())
        let g0 = await c.generation
        await c.setRenderer(StubSVGRenderer(.rendered(glyph())))
        #expect(await c.generation == g0 + 1)
        #expect(await c.glyph(for: key()) == nil)
    }
    @Test("invalidateForScaleChange clears caches, generation unchanged")
    func invalidateScale() async {
        let c = SVGBlockLoadCoordinator()
        await c.setRenderer(StubSVGRenderer(.rendered(glyph())))
        _ = await c.loadIfNeeded(key: key(), svg: "<svg/>", availableWidth: 100, scale: 1)
        _ = await c.awaitGlyph(for: key())
        let g = await c.generation
        await c.invalidateForScaleChange()
        #expect(await c.generation == g)
        #expect(await c.glyph(for: key()) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SVGBlockLoadCoordinatorTests 2>&1 | tail -5`
Expected: FAIL — `SVGBlockLoadCoordinator` not found.

- [ ] **Step 3: Write minimal implementation** — `Sources/MarkdownPlatformView/SVGBlockLoadCoordinator.swift`

Read `Sources/MarkdownPlatformView/MathLoadCoordinator.swift` in full and reproduce it as `SVGBlockLoadCoordinator` with the exact type substitutions above. Preserve every comment **including** the intentional stale-generation note (PR#4 round-1: that design is correct and deliberately documented; the svg coordinator inherits it verbatim). `loadIfNeeded`'s dispatched `Task` calls `await renderer.render(svg:availableWidth:scale:)`. No behavioral divergence from the math coordinator other than the render signature.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SVGBlockLoadCoordinatorTests 2>&1 | tail -3`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownPlatformView/SVGBlockLoadCoordinator.swift Tests/MarkdownKitTests/SVGBlockLoadCoordinatorTests.swift
git commit -m "feat(platformview): SVGBlockLoadCoordinator mirroring MathLoadCoordinator"
```

---

### Task 4: shared identity helper + `.svgRenderer(_:)` modifier (MarkdownKit)

**Files:**
- Create: `Sources/MarkdownKit/SVGBlockRendererIdentity.swift`
- Create: `Sources/MarkdownKit/SVGBlockRendererModifier.swift`
- Test: `Tests/MarkdownKitTests/SVGBlockRendererModifierTests.swift`

**Delta vs spec §6:** identity guard is a **single shared internal helper** (PR#4 round-5 — not per-representable duplication). Modifier param is **`(any SVGBlockRendering)?`** optional (PR#4 round-5 — runtime disable without branching the view tree).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import SwiftUI
@testable import MarkdownKit
@testable import MarkdownRenderKit

private final class R: SVGBlockRendering, @unchecked Sendable {
    func render(svg: String, availableWidth: CGFloat, scale: CGFloat) async -> SVGBlockOutcome { .failed }
}

@Suite("svgRenderer modifier + identity")
@MainActor struct SVGBlockRendererModifierTests {
    @Test("env default nil; concrete round-trips; nil clears")
    func envRoundTrip() {
        var env = EnvironmentValues()
        #expect(env.markdownSVGBlockRenderer == nil)
        let r = R()
        env.markdownSVGBlockRenderer = r
        #expect(env.markdownSVGBlockRenderer === r)
        env.markdownSVGBlockRenderer = nil
        #expect(env.markdownSVGBlockRenderer == nil)
    }
    @Test("isSameSVGBlockRenderer: nil/nil true, one-nil false, same-instance true, diff false")
    func identity() {
        let a = R(); let b = R()
        #expect(isSameSVGBlockRenderer(nil, nil))
        #expect(!isSameSVGBlockRenderer(a, nil))
        #expect(isSameSVGBlockRenderer(a, a))
        #expect(!isSameSVGBlockRenderer(a, b))
    }
    @Test("modifier accepts concrete and nil (compile + behavior)")
    func modifierOptional() {
        _ = Text("x").svgRenderer(R())
        _ = Text("x").svgRenderer(nil)   // git-反证 anchor: non-optional param would fail to compile here
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SVGBlockRendererModifierTests 2>&1 | tail -5`
Expected: FAIL — `markdownSVGBlockRenderer`/`isSameSVGBlockRenderer`/`svgRenderer` unknown.

- [ ] **Step 3: Write minimal implementation**

`Sources/MarkdownKit/SVGBlockRendererIdentity.swift` (mirror `MathRendererIdentity.swift` exactly, svg types, internal access):

```swift
import MarkdownRenderKit

/// 单一共享身份比较（对标 MathRendererIdentity，PR #4 r5：去两 representable 重复）。
/// Single shared identity check (mirrors MathRendererIdentity; PR #4 r5 de-dup).
func isSameSVGBlockRenderer(_ a: (any SVGBlockRendering)?, _ b: (any SVGBlockRendering)?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?): return x === y   // protocol is AnyObject → direct identity, no boxing
    default: return false
    }
}
```

`Sources/MarkdownKit/SVGBlockRendererModifier.swift` (mirror `MathRendererModifier.swift`, optional param):

```swift
import SwiftUI
import MarkdownRenderKit

private struct SVGBlockRendererKey: EnvironmentKey {
    static let defaultValue: (any SVGBlockRendering)? = nil
}

public extension EnvironmentValues {
    var markdownSVGBlockRenderer: (any SVGBlockRendering)? {
        get { self[SVGBlockRendererKey.self] }
        set { self[SVGBlockRendererKey.self] = newValue }
    }
}

public extension View {
    /// 注入 SVG 代码块渲染器；传 nil 可在运行时禁用而无需 branch 视图树
    /// （PR #4 r5：与可选 env 一致）。Inject the ```svg renderer; pass nil to
    /// disable at runtime without branching the view tree.
    func svgRenderer(_ renderer: (any SVGBlockRendering)?) -> some View {
        environment(\.markdownSVGBlockRenderer, renderer)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter SVGBlockRendererModifierTests 2>&1 | tail -3`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownKit/SVGBlockRendererIdentity.swift Sources/MarkdownKit/SVGBlockRendererModifier.swift Tests/MarkdownKitTests/SVGBlockRendererModifierTests.swift
git commit -m "feat(markdownkit): .svgRenderer(_:) optional modifier + shared identity helper"
```

---

### Task 5: `MarkdownLabelView` wiring — view-owned cache + `triggerSVGBlockLoads` (iOS + AppKit)

**Files:**
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView.swift` (both `#if canImport(UIKit)` and `#elseif canImport(AppKit)` class bodies, symmetric)
- Modify: `Sources/MarkdownKit/MarkdownText.swift`, `Sources/MarkdownKit/MarkdownStreamingText.swift` (representable: read env + identity-guarded assignment)
- Test: `Tests/MarkdownKitTests/SVGBlockViewWiringTests.swift`, `Tests/MarkdownMathTests/StreamingSVGBlockCacheSurvivesRendererRecreationTests.swift`

**Delta vs spec §5 (CRITICAL — post-PR#4):** the svg cache/scale/generation are **view-owned** (`private var _svgBlockCache: [SVGBlockCacheKey: SVGBlockGlyph] = [:]`, `_svgRasterScale: CGFloat = 1`, `_svgBlockRendererGeneration: Int = 0`) and **re-seeded into every freshly created renderer in the `cachedRenderer` getter**, exactly mirroring `_mathCache`/`_imageCache` (post-`e364b4e`). The spec's "svgBlockCache on renderer, platform fills it" alone would reintroduce the streaming-width-churn cache-discard bug `e364b4e` fixed — do NOT do renderer-only.

Read in `MarkdownLabelView.swift` (both platform branches): `_mathCache`/`_imageCache` field decls; the `cachedRenderer` getter's `renderer.imageCache = self._imageCache` / `renderer.mathCache = self._mathCache` re-seed lines; `mathRenderer` `didSet`; `triggerMathLoads(in:)` final form; its 4 call sites (full `updateContent` path + incremental `applyDocument` path, each platform). Mirror each for svg, **adjacent to the math equivalents**, symmetric across platforms.

- [ ] **Step 1: Write the failing tests**

`Tests/MarkdownKitTests/SVGBlockViewWiringTests.swift`:

```swift
import Testing
import Foundation
@testable import MarkdownRenderKit
@testable import MarkdownPlatformView
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private final class ImgSVGRenderer: SVGBlockRendering, @unchecked Sendable {
    func render(svg: String, availableWidth: CGFloat, scale: CGFloat) async -> SVGBlockOutcome {
        #if canImport(UIKit)
        return .rendered(SVGBlockGlyph(image: UIGraphicsImageRenderer(size: .init(width: 50, height: 30)).image { _ in }))
        #else
        return .rendered(SVGBlockGlyph(image: NSImage(size: .init(width: 50, height: 30))))
        #endif
    }
}

@Suite("SVG block view wiring")
@MainActor struct SVGBlockViewWiringTests {
    @Test("```svg doc: placeholder marker enumerable, then async write-back yields an attachment")
    func placeholderThenAttachment() async {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 4000))
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #elseif canImport(AppKit)
        view.layoutSubtreeIfNeeded()
        #endif
        view.svgBlockRenderer = ImgSVGRenderer()
        for _ in 0..<20 { await Task.yield(); try? await Task.sleep(nanoseconds: 20_000_000) }
        view.setMarkdown("```svg\n<svg viewBox=\"0 0 10 6\"/>\n```\n\ntail")
        var hasAttachment = false
        for _ in 0..<200 {
            await Task.yield(); try? await Task.sleep(nanoseconds: 30_000_000)
            let s = view._renderedSVGBlockStateForTesting()
            if s.attachmentCount >= 1 { hasAttachment = true; break }
        }
        #expect(hasAttachment)   // miss → marker → coordinator → write-back → attachment
    }
}
```

`Tests/MarkdownMathTests/StreamingSVGBlockCacheSurvivesRendererRecreationTests.swift` — **faithful streaming + width-churn guard** (mirror `StreamingMathCacheSurvivesRendererRecreationTests.swift` exactly; this is the load-bearing guard per [[bug1-streaming-layout-device-verify]] — host-green ≠ device unless the guard reproduces streaming + width churn):

```swift
import Testing
import Foundation
@testable import MarkdownRenderKit
@testable import MarkdownPlatformView
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private final class ChurnSVGRenderer: SVGBlockRendering, @unchecked Sendable {
    func render(svg: String, availableWidth: CGFloat, scale: CGFloat) async -> SVGBlockOutcome {
        #if canImport(UIKit)
        return .rendered(SVGBlockGlyph(image: UIGraphicsImageRenderer(size: .init(width: 60, height: 40)).image { _ in }))
        #else
        return .rendered(SVGBlockGlyph(image: NSImage(size: .init(width: 60, height: 40))))
        #endif
    }
}

@Suite("Streaming SVG-block cache survives renderer recreation (mirror Bug 1 math)")
@MainActor struct StreamingSVGBlockCacheSurvivesRendererRecreationTests {
    @Test("streaming + width churn: resolved svg attachment must stay resolved across renderer recreation")
    func churnHoldsResolved() async {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 10_000))
        #if canImport(AppKit)
        view.layoutSubtreeIfNeeded()
        #endif
        view.svgBlockRenderer = ChurnSVGRenderer()
        for _ in 0..<20 { await Task.yield(); try? await Task.sleep(nanoseconds: 20_000_000) }
        let src = "intro paragraph one two three\n\n```svg\n<svg viewBox=\"0 0 12 8\"/>\n```\n\ntail paragraph alpha beta gamma delta\n"
        let toks: [String] = stride(from: src.startIndex, to: src.endIndex, by: 2).map {
            String(src[$0..<(src.index($0, offsetBy: 2, limitedBy: src.endIndex) ?? src.endIndex)])
        }
        for (i, t) in toks.enumerated() {
            if i == 0 { view.setMarkdown(t) } else { view.appendMarkdown(t) }
            if i % 4 == 0 { view.frame = CGRect(x: 0, y: 0, width: (i % 8 == 0) ? 322 : 318, height: 10_000) }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        var consecutive = 0, held = false, toggle = false
        for step in 0..<320 {
            await Task.yield(); try? await Task.sleep(nanoseconds: 18_000_000)
            if step % 3 == 0 {
                toggle.toggle()
                view.frame = CGRect(x: 0, y: 0, width: toggle ? 322 : 318, height: 10_000)
                #if canImport(AppKit)
                view.layoutSubtreeIfNeeded()
                #endif
            }
            let s = view._renderedSVGBlockStateForTesting()
            if s.markerCount == 0 && s.attachmentCount == 1 {
                consecutive += 1
                if consecutive >= 8 { held = true; break }
            } else { consecutive = 0 }
        }
        #expect(held, "under width churn the resolved ```svg image must survive renderer recreation (view-owned cache + getter re-seed)")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "SVGBlockViewWiringTests|StreamingSVGBlockCacheSurvivesRendererRecreationTests" 2>&1 | tail -6`
Expected: FAIL — `svgBlockRenderer` / `_renderedSVGBlockStateForTesting` unknown.

- [ ] **Step 3: Write minimal implementation**

In `MarkdownLabelView.swift` **both** platform class bodies, symmetric, adjacent to math equivalents:
1. Fields: `private let _svgBlockCoordinator = SVGBlockLoadCoordinator()`; `private var _svgBlockCache: [SVGBlockCacheKey: SVGBlockGlyph] = [:]`; `private var _svgRasterScale: CGFloat = 1`; `private var _svgBlockRendererGeneration: Int = 0`.
2. `public var svgBlockRenderer: (any SVGBlockRendering)? { didSet { Task { await self._svgBlockCoordinator.setRenderer(self.svgBlockRenderer) } } }` (copy the math `didSet` eventual-consistency comment, svg-worded).
3. In `cachedRenderer` getter, beside `renderer.mathCache = self._mathCache` etc., add: `renderer.svgBlockCache = self._svgBlockCache`; `renderer.svgRasterScale = self._svgRasterScale`; `renderer.svgRendererGeneration = self._svgBlockRendererGeneration`.
4. Add `private func triggerSVGBlockLoads(in range: NSRange)` mirroring `triggerMathLoads(in:)` final form: guard `self.svgBlockRenderer != nil` & attributedString; enumerate `.markdownSVGBlockSource` in clamped range collecting `(svg: String)`; one `Task`: read `gen = await self._svgBlockCoordinator.generation`, build `SVGBlockCacheKey(svg:, availableWidth: max(bounds.width,1), rasterScale: scale, rendererGeneration: gen)` (scale = iOS `window?.screen.scale ?? UIScreen.main.scale` / AppKit `window?.backingScaleFactor ?? 2`); `loadIfNeeded` all; `awaitGlyph` all; if any resolved, one `await MainActor.run { self._svgRasterScale = scale; self._svgBlockRendererGeneration = gen; for e in resolved { self._svgBlockCache[e.key] = e.glyph; self._cachedRenderer?.svgBlockCache[e.key] = e.glyph }; self.updateContent() }` (mirror the math write-back's view-store-is-truth + transient double-write + single `updateContent`).
5. Call `self.triggerSVGBlockLoads(in:)` at **every** site that calls `self.triggerMathLoads(in:)` (4: full `updateContent` range + incremental `applyDocument` suffix range, each platform), with the identical range argument.
6. Add internal test seam `func _renderedSVGBlockStateForTesting() -> (markerCount: Int, attachmentCount: Int)` mirroring `_renderedMathStateForTesting()` (read it): enumerate `contentStorage.attributedString` for `.markdownSVGBlockSource` count and `.attachment` count; internal, read-only, both platforms.

In `MarkdownText.swift` & `MarkdownStreamingText.swift` (both representables, both platform branches): beside the `@Environment(\.markdownMathRenderer)` read + identity-guarded `view.mathRenderer` assignment, add `@Environment(\.markdownSVGBlockRenderer)` and, in the same update method, `if !isSameSVGBlockRenderer(context.coordinator.lastSVGBlockRenderer, self.svgRenderer) { view.svgBlockRenderer = self.svgRenderer; context.coordinator.lastSVGBlockRenderer = self.svgRenderer }` — add `var lastSVGBlockRenderer: (any SVGBlockRendering)?` to each Coordinator beside `lastMathRenderer`. `MarkdownEditor` is not touched (editor never renders svg).

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter "SVGBlockViewWiringTests|StreamingSVGBlockCacheSurvivesRendererRecreationTests" 2>&1 | tail -4`
Expected: PASS (2 tests).

- [ ] **Step 5: git-反证 (prove the streaming guard is genuine)**

Temporarily delete the 3 svg re-seed lines in the `cachedRenderer` getter (step 3.3). Run: `swift test --filter StreamingSVGBlockCacheSurvivesRendererRecreationTests 2>&1 | tail -3`
Expected: **RED** (`held == false` — churn discards the cache). Restore the 3 lines; re-run → **GREEN**. Record the RED/GREEN output in the task notes.

- [ ] **Step 6: Full regression + iOS**

Run: `swift test 2>&1 | tail -3` (all green, math/Bug1-4 guards unaffected) and `xcodebuild -project Example/Example.xcodeproj -scheme Example -destination 'generic/platform=iOS' build 2>&1 | tail -3` (BUILD SUCCEEDED).

- [ ] **Step 7: Commit**

```bash
git add Sources/MarkdownPlatformView/MarkdownLabelView.swift Sources/MarkdownKit/MarkdownText.swift Sources/MarkdownKit/MarkdownStreamingText.swift Tests/MarkdownKitTests/SVGBlockViewWiringTests.swift Tests/MarkdownMathTests/StreamingSVGBlockCacheSurvivesRendererRecreationTests.swift
git commit -m "feat(platformview): view-owned svg cache + triggerSVGBlockLoads wiring (iOS+AppKit, faithful churn guard)"
```

---

### Task 6: `SwiftDrawSVGBlockRenderer` (MarkdownMath, self-contained — no SVGRasterizer refactor)

**Files:**
- Create: `Sources/MarkdownMath/SwiftDrawSVGBlockRenderer.swift`
- Test: `Tests/MarkdownMathTests/SwiftDrawSVGBlockRendererTests.swift`

**DRY decision (resolves spec §7/§9.1):** implement SwiftDraw parse + rasterize **self-contained** in this file. Do **NOT** extract/refactor `SVGRasterizer` (spec §9.1 hard gate: zero math-path regression risk outweighs the small duplication). Read `Sources/MarkdownMath/SVGRasterizer.swift` **read-only** to copy the correct idioms: SwiftDraw `SVG(data:)` parse, the platform `rasterize` branch (`#if canImport(UIKit) drawing.rasterize(size:scale:)` / `#elseif canImport(AppKit) drawing.rasterize(with:scale:); image.size = targetPointSize`), and the point-size contract. **No color injection** (do not call `injectColor`/`normalizeUnits`-color paths; SVG keeps author colors). Sizing: from `drawing.size` (SwiftDraw-parsed viewBox/width/height) compute native aspect; `targetWidth = min(nativeWidth, availableWidth)` (if `availableWidth <= 0` or non-finite → native size), `targetHeight = targetWidth * nativeHeight / nativeWidth`; degenerate (≤1pt or non-finite) → `.failed`. `Task.isCancelled` → `.cancelled`. parse failure → `.failed`.

- [ ] **Step 1: Write the failing test** — `Tests/MarkdownMathTests/SwiftDrawSVGBlockRendererTests.swift`

```swift
import Testing
import Foundation
@testable import MarkdownRenderKit
@testable import MarkdownMath
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite("SwiftDrawSVGBlockRenderer")
struct SwiftDrawSVGBlockRendererTests {
    let valid = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 200 100\"><rect width=\"200\" height=\"100\" fill=\"#3366cc\"/></svg>"

    @Test("valid svg → rendered, point-size (not pixel×scale), fit-width, preserve aspect, no upscale")
    func renderedPointSize() async {
        let r = SwiftDrawSVGBlockRenderer()
        let out = await r.render(svg: valid, availableWidth: 100, scale: 3)
        guard case .rendered(let g) = out else { #expect(Bool(false), "expected .rendered"); return }
        // native 200×100; availableWidth 100 < 200 → width 100, height 50, points (NOT 300×150)
        #expect(abs(g.image.size.width - 100) <= 0.5)
        #expect(abs(g.image.size.height - 50) <= 0.5)
    }
    @Test("availableWidth ≥ native → no upscale (stays native)")
    func noUpscale() async {
        let r = SwiftDrawSVGBlockRenderer()
        guard case .rendered(let g) = await r.render(svg: valid, availableWidth: 999, scale: 1) else {
            #expect(Bool(false)); return
        }
        #expect(abs(g.image.size.width - 200) <= 0.5)
        #expect(abs(g.image.size.height - 100) <= 0.5)
    }
    @Test("invalid svg → failed")
    func invalid() async {
        let r = SwiftDrawSVGBlockRenderer()
        if case .failed = await r.render(svg: "not svg at all", availableWidth: 100, scale: 1) { } else {
            #expect(Bool(false), "expected .failed")
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SwiftDrawSVGBlockRendererTests 2>&1 | tail -5`
Expected: FAIL — `SwiftDrawSVGBlockRenderer` not found.

- [ ] **Step 3: Write minimal implementation** — `Sources/MarkdownMath/SwiftDrawSVGBlockRenderer.swift`

```swift
import Foundation
import SwiftDraw
import MarkdownRenderKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// SwiftDraw-backed ```svg renderer. Self-contained (no SVGRasterizer refactor —
/// spec §9.1 zero-math-regression hard gate). 不注入颜色：SVG 自带配色按作者原样。
public final class SwiftDrawSVGBlockRenderer: SVGBlockRendering, @unchecked Sendable {
    public init() {}

    public func render(svg: String, availableWidth: CGFloat, scale: CGFloat) async -> SVGBlockOutcome {
        if Task.isCancelled { return .cancelled }
        guard let data = svg.data(using: .utf8), let drawing = SVG(data: data) else { return .failed }
        let native = drawing.size
        guard native.width > 0, native.height > 0,
              native.width.isFinite, native.height.isFinite else { return .failed }

        let targetWidth: CGFloat
        if availableWidth.isFinite, availableWidth > 0 {
            targetWidth = min(native.width, availableWidth)   // fit-width, no upscale
        } else {
            targetWidth = native.width
        }
        let targetHeight = targetWidth * native.height / native.width
        let target = CGSize(width: targetWidth, height: targetHeight)
        guard target.width > 1, target.height > 1,
              target.width.isFinite, target.height.isFinite else { return .failed }
        if Task.isCancelled { return .cancelled }

        #if canImport(UIKit)
        let image = drawing.rasterize(size: target, scale: scale)
        #elseif canImport(AppKit)
        let image = drawing.rasterize(with: target, scale: scale)
        image.size = target            // AppKit point-size contract (mirror SVGRasterizer)
        #else
        return .failed
        #endif
        return .rendered(SVGBlockGlyph(image: image))
    }
}
```

(If the installed SwiftDraw API names differ — verify against `SVGRasterizer.swift`'s actual calls and match them exactly. Do not invent API; mirror the working math rasterizer's SwiftDraw usage verbatim where it overlaps.)

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter SwiftDrawSVGBlockRendererTests 2>&1 | tail -3`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownMath/SwiftDrawSVGBlockRenderer.swift Tests/MarkdownMathTests/SwiftDrawSVGBlockRendererTests.swift
git commit -m "feat(math): SwiftDrawSVGBlockRenderer (self-contained, fit-width, no color injection)"
```

---

### Task 7: Example wiring + degradation + full regression / iOS

**Files:**
- Modify: `Example/Sources/ContentView.swift` (add `.svgRenderer(SwiftDrawSVGBlockRenderer())` to RenderTab & StreamTab; add a ```svg block to sample content)
- Test: `Tests/MarkdownKitTests/SVGBlockDegradationTests.swift`

- [ ] **Step 1: Write the failing test** — degradation contract

```swift
import Testing
import Foundation
@testable import MarkdownRenderKit
@testable import MarkdownCore

@Suite("SVG block degradation")
struct SVGBlockDegradationTests {
    @Test("no renderer (empty cache) → ```svg stays a readable highlighted code block, not crash/empty")
    func noRendererDegrades() {
        let r = AttributedStringRenderer(style: .default, availableWidth: 320)   // svgBlockCache empty
        let out = r.renderBlock(.codeBlock(language: "svg", body: "<svg viewBox=\"0 0 4 4\"/>"))
        #expect(out.length > 0)
        #expect(out.string.contains("<svg"))            // source visible (degraded readable state)
        #expect(!out.string.contains("\u{FFFC}"))       // no attachment when un-rendered
        var marked = false
        out.enumerateAttribute(.markdownSVGBlockSource, in: NSRange(location: 0, length: out.length)) { v, _, _ in
            if v != nil { marked = true }
        }
        #expect(marked)
    }
}
```

- [ ] **Step 2: Run to verify it fails / then passes**

Run: `swift test --filter SVGBlockDegradationTests 2>&1 | tail -3`
Expected: this should PASS already if Tasks 1-2 are correct (degradation is the cache-miss path). If it FAILS, fix the Task-2 miss path until green. (This task's test is a contract guard, not new production code.)

- [ ] **Step 3: Wire the Example**

Read `Example/Sources/ContentView.swift`. Where `.mathRenderer(MathJaxRenderer())` is applied to the RenderTab and StreamTab `MarkdownText`/`MarkdownStreamingText`, add `.svgRenderer(SwiftDrawSVGBlockRenderer())` (same view, chained). Add to the sample markdown a ```svg block, e.g.:

````
## SVG 代码块（流式渲染）

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 60"><rect width="120" height="60" rx="8" fill="#4C8BF5"/><text x="60" y="38" font-size="20" text-anchor="middle" fill="white">SVG</text></svg>
```
````

Ensure `import MarkdownMath` is present in ContentView (it already is for `MathJaxRenderer`).

- [ ] **Step 4: Full regression gate**

Run, all must pass:
- `swift build -Xswiftc -warnings-as-errors 2>&1 | tail -3` → `Build complete!` 0/0
- `swift test 2>&1 | tail -3` → all green (every prior svg task + **all** existing tests: math, Bug1/2/3/4 guards, wide-table, pandoc, round-1..5 PR#4 guards — zero regression)
- `xcodebuild -project Example/Example.xcodeproj -scheme Example -destination 'generic/platform=iOS' build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`
- Core/RenderKit zero-SwiftDraw check: `grep -rn "SwiftDraw" Sources/MarkdownCore Sources/MarkdownRenderKit Sources/MarkdownPlatformView` → **zero hits** (SwiftDraw only in MarkdownMath).

- [ ] **Step 5: Commit**

```bash
git add Example/Sources/ContentView.swift Tests/MarkdownKitTests/SVGBlockDegradationTests.swift
git commit -m "feat(example): wire .svgRenderer + sample ```svg; degradation contract guard"
```

---

## Self-Review

**1. Spec coverage** — every spec section maps to a task:
- §1/§10 render ```svg as image / degrade / non-svg unchanged / editor untouched → Tasks 2, 5, 7 (degradation test, `nonSvgUnchanged`, editor not wired in Task 5).
- §2 RenderKit zero-dep + point-size + reuse-math-discipline → Tasks 1-3 (zero-dep protocol), Task 6 (point-size), Task 5 (view-owned cache + resetLayout reuse).
- §3 module layering → Tasks 1/2 (RenderKit), 3/5 (PlatformView), 4 (Kit), 6 (Math); zero-SwiftDraw grep in Task 7 step 4.
- §4 protocol/types/attr/renderCodeBlock branch → Tasks 1, 2.
- §5 coordinator + wiring → Tasks 3, 5 (view-owned cache is the post-PR#4 hardening over the spec).
- §6 modifier + identity guard → Task 4 (shared helper + optional param = post-PR#4 hardening over the spec).
- §7 SwiftDrawSVGBlockRenderer + DRY decision → Task 6 (resolved: self-contained, no SVGRasterizer refactor).
- §8 tests (RenderKit / coordinator / env / wiring / MarkdownMath gated / degradation / no-regression) → Tasks 1-7 test files + Task 5 faithful churn guard + Task 7 regression gate.
- §9 risks: DRY (Task 6 decision), %-width SVG → `.failed` (Task 6 guards via `native>0` checks), streaming partial (swift-markdown native — no task needed), copy via Bug-4 (no task — already covered), security (SwiftDraw static — no code).
- §10 acceptance → Task 7 step 4 is the acceptance gate.

No spec requirement left without a task.

**2. Placeholder scan** — no "TBD/TODO/handle edge cases/similar to Task N". Mirror instructions name the exact template file + exact deltas + provide full new/test code. The two "verify SwiftDraw API against SVGRasterizer" and "extract highlighted-code helper if inline" notes are concrete conditional instructions with the fallback specified, not placeholders.

**3. Type consistency** — `SVGBlockRendering` / `SVGBlockGlyph` / `SVGBlockOutcome` / `SVGBlockCacheKey` / `.markdownSVGBlockSource` / `svgBlockCache` / `svgRasterScale` / `svgRendererGeneration` / `_svgBlockCache` / `_svgRasterScale` / `_svgBlockRendererGeneration` / `_svgBlockCoordinator` / `svgBlockRenderer` / `triggerSVGBlockLoads` / `isSameSVGBlockRenderer` / `markdownSVGBlockRenderer` / `svgRenderer(_:)` / `lastSVGBlockRenderer` / `_renderedSVGBlockStateForTesting` / `SwiftDrawSVGBlockRenderer` — used consistently across all tasks; coordinator `loadIfNeeded(key:svg:availableWidth:scale:)` signature consistent between Task 3 def and Task 5 caller.

No issues found.
