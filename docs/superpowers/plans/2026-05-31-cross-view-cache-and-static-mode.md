# 跨 view cache + static/streaming 占位区分 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SVG / math 异步渲染的未命中分支按调用方式区分占位形态（`setMarkdown` 静态 → 透明 attachment，`appendMarkdown` 流式 → 现有源码）；cache 跨 MarkdownLabelView 共享（shared singleton）。下游 oh-my-exam 端的 fade-in 兜底补丁随后可删。

**Architecture:** A 块 `SVGBlockLoadCoordinator.shared` / `MathLoadCoordinator.shared` 内部单例化，view 默认引用；B 块新增 `PlaceholderMode` enum + `AttributedStringRenderer` init 多收一个 `placeholderMode`，cache-miss 分支按 mode 选两条；C 块新增 `SVGViewBoxParser` 提 aspect 给 static-miss 占位 attachment 算高度，math 按 displayMode + pointSize 估算。

**Tech Stack:** Swift Testing (`@Test` / `@Suite`)、Swift 6 严格并发（actor）、TextKit 2（NSTextAttachment）、SwiftDraw SVG 渲染器、MathJax 渲染器。`swift build -Xswiftc -warnings-as-errors` + `swift test`。

依据 spec：`docs/superpowers/specs/2026-05-31-cross-view-cache-and-static-mode-design.md`。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `Sources/MarkdownRenderKit/PlaceholderMode.swift` | `public enum PlaceholderMode: Sendable { case static; case streaming }` | Create |
| `Sources/MarkdownRenderKit/SVGViewBoxParser.swift` | `public enum SVGViewBoxParser { static func parseAspect(from: String) -> CGFloat? }`——首 4KB 内提取 viewBox h/w | Create |
| `Sources/MarkdownRenderKit/AttributedStringRenderer.swift` | init 多收 `placeholderMode: PlaceholderMode = .streaming`（默认保留旧行为）；私有 `transparentAttachment(width:height:)` 工厂；`renderSVGBlock` / `renderMathBlock` cache-miss 分支按 mode 分两条 | Modify |
| `Sources/MarkdownPlatformView/SVGBlockLoadCoordinator.swift` | 加 `public static let shared = SVGBlockLoadCoordinator()` | Modify |
| `Sources/MarkdownPlatformView/MathLoadCoordinator.swift` | 加 `public static let shared = MathLoadCoordinator()` | Modify |
| `Sources/MarkdownPlatformView/MarkdownLabelView.swift` | ①`_svgBlockCoordinator` / `_mathCoordinator` 改用 `.shared`；②加 `private var renderMode: PlaceholderMode = .static`，`setMarkdown` 翻 `.static`、`appendMarkdown` 翻 `.streaming`；③6 个 `AttributedStringRenderer(...)` 实例化点传 `placeholderMode: self.renderMode` | Modify |
| `Tests/MarkdownKitTests/SVGViewBoxParserTests.swift` | 解析器单测（有/无 viewBox、格式坏、4KB 上限、多 `<svg>`） | Create |
| `Tests/MarkdownKitTests/PlaceholderModeRendererTests.swift` | AttributedStringRenderer 在 static / streaming 两 mode 下 SVG/math cache-miss 分支差异 + cache-hit 一致；TransparentAttachment 尺寸契约 | Create |
| `Tests/MarkdownKitTests/MarkdownLabelViewRenderModeTests.swift` | view 初始 mode == `.static`、`setMarkdown` 翻 `.static`、`appendMarkdown` 翻 `.streaming`、连续调用按最后一次 | Create |
| `Tests/MarkdownKitTests/SharedCoordinatorTests.swift` | 两个 view（或 mock 协调消费者）共用 `.shared` 时 renderer 仅被调一次；`init()` 创建的独立实例与 shared 互不影响 | Create |

约定遵循（来自 spec §5.3 + 仓 doc 惯例）：
- 测试用 Swift Testing（`@Test` / `@Suite`）
- doc-comments 中英对照（参看仓内 `MarkdownLabelView.swift` / `SVGBlockLoadCoordinator.swift` 既有风格）
- `swift build -Xswiftc -warnings-as-errors` 严格通过

---

## Task 1: SVGViewBoxParser

**Files:**
- Create: `Sources/MarkdownRenderKit/SVGViewBoxParser.swift`
- Test: `Tests/MarkdownKitTests/SVGViewBoxParserTests.swift`

> 独立纯函数。无依赖。先做。

- [ ] **Step 1: 写失败测试**

`Tests/MarkdownKitTests/SVGViewBoxParserTests.swift`：

```swift
import Foundation
@testable import MarkdownRenderKit
import Testing

@Suite("SVGViewBoxParser")
struct SVGViewBoxParserTests {
    @Test func parsesIntegerViewBox() {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="480" height="320" viewBox="0 0 480 320"></svg>"#
        let aspect = SVGViewBoxParser.parseAspect(from: svg)
        #expect(aspect != nil)
        #expect(abs((aspect ?? 0) - (320.0 / 480.0)) < 0.0001)   // h/w
    }

    @Test func parsesDecimalViewBox() {
        let svg = #"<svg viewBox="0 0 100.5 200.25"></svg>"#
        let aspect = SVGViewBoxParser.parseAspect(from: svg)
        #expect(aspect != nil)
        #expect(abs((aspect ?? 0) - (200.25 / 100.5)) < 0.0001)
    }

    @Test func returnsNilWhenViewBoxMissing() {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="480" height="320"></svg>"#
        #expect(SVGViewBoxParser.parseAspect(from: svg) == nil)
    }

    @Test func returnsNilWhenViewBoxHasWrongNumberOfValues() {
        let svg = #"<svg viewBox="0 0 480"></svg>"#
        #expect(SVGViewBoxParser.parseAspect(from: svg) == nil)
    }

    @Test func returnsNilWhenViewBoxContainsNonNumeric() {
        let svg = #"<svg viewBox="0 0 abc 320"></svg>"#
        #expect(SVGViewBoxParser.parseAspect(from: svg) == nil)
    }

    @Test func returnsNilWhenWidthIsZero() {
        let svg = #"<svg viewBox="0 0 0 320"></svg>"#
        #expect(SVGViewBoxParser.parseAspect(from: svg) == nil)   // 防 division by zero
    }

    @Test func handlesSVGTagAfterXMLDeclaration() {
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
        <svg viewBox="0 0 200 100" xmlns="http://www.w3.org/2000/svg"></svg>
        """
        let aspect = SVGViewBoxParser.parseAspect(from: svg)
        #expect(aspect != nil)
        #expect(abs((aspect ?? 0) - 0.5) < 0.0001)
    }

    @Test func bailsOutWhenSVGTagPastFirst4KB() {
        let padding = String(repeating: " ", count: 5000)
        let svg = padding + #"<svg viewBox="0 0 480 320"></svg>"#
        #expect(SVGViewBoxParser.parseAspect(from: svg) == nil)   // 性能上限契约
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd /Users/evan/Repositories/MarkdownKit && swift test --filter SVGViewBoxParserTests 2>&1 | tail -20`
Expected: 编译失败 — `SVGViewBoxParser` 未定义。

- [ ] **Step 3: 实现 SVGViewBoxParser**

`Sources/MarkdownRenderKit/SVGViewBoxParser.swift`：

```swift
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 在 SVG 字符串首 4KB 内提取 `<svg ... viewBox="x y w h" ...>` 的高宽比（`h / w`）。
/// 调用方在 AttributedStringRenderer 的 static-miss 分支用它给透明占位 attachment 算高度；
/// 失败（找不到、格式坏、宽为 0、`<svg ` 在首 4KB 外）一律返回 nil，调用方走默认 aspect。
///
/// Returns `h / w` for the `viewBox` of the outermost `<svg ...>` tag found within
/// the first 4 KB of `svg`. Returns nil on missing/malformed input or when width is 0.
/// Typical execution < 100µs; not memoised (callers invoke per cache miss).
public enum SVGViewBoxParser {
    /// 上限：超过此字节数后还没遇到 `<svg ` 起始即放弃，避免 pathological 长字符串扫描成本。
    private static let scanWindowBytes = 4096

    public static func parseAspect(from svg: String) -> CGFloat? {
        // 截首段，超过 scanWindowBytes 不再扫
        let scan = svg.prefix(self.scanWindowBytes)
        // 找 "<svg " 或 "<svg>" 起始
        guard let svgRange = scan.range(of: #"<svg(\s|>)"#, options: .regularExpression) else {
            return nil
        }
        // 找该 svg tag 内的 viewBox="..." attribute
        // 限定到 svgRange 之后的内容，止于第一个 ">"（tag 结束符）
        let afterSVG = scan[svgRange.upperBound...]
        guard let tagEnd = afterSVG.firstIndex(of: ">") else { return nil }
        let tagBody = afterSVG[..<tagEnd]
        guard let vbRange = tagBody.range(of: #"viewBox\s*=\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        // 抽出引号内 4 个数
        let vbAttr = tagBody[vbRange]
        guard let quoteStart = vbAttr.firstIndex(of: "\""),
              let quoteEnd = vbAttr.lastIndex(of: "\""),
              quoteStart < quoteEnd else {
            return nil
        }
        let inner = vbAttr[vbAttr.index(after: quoteStart)..<quoteEnd]
        let tokens = inner.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" })
        guard tokens.count == 4 else { return nil }
        let nums = tokens.compactMap { Double($0) }
        guard nums.count == 4 else { return nil }
        let w = nums[2], h = nums[3]
        guard w > 0 else { return nil }
        return CGFloat(h / w)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter SVGViewBoxParserTests 2>&1 | tail -15`
Expected: PASS（8 个 case）。

- [ ] **Step 5: 提交**

```bash
cd /Users/evan/Repositories/MarkdownKit
git add Sources/MarkdownRenderKit/SVGViewBoxParser.swift Tests/MarkdownKitTests/SVGViewBoxParserTests.swift
git commit -m "feat(render): SVGViewBoxParser 解析首 4KB 内的 viewBox 取高宽比 + 8 单测"
```

---

## Task 2: SVGBlockLoadCoordinator / MathLoadCoordinator shared 单例

**Files:**
- Modify: `Sources/MarkdownPlatformView/SVGBlockLoadCoordinator.swift`
- Modify: `Sources/MarkdownPlatformView/MathLoadCoordinator.swift`
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView.swift`（2 处 `_xxxCoordinator` 初始化器）
- Test: `Tests/MarkdownKitTests/SharedCoordinatorTests.swift`

> A 块。Coordinator 已有完整 LRU/dedup/gen 逻辑，只是 view-内私有。加 shared 静态属性 + 把 view 字段改用它。`init()` public 保留供测试取独立实例。

- [ ] **Step 1: 写失败测试**

`Tests/MarkdownKitTests/SharedCoordinatorTests.swift`：

```swift
import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing

@Suite("Shared coordinator singletons")
struct SharedCoordinatorTests {
    @Test func svgSharedSingletonReturnsSameInstance() async {
        let a = SVGBlockLoadCoordinator.shared
        let b = SVGBlockLoadCoordinator.shared
        #expect(a === b)
    }

    @Test func mathSharedSingletonReturnsSameInstance() async {
        let a = MathLoadCoordinator.shared
        let b = MathLoadCoordinator.shared
        #expect(a === b)
    }

    @Test func independentInitInstancesAreNotShared() async {
        let a = SVGBlockLoadCoordinator()
        let b = SVGBlockLoadCoordinator()
        #expect(a !== b)
        #expect(a !== SVGBlockLoadCoordinator.shared)
    }

    @Test func mathIndependentInitInstancesAreNotShared() async {
        let a = MathLoadCoordinator()
        let b = MathLoadCoordinator()
        #expect(a !== b)
        #expect(a !== MathLoadCoordinator.shared)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd /Users/evan/Repositories/MarkdownKit && swift test --filter SharedCoordinatorTests 2>&1 | tail -15`
Expected: 编译失败 — `static let shared` 未定义。

- [ ] **Step 3: 加 shared 单例**

`Sources/MarkdownPlatformView/SVGBlockLoadCoordinator.swift`：在 `public actor SVGBlockLoadCoordinator { ... }` 闭合 `}` 之后追加：

```swift
extension SVGBlockLoadCoordinator {
    /// 进程级共享实例。所有 MarkdownLabelView 默认引用，cache 跨 view 不重建。
    ///
    /// 既存 LRU(256) / negative(1024) / dedup / 代际逻辑全部继承——同 process
    /// 全部 markdown 视图共用这一份。`setRenderer` 调用会清整体 cache + 代际自增，
    /// 因此**所有 view 应该共用同一个 renderer 实例**（MarkdownKit 的 SwiftUI
    /// 注入约定下成立）；若不同 view 注入不同 renderer，cache 会被互相清掉——
    /// 这条约束记录在此，不视为 bug。
    ///
    /// Tests requiring isolation can construct independent instances via `init()`.
    public static let shared = SVGBlockLoadCoordinator()
}
```

`Sources/MarkdownPlatformView/MathLoadCoordinator.swift`：同样在 actor 闭合后追加：

```swift
extension MathLoadCoordinator {
    /// 进程级共享实例。所有 MarkdownLabelView 默认引用，cache 跨 view 不重建。
    /// 约束同 `SVGBlockLoadCoordinator.shared`：调用方应保证全 process 用同一个
    /// MathRendering 实例，否则 setRenderer 会反复清 cache。Tests 通过 `init()` 取独立实例。
    public static let shared = MathLoadCoordinator()
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter SharedCoordinatorTests 2>&1 | tail -10`
Expected: PASS（4 case）。

- [ ] **Step 5: 把 MarkdownLabelView 改用 shared**

在 `Sources/MarkdownPlatformView/MarkdownLabelView.swift` 里搜索 `_svgBlockCoordinator = SVGBlockLoadCoordinator(` 与 `_mathCoordinator = MathLoadCoordinator(`，应有两处（UIKit + AppKit 路径各一）。

第一处（约 line 627–628，在 `#if canImport(UIKit)` 块内）当前形如：

```swift
    /// Platform-agnostic async ```svg block render coordinator (dedup/三态/代际).
    private let _svgBlockCoordinator = SVGBlockLoadCoordinator()
```

改为：

```swift
    /// Platform-agnostic async ```svg block render coordinator (dedup/三态/代际).
    /// 默认引用 `.shared`：cross-view cache（同 process 全部 MarkdownLabelView 共用）。
    /// 等价的 `init()` 版本仍可由 tests / 多 renderer 隔离场景手动构造（参见 spec §7 已知约束）。
    private let _svgBlockCoordinator: SVGBlockLoadCoordinator = .shared
```

`_mathCoordinator` 同样处理（同一区域，应紧邻在 _svgBlockCoordinator 上面或下面）。

`#if canImport(AppKit)` 块内的对应两处（约 line 2000+，文件后半段）作同样改动。

> 自检：`grep -n "_svgBlockCoordinator = SVGBlockLoadCoordinator(\|_mathCoordinator = MathLoadCoordinator(" Sources/MarkdownPlatformView/MarkdownLabelView.swift` 应返回 0 行（全部替换完）。

- [ ] **Step 6: 全量构建 + 既有测试不回归**

Run: `cd /Users/evan/Repositories/MarkdownKit && swift build -Xswiftc -warnings-as-errors 2>&1 | tail -5`
Expected: BUILD SUCCEEDED，0 warning。

Run: `swift test 2>&1 | grep -iE "Test Suite|PASSED|FAILED|errors?:" | tail -10`
Expected: 全绿（既有测试不回归——shared 与 init() 行为等价，coordinator 内部状态不变）。

- [ ] **Step 7: 提交**

```bash
git add Sources/MarkdownPlatformView/SVGBlockLoadCoordinator.swift \
        Sources/MarkdownPlatformView/MathLoadCoordinator.swift \
        Sources/MarkdownPlatformView/MarkdownLabelView.swift \
        Tests/MarkdownKitTests/SharedCoordinatorTests.swift
git commit -m "feat(coord): SVGBlockLoadCoordinator.shared / MathLoadCoordinator.shared 单例 + MarkdownLabelView 默认引用 + 4 单测"
```

---

## Task 3: PlaceholderMode + AttributedStringRenderer mode-aware

**Files:**
- Create: `Sources/MarkdownRenderKit/PlaceholderMode.swift`
- Modify: `Sources/MarkdownRenderKit/AttributedStringRenderer.swift`
- Test: `Tests/MarkdownKitTests/PlaceholderModeRendererTests.swift`

> B 块 + C 块的渲染器侧。引入 PlaceholderMode、TransparentAttachment（helper 内联在 renderer 文件）、`renderSVGBlock` / `renderMathBlock` 的 static-miss 新分支。默认 `.streaming` 保留旧行为，调用方显式传 `.static` 才走新分支。

- [ ] **Step 1: 写失败测试**

`Tests/MarkdownKitTests/PlaceholderModeRendererTests.swift`：

```swift
import Foundation
import MarkdownCore
@testable import MarkdownRenderKit
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite("PlaceholderMode-aware rendering")
struct PlaceholderModeRendererTests {
    // MARK: SVG miss 分支按 mode 区分

    @Test func svgStaticMissEmitsTransparentAttachmentWithMarker() {
        let svg = #"<svg viewBox="0 0 480 320"></svg>"#
        let renderer = AttributedStringRenderer(
            style: .default, availableWidth: 600, placeholderMode: .static)
        let block = BlockNode.codeBlock(language: "svg", body: svg)
        let result = renderer.renderBlock(block)

        // 应携带 .markdownSVGBlockSource marker（与 streaming miss 一致）
        let full = NSRange(location: 0, length: result.length)
        var foundMarker = false
        result.enumerateAttribute(.markdownSVGBlockSource, in: full) { v, _, _ in
            if v is String { foundMarker = true }
        }
        #expect(foundMarker)

        // 应含 NSTextAttachment 且 image == nil（透明），bounds 按 viewBox aspect
        var foundTransparentAttachment = false
        result.enumerateAttribute(.attachment, in: full) { v, _, _ in
            guard let att = v as? NSTextAttachment else { return }
            if att.image == nil {
                foundTransparentAttachment = true
                let expectedH: CGFloat = 600 * (320.0 / 480.0)
                #expect(abs(att.bounds.size.height - expectedH) < 1)
                #expect(abs(att.bounds.size.width - 600) < 1)
            }
        }
        #expect(foundTransparentAttachment)
    }

    @Test func svgStreamingMissEmitsHighlightedSourceWithMarker() {
        let svg = #"<svg viewBox="0 0 480 320"></svg>"#
        let renderer = AttributedStringRenderer(
            style: .default, availableWidth: 600, placeholderMode: .streaming)
        let block = BlockNode.codeBlock(language: "svg", body: svg)
        let result = renderer.renderBlock(block)

        // marker 仍打
        let full = NSRange(location: 0, length: result.length)
        var foundMarker = false
        result.enumerateAttribute(.markdownSVGBlockSource, in: full) { v, _, _ in
            if v is String { foundMarker = true }
        }
        #expect(foundMarker)

        // streaming-miss 是文本（高亮源码），不应含透明 attachment
        var foundTransparentAttachment = false
        result.enumerateAttribute(.attachment, in: full) { v, _, _ in
            if let att = v as? NSTextAttachment, att.image == nil { foundTransparentAttachment = true }
        }
        #expect(foundTransparentAttachment == false)

        // 源串字符应在结果里
        #expect(result.string.contains("viewBox"))
    }

    @Test func svgStaticMissFallsBackTo60PercentAspectWhenNoViewBox() {
        let svg = "<svg></svg>"
        let renderer = AttributedStringRenderer(
            style: .default, availableWidth: 600, placeholderMode: .static)
        let block = BlockNode.codeBlock(language: "svg", body: svg)
        let result = renderer.renderBlock(block)

        let full = NSRange(location: 0, length: result.length)
        var attachmentHeight: CGFloat = -1
        result.enumerateAttribute(.attachment, in: full) { v, _, _ in
            if let att = v as? NSTextAttachment, att.image == nil {
                attachmentHeight = att.bounds.size.height
            }
        }
        #expect(abs(attachmentHeight - 600 * 0.6) < 1)
    }

    // MARK: Math miss 分支

    @Test func mathStaticMissEmitsTransparentAttachmentSizedByPointSize() {
        // display math（块级）→ 高度 ≈ pointSize × 2
        var style = RenderStyle.default
        #if canImport(UIKit)
        style.bodyFont = .systemFont(ofSize: 17, weight: .regular)
        #elseif canImport(AppKit)
        style.bodyFont = .systemFont(ofSize: 17)
        #endif
        let renderer = AttributedStringRenderer(
            style: style, availableWidth: 600, placeholderMode: .static)
        let block = BlockNode.mathBlock(latex: "x = \\frac{a}{b}", display: true)
        let result = renderer.renderBlock(block)

        let full = NSRange(location: 0, length: result.length)
        var height: CGFloat = -1
        result.enumerateAttribute(.attachment, in: full) { v, _, _ in
            if let att = v as? NSTextAttachment, att.image == nil { height = att.bounds.size.height }
        }
        #expect(abs(height - 17 * 2.0) < 1)
    }

    // MARK: cache hit 两 mode 一致

    @Test func cacheHitIdenticalAcrossModes() {
        let svg = #"<svg viewBox="0 0 480 320"></svg>"#
        let key = SVGBlockCacheKey(svg: svg, availableWidth: 600, rasterScale: 2, rendererGeneration: 0)
        // 造一个 dummy glyph
        #if canImport(UIKit)
        let dummyImage = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 50)).image { _ in }
        #elseif canImport(AppKit)
        let dummyImage = NSImage(size: CGSize(width: 100, height: 50))
        #endif
        let glyph = SVGBlockGlyph(image: dummyImage)

        for mode in [PlaceholderMode.static, .streaming] {
            var renderer = AttributedStringRenderer(
                style: .default, availableWidth: 600, placeholderMode: mode)
            renderer.svgRasterScale = 2
            renderer.svgRendererGeneration = 0
            renderer.svgBlockCache[key] = glyph
            let block = BlockNode.codeBlock(language: "svg", body: svg)
            let result = renderer.renderBlock(block)

            let full = NSRange(location: 0, length: result.length)
            var hitAttachmentWithImage = false
            result.enumerateAttribute(.attachment, in: full) { v, _, _ in
                if let att = v as? NSTextAttachment, att.image != nil { hitAttachmentWithImage = true }
            }
            #expect(hitAttachmentWithImage, "cache hit branch should emit attachment with image regardless of mode (\(mode))")
        }
    }

    // MARK: 默认 mode 保留旧行为

    @Test func defaultModeIsStreaming() {
        let svg = #"<svg viewBox="0 0 480 320"></svg>"#
        // 不传 placeholderMode → 默认应 .streaming（向后兼容）
        let renderer = AttributedStringRenderer(style: .default, availableWidth: 600)
        let block = BlockNode.codeBlock(language: "svg", body: svg)
        let result = renderer.renderBlock(block)

        // streaming-miss 含源串文本
        #expect(result.string.contains("viewBox"))
    }
}
```

> 注：`BlockNode.codeBlock(language:body:)` / `BlockNode.mathBlock(latex:display:)` 是仓内既有 enum case。如果实际 API 不同（例如 `BlockNode.code(...)`），按既有源调整 case 名。Math case 在 `MarkdownCore/BlockNode.swift` 里：自查 `grep -n "case math\|case code" Sources/MarkdownCore/BlockNode.swift` 取真名。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd /Users/evan/Repositories/MarkdownKit && swift test --filter PlaceholderModeRendererTests 2>&1 | tail -25`
Expected: 编译失败 — `PlaceholderMode` 未定义、`init(..., placeholderMode:)` 参数不存在。

- [ ] **Step 3: 加 PlaceholderMode enum**

`Sources/MarkdownRenderKit/PlaceholderMode.swift`：

```swift
import Foundation

/// 异步渲染（SVG 代码块 / 数学公式）的未命中分支占位形态。
///
/// MarkdownLabelView 根据调用方式翻转：
/// - `setMarkdown(_:)` → `.static`，未渲染期透明 attachment 占位
/// - `appendMarkdown(_:)` → `.streaming`，未渲染期显示高亮源码（用户在看着 chunk 到达）
///
/// Async rendering placeholder mode for SVG code blocks / math formulas.
/// `MarkdownLabelView` flips this based on which entry point is called:
/// - `setMarkdown(_:)` → `.static`: transparent attachment placeholder until glyph arrives
/// - `appendMarkdown(_:)` → `.streaming`: keep highlighted source until glyph arrives
public enum PlaceholderMode: Sendable, Equatable {
    case `static`
    case streaming
}
```

- [ ] **Step 4: AttributedStringRenderer 加 placeholderMode 入参 + 两条 miss 分支**

`Sources/MarkdownRenderKit/AttributedStringRenderer.swift`：

**4.1** 在 init 加参数（保留默认值 `.streaming` 向后兼容）：

把：

```swift
public init(style: RenderStyle = .default, availableWidth: CGFloat = .greatestFiniteMagnitude) {
```

改为：

```swift
public init(
    style: RenderStyle = .default,
    availableWidth: CGFloat = .greatestFiniteMagnitude,
    placeholderMode: PlaceholderMode = .streaming
) {
```

在 init 体里增加 `self.placeholderMode = placeholderMode`，并在公共属性区（紧邻 `public let style`、`public let availableWidth` 等附近）声明：

```swift
public let placeholderMode: PlaceholderMode
```

**4.2** 加私有 transparent attachment 工厂（放在文件末尾或现有 private helper 区）：

```swift
extension AttributedStringRenderer {
    /// Static-mode 占位用的透明 attachment：image=nil、bounds=声明大小，TextKit 自然留白。
    fileprivate func transparentAttachment(width: CGFloat, height: CGFloat) -> NSTextAttachment {
        let att = NSTextAttachment()
        att.image = nil
        att.bounds = CGRect(x: 0, y: 0, width: width, height: max(1, height))
        return att
    }
}
```

**4.3** 改 `renderSVGBlock(svg:)` 的 miss 分支。当前：

```swift
private func renderSVGBlock(svg: String) -> NSAttributedString {
    let key = ...
    if let glyph = self.svgBlockCache[key] {
        // hit: centered attachment with image
        ...
        return m
    }
    // Miss → keep the existing syntax-highlighted code-block rendering
    let highlighted = self.renderHighlightedCodeBlock(language: "svg", body: svg)
    let result = NSMutableAttributedString(attributedString: highlighted)
    result.addAttribute(.markdownSVGBlockSource, value: svg, range: NSRange(location: 0, length: result.length))
    return result
}
```

把 miss 分支改为按 mode 分两条：

```swift
    // Miss: behaviour depends on placeholderMode.
    switch self.placeholderMode {
    case .streaming:
        // 既有行为：高亮源码 + marker，平台层异步派发
        let highlighted = self.renderHighlightedCodeBlock(language: "svg", body: svg)
        let result = NSMutableAttributedString(attributedString: highlighted)
        result.addAttribute(.markdownSVGBlockSource, value: svg, range: NSRange(location: 0, length: result.length))
        return result
    case .static:
        // 新：透明 attachment，按 viewBox aspect 预留高度（解析失败回退 0.6）
        let aspect = SVGViewBoxParser.parseAspect(from: svg) ?? 0.6
        let width = self.availableWidth.isFinite ? self.availableWidth : 480
        let height = width * aspect
        let att = self.transparentAttachment(width: width, height: height)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 0
        let m = NSMutableAttributedString(attachment: att)
        m.addAttribute(.paragraphStyle, value: para.copy() as! NSParagraphStyle,
                       range: NSRange(location: 0, length: m.length))
        m.addAttribute(.markdownSVGBlockSource, value: svg,
                       range: NSRange(location: 0, length: m.length))
        return m
    }
```

**4.4** 改 `renderMathBlock(latex:display:)`（或仓里对应的 math block 渲染函数——`grep -n "renderMathBlock\|renderMath\|markdownMathSource" Sources/MarkdownRenderKit/AttributedStringRenderer.swift` 找到准确签名，函数体的 miss 分支同样按 mode 分支）。

定位到 math 函数的 miss 分支后改成：

```swift
    // Miss: behaviour depends on placeholderMode.
    switch self.placeholderMode {
    case .streaming:
        // 既有行为：高亮源码 + .markdownMathSource marker
        // [保持原有 streaming-miss 逻辑不动，原代码原位置]
        ...
    case .static:
        let pointSize = self.style.bodyFont.pointSize
        let height = display ? pointSize * 2.0 : pointSize * 1.2
        let width = self.availableWidth.isFinite ? self.availableWidth : pointSize * 10
        let att = self.transparentAttachment(width: width, height: height)
        let para = NSMutableParagraphStyle()
        para.alignment = display ? .center : .natural
        para.paragraphSpacing = 0
        let m = NSMutableAttributedString(attachment: att)
        m.addAttribute(.paragraphStyle, value: para.copy() as! NSParagraphStyle,
                       range: NSRange(location: 0, length: m.length))
        m.addAttribute(.markdownMathSource, value: latex,
                       range: NSRange(location: 0, length: m.length))
        return m
    }
```

> 实现注：若 `renderMathBlock` 的 latex/display 不直接在函数签名里（例如内部从 mathSource 类型解构），用现有的解构方式取值；不要新增参数。完整的 math 渲染代码区上下文需在 implementation 时读完函数体后再贴。

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter PlaceholderModeRendererTests 2>&1 | tail -25`
Expected: PASS（6 case 全绿）。

- [ ] **Step 6: 既有测试不回归**

Run: `swift test 2>&1 | grep -iE "Test Suite.*passed|Test Suite.*failed|errors?:" | tail -10`
Expected: 全 suite 绿。默认 placeholderMode == `.streaming` 保持旧行为，既有 SVG/Math renderer tests 不变。

- [ ] **Step 7: 提交**

```bash
git add Sources/MarkdownRenderKit/PlaceholderMode.swift \
        Sources/MarkdownRenderKit/AttributedStringRenderer.swift \
        Tests/MarkdownKitTests/PlaceholderModeRendererTests.swift
git commit -m "feat(render): PlaceholderMode enum + AttributedStringRenderer init 多收 mode + static-miss 透明 attachment 分支（SVG/Math）"
```

---

## Task 4: MarkdownLabelView renderMode tracking + transparent 透传

**Files:**
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView.swift`
- Test: `Tests/MarkdownKitTests/MarkdownLabelViewRenderModeTests.swift`

> view 加 `renderMode` 状态字段；`setMarkdown` / `appendMarkdown` 翻转；6 个 `AttributedStringRenderer(...)` 实例化点传 `placeholderMode: self.renderMode`。

- [ ] **Step 1: 写失败测试**

`Tests/MarkdownKitTests/MarkdownLabelViewRenderModeTests.swift`：

```swift
import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing

@Suite("MarkdownLabelView renderMode tracking")
@MainActor
struct MarkdownLabelViewRenderModeTests {
    @Test func initialRenderModeIsStatic() {
        let view = MarkdownLabelView()
        #expect(view.renderMode == .static)
    }

    @Test func setMarkdownSetsRenderModeStatic() {
        let view = MarkdownLabelView()
        view.appendMarkdown("foo")
        #expect(view.renderMode == .streaming)
        view.setMarkdown("bar")
        #expect(view.renderMode == .static)
    }

    @Test func appendMarkdownSetsRenderModeStreaming() {
        let view = MarkdownLabelView()
        view.setMarkdown("foo")
        #expect(view.renderMode == .static)
        view.appendMarkdown(" bar")
        #expect(view.renderMode == .streaming)
    }

    @Test func consecutiveSetMarkdownStaysStatic() {
        let view = MarkdownLabelView()
        view.setMarkdown("a")
        view.setMarkdown("b")
        #expect(view.renderMode == .static)
    }

    @Test func consecutiveAppendMarkdownStaysStreaming() {
        let view = MarkdownLabelView()
        view.appendMarkdown("a")
        view.appendMarkdown(" b")
        #expect(view.renderMode == .streaming)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter MarkdownLabelViewRenderModeTests 2>&1 | tail -15`
Expected: 编译失败 — `renderMode` 未定义。

- [ ] **Step 3: 加 renderMode 状态字段**

在 `Sources/MarkdownPlatformView/MarkdownLabelView.swift` 的 `#if canImport(UIKit)` 块（约 line 158+ 的 class 定义内）找一个状态字段聚集区，加：

```swift
    /// 占位 mode 跟踪：`setMarkdown` 翻 `.static`、`appendMarkdown` 翻 `.streaming`。
    /// 传给 `AttributedStringRenderer.init(...)` 决定 cache-miss 占位形态。
    /// 默认 `.static`（构造时空内容场景）。
    /// Tracks placeholder mode; flipped by setMarkdown/appendMarkdown.
    public internal(set) var renderMode: PlaceholderMode = .static
```

> `public internal(set)`：tests 需读但仅模块内能写。

`#if canImport(AppKit)` 块（约 line 2000+ 内 class 定义里）同样加一份。

- [ ] **Step 4: setMarkdown / appendMarkdown 翻转 renderMode**

UIKit 块的 `setMarkdown`（line ~499）：

```swift
    public func setMarkdown(_ source: String) {
        self.renderMode = .static
        self._parseSerial += 1
        ...
    }
```

UIKit 块的 `appendMarkdown`（line ~508）：

```swift
    public func appendMarkdown(_ chunk: String) {
        self.renderMode = .streaming
        self.streamingSource += chunk
        ...
    }
```

AppKit 块的对应 `setMarkdown`（line ~1914）和 `appendMarkdown`（line ~1923）同样加 `self.renderMode = .static` / `.streaming` 首行。

- [ ] **Step 5: 6 个 AttributedStringRenderer 实例化点透传 mode**

`grep -n "AttributedStringRenderer(" Sources/MarkdownPlatformView/MarkdownLabelView.swift` 应有 6 处：

```
693:  var renderer = AttributedStringRenderer(style: renderStyle, availableWidth: w)
1288: let renderer = AttributedStringRenderer(style: renderStyle, availableWidth: naturalWidth)
1313: let renderer = AttributedStringRenderer(style: renderStyle, availableWidth: naturalWidth)
2048: var renderer = AttributedStringRenderer(style: renderStyle, availableWidth: w)
2385: let renderer = AttributedStringRenderer(style: renderStyle, availableWidth: naturalWidth)
2410: let renderer = AttributedStringRenderer(style: renderStyle, availableWidth: naturalWidth)
```

每处末尾加 `, placeholderMode: self.renderMode`：

```swift
var renderer = AttributedStringRenderer(
    style: renderStyle, availableWidth: w, placeholderMode: self.renderMode)
```

```swift
let renderer = AttributedStringRenderer(
    style: renderStyle, availableWidth: naturalWidth, placeholderMode: self.renderMode)
```

（具体每处选择换行 / 单行视 80 字符行宽决定。）

- [ ] **Step 6: 跑测试确认通过**

Run: `swift test --filter MarkdownLabelViewRenderModeTests 2>&1 | tail -15`
Expected: PASS（5 case）。

- [ ] **Step 7: 全量回归**

Run: `swift test 2>&1 | grep -iE "Test Suite.*passed|Test Suite.*failed|errors?:" | tail -10`
Expected: 全绿。

Run: `swift build -Xswiftc -warnings-as-errors 2>&1 | tail -5`
Expected: BUILD SUCCEEDED，0 warning。

- [ ] **Step 8: 提交**

```bash
git add Sources/MarkdownPlatformView/MarkdownLabelView.swift \
        Tests/MarkdownKitTests/MarkdownLabelViewRenderModeTests.swift
git commit -m "feat(view): MarkdownLabelView renderMode 状态 + setMarkdown/appendMarkdown 翻转 + 6 处 AttributedStringRenderer 透传"
```

---

## Task 5: 跨 view cache 共享集成验证

**Files:**
- Test: `Tests/MarkdownKitTests/SharedCoordinatorTests.swift`（追加）

> Task 2 加了 shared 单例 + view 用 .shared，但没验过两 view 真的复用 cache。本 task 用 mock renderer 计数器验证。

- [ ] **Step 1: 追加集成测试**

打开 `Tests/MarkdownKitTests/SharedCoordinatorTests.swift`，在 `@Suite("Shared coordinator singletons") struct SharedCoordinatorTests { ... }` 内追加：

```swift
    @Test func twoCoordinatorCallsHitSharedCacheOnSecondView() async {
        // Mock renderer 计数渲染调用次数
        actor CallCounter { var count = 0; func inc() { count += 1 }; func get() -> Int { count } }
        let counter = CallCounter()

        final class CountingSVGRenderer: SVGBlockRendering {
            let counter: CallCounter
            #if canImport(UIKit)
            let stub: PlatformImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
            #elseif canImport(AppKit)
            let stub: PlatformImage = NSImage(size: CGSize(width: 1, height: 1))
            #endif
            init(counter: CallCounter) { self.counter = counter }
            func render(svg: String, availableWidth: CGFloat, scale: CGFloat) async -> SVGBlockOutcome {
                await counter.inc()
                return .rendered(SVGBlockGlyph(image: self.stub))
            }
        }

        let renderer = CountingSVGRenderer(counter: counter)
        // 取一个独立 coordinator 实例做隔离测试，避免污染全局 shared 状态
        let coord = SVGBlockLoadCoordinator()
        await coord.setRenderer(renderer)

        let key = SVGBlockCacheKey(svg: "<svg/>", availableWidth: 100, rasterScale: 2, rendererGeneration: 0)
        // "view 1" 第一次请求 → dispatch
        let dispatched1 = await coord.loadIfNeeded(key: key, svg: "<svg/>", availableWidth: 100, scale: 2)
        #expect(dispatched1)
        await coord.drain()
        #expect(await coord.glyph(for: key) != nil)
        #expect(await counter.get() == 1)

        // "view 2" 同 key 请求 → 应命中 cache，不再 dispatch
        let dispatched2 = await coord.loadIfNeeded(key: key, svg: "<svg/>", availableWidth: 100, scale: 2)
        #expect(dispatched2 == false)
        #expect(await counter.get() == 1, "shared cache 命中后 renderer 不应被再次调用")
    }
```

> 注：测试构造独立 coordinator（不是 `.shared`），避免污染全局；逻辑等价——shared 与 init() 行为相同，本测试只是证 cache 在同一 coordinator 内对多次 loadIfNeeded 调用幂等，即"跨 view 共享 = 跨调用幂等"。

- [ ] **Step 2: 跑测试确认通过**

Run: `swift test --filter SharedCoordinatorTests 2>&1 | tail -15`
Expected: PASS（4 + 1 = 5 case）。

- [ ] **Step 3: 提交**

```bash
git add Tests/MarkdownKitTests/SharedCoordinatorTests.swift
git commit -m "test(coord): 跨调用 cache 共享幂等验证（同 key 二次 loadIfNeeded 不再触发 renderer）"
```

---

## Task 6: 全量回归 + 文档对账 + 推送

- [ ] **Step 1: 全量测试**

Run: `cd /Users/evan/Repositories/MarkdownKit && swift test 2>&1 | grep -iE "Test Suite|errors?:|Failure" | tail -20`
Expected: 全 suite 绿。

- [ ] **Step 2: 严格 build（warnings-as-errors）**

Run: `swift build -Xswiftc -warnings-as-errors 2>&1 | tail -8`
Expected: BUILD SUCCEEDED，0 warning。

- [ ] **Step 3: Example app 仍能 build**

Run: `swift build --target Example 2>&1 | tail -5` 或在 Example 目录跑 build。
Expected: 无新错误。Example 行为可能受 shared coordinator 影响（多 view 注入不同 @State renderer → cache 互清，记录于 spec §7），但 build 应过。

- [ ] **Step 4: 推送分支**

```bash
git push -u origin feature/cross-view-cache-and-static-mode
```

- [ ] **Step 5: 在 GitHub 开 PR**

```bash
gh pr create --base main --head feature/cross-view-cache-and-static-mode \
  --title "跨 view cache + static/streaming 占位区分（SVG + Math）" \
  --body "$(cat <<'EOF'
## Summary

下游 oh-my-exam (PR #7) 因 MarkdownText 的异步 SVG / math 渲染未命中分支显示高亮源码而产生闪烁；app 端已用 .opacity fade-in 兜了一手（PR #7 \`bdca384\`），本 PR 让 MarkdownKit 原生支持掉这层补丁。

- **A**：\`SVGBlockLoadCoordinator.shared\` / \`MathLoadCoordinator.shared\` 单例化，\`MarkdownLabelView\` 默认引用（向后兼容：\`init()\` 仍 public，tests 可拿独立实例）。Cache LRU/dedup/in-flight/代际逻辑全部继承——同 process 全部 markdown 视图共享 cache，复访同步出图。
- **B**：新 \`PlaceholderMode\` enum；\`AttributedStringRenderer.init(...)\` 多收 \`placeholderMode\` 参数（默认 \`.streaming\` 向后兼容）；\`renderSVGBlock\` / \`renderMathBlock\` 的 cache-miss 分支按 mode 分两条——streaming 保留高亮源码、static 改透明 attachment + marker。
- **C**：新 \`SVGViewBoxParser\` 解析 SVG 首 4KB 内的 viewBox 取高宽比；static-miss 占位 attachment 按真实 aspect 预留高度，glyph 到达时 layout shift 最小。Math 按 displayMode + pointSize 估算高度。
- **MarkdownLabelView**：\`renderMode\` 字段由 \`setMarkdown\` / \`appendMarkdown\` 翻转；6 个 \`AttributedStringRenderer\` 实例化点透传。

详见 spec：\`docs/superpowers/specs/2026-05-31-cross-view-cache-and-static-mode-design.md\`。

## Test Plan

- [x] \`swift test\` 全 suite 绿（新 4 个测试 suite + 现有回归）
- [x] \`swift build -Xswiftc -warnings-as-errors\` 零警告
- [x] Example app build 不破

## 下游 follow-up（不在本 PR 内）

oh-my-exam 端在 MK bump 之后单独 PR：删除 \`QuestionMarkdownView\` 的 fade-in 补丁（hasAsyncContent + opacity + task(id:markdown)）。
EOF
)" 2>&1 | tail -3
```

---

## Self-Review（写计划后对照 spec）

**Spec 覆盖：**

- ✅ §1 目标 A 内部 shared coordinator → Task 2
- ✅ §1 目标 B mode 区分 → Task 3（renderer）+ Task 4（label view）
- ✅ §1 目标 C viewBox 预热 → Task 1（parser）+ Task 3 用到
- ✅ §2.1 shared 单例代码片段 → Task 2 Step 3
- ✅ §2.2 PlaceholderMode 枚举 → Task 3 Step 3
- ✅ §2.2 `setMarkdown`/`appendMarkdown` 翻转 → Task 4 Step 4
- ✅ §2.3 SVGViewBoxParser → Task 1
- ✅ §2.3 TransparentAttachment 工厂 → Task 3 Step 4.2
- ✅ §3 数据流（mode snapshot at render time）→ Task 4 实现保证（renderer 实例化时一次取 mode，后续不重渲染）
- ✅ §4 边界 viewBox 找不到回退 0.6 → Task 3 Step 4.3
- ✅ §4 边界 4KB 上限 → Task 1 Step 3
- ✅ §4 边界 renderer == nil / failed → 既有路径不动（Task 2/3 都未触碰）
- ✅ §5 测试覆盖 → Task 1 (parser) / Task 3 (renderer mode) / Task 4 (view mode) / Task 5 (shared cache)
- ✅ §6 下游整合 → Task 6 PR body 写明 follow-up

**Placeholder 扫描**：无 TBD/TODO；每段代码完整可粘贴。一处「math 函数体的 streaming-miss 保持原状」要求实施者 read 现有代码——这是有意保留，因为 streaming 分支零改动、不应 reformat。

**类型一致性**：
- `PlaceholderMode` 定义 (Task 3) 与使用 (Task 3 renderer / Task 4 view / Tests 引用) 命名一致
- `SVGViewBoxParser.parseAspect(from:) -> CGFloat?` (Task 1) 与使用 (Task 3 Step 4.3) 签名一致
- `SVGBlockLoadCoordinator.shared` / `MathLoadCoordinator.shared` (Task 2) 与 view 字段 (Task 2 Step 5) 一致
- `renderMode` 字段 (Task 4 Step 3) 与 setMarkdown/appendMarkdown 翻转 (Step 4) + renderer 实例化点 (Step 5) 一致
- `AttributedStringRenderer.init(... placeholderMode:)` (Task 3 Step 4.1) 与 6 个调用点 (Task 4 Step 5) 一致

**实施者要 read 一下再写的两处**（不是 plan placeholder，是范围内的真实"看上下文"动作）：

1. Task 3 Step 4.4 里 `renderMathBlock` 的真实签名和函数体——plan 给出新 case .static 分支的代码骨架，但 streaming 分支保留原样需先读。
2. Task 4 Step 3 / Step 4 里 `MarkdownLabelView` 的 class 状态字段聚集区位置——文件 2700+ 行，plan 给出 line 范围近似值，实施者按 grep 定位。

---
