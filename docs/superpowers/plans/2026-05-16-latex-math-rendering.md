# LaTeX 数学公式渲染 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 MarkdownKit 渲染 `$…$` / `$$…$$` / `\(…\)` / `\[…\]` 四种 LaTeX 数学公式（只读视图渲染、编辑器仅 token 高亮），渲染后端用 MathJaxSwift+SwiftDraw 收敛在独立可选产品 `MarkdownMath`。

**Architecture:** `MarkdownCore` 在喂 swift-markdown 前做源码层数学预扫描（哨兵替换 + 防伪造转义），解析后就地、保留容器结构地回填 `InlineNode.math` / `BlockNode.mathBlock`。`MarkdownRenderKit` 定义 `MathRendering` 注入协议与缓存（零依赖、平台无关），未命中走占位文本 + 自定义属性。`MarkdownPlatformView` 用平台无关的 `MathLoadCoordinator` 异步驱动渲染、负缓存、失效。`MarkdownMath` 实现协议（MathJax→SVG→SwiftDraw 光栅化）。

**Tech Stack:** Swift 6.2 / SwiftPM、swift-markdown、Swift Testing、MathJaxSwift（colinc86）、SwiftDraw（swhitty）。规范见 `docs/superpowers/specs/2026-05-16-latex-math-rendering-design.md`。

**测试约定：** 宿主为 macOS，`swift test` 编译 `#elseif canImport(AppKit)` 分支；纯逻辑（scanner / 编解码 / coordinator / renderer）全部放进可在 macOS 上跑的单元测试。命令统一 `swift test --filter <SuiteName>`，编译校验用 `swift build`。每个 Task 末尾 commit。

---

## File Structure

**新建**
- `Sources/MarkdownCore/MathScanner.swift` — 源码层定界符扫描（四定界符、转义、代码区跳过、配对、行/块分类），编辑器高亮复用
- `Sources/MarkdownCore/MathSentinel.swift` — 哨兵编解码：保留标量、预存在转义、替换、还原
- `Sources/MarkdownRenderKit/MathRendering.swift` — `MathRenderOutcome` / `MathRenderedGlyph` / `MathCacheKey` / `MathRendering` 协议 / 有效字号工具 / `.markdownMathSource`
- `Sources/MarkdownPlatformView/MathLoadCoordinator.swift` — 平台无关的异步加载/缓存/负缓存/失效协调器
- `Sources/MarkdownKit/MathRendererModifier.swift` — SwiftUI `.mathRenderer(_:)`
- `Sources/MarkdownMath/SVGRasterizer.swift` — SVG 字符串 → `PlatformImage` + 基线（颜色注入、ex/viewBox/vertical-align 解析、SwiftDraw）
- `Sources/MarkdownMath/MathJaxRenderer.swift` — `MathJaxRenderer: MathRendering`
- `Tests/MarkdownKitTests/MathScannerTests.swift`
- `Tests/MarkdownKitTests/MathSentinelTests.swift`
- `Tests/MarkdownKitTests/MathParsingTests.swift`
- `Tests/MarkdownKitTests/MathRenderingTests.swift`
- `Tests/MarkdownKitTests/MathLoadCoordinatorTests.swift`
- `Tests/MarkdownKitTests/MathEditorHighlightTests.swift`
- `Tests/MarkdownMathTests/SVGRasterizerTests.swift`
- `Tests/MarkdownMathTests/MathJaxRendererTests.swift`

**修改**
- `Package.swift` — MathJaxSwift / SwiftDraw 依赖、`MarkdownMath` target+library、`MarkdownMathTests` target
- `Sources/MarkdownCore/InlineNode.swift` — `case math(latex:)`
- `Sources/MarkdownCore/BlockNode.swift` — `case mathBlock(latex:)`
- `Sources/MarkdownCore/DocumentParser.swift` — 预扫描+替换+就地回填集成、`parsingAppend` 数学感知边界
- `Sources/MarkdownRenderKit/AttributedStringRenderer.swift` — `mathCache`、渲染 `.math`/`.mathBlock`
- `Sources/MarkdownRenderKit/RenderStyle.swift` — `mathTokenColor` / `mathScale` / `mathColorOverride`
- `Sources/MarkdownRenderKit/MarkdownSourceHighlighter.swift` — 数学 token 高亮
- `Sources/MarkdownPlatformView/MarkdownLabelView.swift` — 接入 `MathLoadCoordinator`（iOS + AppKit 两路）

---

## Task 1: 依赖落地 + SwiftDraw×MathJax 还原度 spike（go/no-go 门）

**Files:**
- Modify: `Package.swift`
- Create: `Sources/MarkdownMath/MarkdownMath.swift`
- Test: `Tests/MarkdownMathTests/SVGRasterizerTests.swift`（本任务仅放 spike 用例）

- [ ] **Step 1: 加依赖与新 target/library（先用 branch 去险，后续 Task 14 Step 5 再 pin）**

`Package.swift` 的 `dependencies` 数组追加：

```swift
.package(url: "https://github.com/colinc86/MathJaxSwift.git", branch: "main"),
.package(url: "https://github.com/swhitty/SwiftDraw.git", branch: "main"),
```

`targets` 数组追加（放在 `MarkdownKit` target 之后、`testTarget` 之前）：

```swift
.target(
    name: "MarkdownMath",
    dependencies: [
        "MarkdownRenderKit",
        .product(name: "MathJaxSwift", package: "MathJaxSwift"),
        .product(name: "SwiftDraw", package: "SwiftDraw"),
    ]
),
.testTarget(
    name: "MarkdownMathTests",
    dependencies: ["MarkdownMath", "MarkdownCore", "MarkdownRenderKit"]
),
```

`products` 数组追加：

```swift
.library(name: "MarkdownMath", targets: ["MarkdownMath"]),
```

- [ ] **Step 2: 占位源文件让 target 可编译**

Create `Sources/MarkdownMath/MarkdownMath.swift`:

```swift
// MarkdownMath: MathJax + SwiftDraw 实现 MarkdownRenderKit 的 MathRendering 协议。
// 具体类型见 SVGRasterizer.swift / MathJaxRenderer.swift。
import Foundation
```

- [ ] **Step 3: 解析依赖**

Run: `swift package resolve`
Expected: 退出码 0，`Package.resolved` 出现 `MathJaxSwift` 与 `SwiftDraw` 两条；若失败则停止并向人汇报（依赖不可用 = 整方案前置不成立）。

- [ ] **Step 4: 写 spike 失败测试（验证 tex2svg → SwiftDraw 可产出非退化位图）**

Create `Tests/MarkdownMathTests/SVGRasterizerTests.swift`:

```swift
import Testing
import Foundation
import MathJaxSwift
import SwiftDraw

@Suite("SwiftDraw × MathJax spike")
struct SVGRasterizerSpikeTests {
    @Test("tex2svg 产出可被 SwiftDraw 光栅化为非空位图")
    func mathjaxSVGRasterizes() async throws {
        let mathjax = try MathJax(preferredOutputFormat: .svg)
        let svg = try await mathjax.tex2svg("x^2 + \\frac{a}{b}")
        #expect(svg.contains("<svg"))

        let data = try #require(svg.data(using: .utf8))
        let drawing = try #require(SwiftDraw.SVG(data: data))
        let image = drawing.rasterize(scale: 2.0)
        #expect(image.size.width > 1)
        #expect(image.size.height > 1)
    }
}
```

- [ ] **Step 5: 运行 spike（这是 go/no-go 门）**

Run: `swift test --filter "SwiftDraw × MathJax spike"`
Expected: PASS。
失败处理：若 `SwiftDraw.SVG(data:)` 解析失败或 `rasterize` 产出退化（尺寸 ≤1），**停止并向人汇报**，按 spec §11.1 走回退（手解析 MathJax SVG 几何 / 换光栅化器）。注意 SwiftDraw 的具体 API 名（`SVG`、`rasterize(scale:)`）以解析后的实际头文件为准；若签名不同，按其真实 API 调整本步骤后重跑，仍以「非退化位图」为通过标准。

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved Sources/MarkdownMath/MarkdownMath.swift Tests/MarkdownMathTests/SVGRasterizerTests.swift
git commit -m "feat(math): 加 MathJaxSwift+SwiftDraw 依赖与 MarkdownMath 产品，spike 通过"
```

---

## Task 2: IR 新增 math 节点

**Files:**
- Modify: `Sources/MarkdownCore/InlineNode.swift`
- Modify: `Sources/MarkdownCore/BlockNode.swift`
- Test: `Tests/MarkdownKitTests/MathParsingTests.swift`

- [ ] **Step 1: 写失败测试**

Create `Tests/MarkdownKitTests/MathParsingTests.swift`:

```swift
import MarkdownCore
import Testing

@Suite("Math IR")
struct MathIRTests {
    @Test("math / mathBlock 节点可构造且 Equatable")
    func mathNodesEquatable() {
        #expect(InlineNode.math(latex: "x^2") == InlineNode.math(latex: "x^2"))
        #expect(InlineNode.math(latex: "x^2") != InlineNode.math(latex: "y"))
        #expect(BlockNode.mathBlock(latex: "\\int") == BlockNode.mathBlock(latex: "\\int"))
        #expect(BlockNode.mathBlock(latex: "\\int") != BlockNode.mathBlock(latex: "\\sum"))
    }
}
```

- [ ] **Step 2: 运行验证失败**

Run: `swift test --filter "Math IR"`
Expected: 编译失败，`type 'InlineNode' has no member 'math'`。

- [ ] **Step 3: 加 IR case**

`Sources/MarkdownCore/InlineNode.swift`，在 `case html(String)` 之前插入：

```swift
    /// An inline LaTeX math span (`$…$` / `\(…\)`), delimiters stripped.
    case math(latex: String)
```

`Sources/MarkdownCore/BlockNode.swift`，在 `case table(...)` 之前插入：

```swift
    /// A display-level LaTeX math block (`$$…$$` / `\[…\]`), delimiters stripped.
    case mathBlock(latex: String)
```

- [ ] **Step 4: 运行验证通过**

Run: `swift test --filter "Math IR"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownCore/InlineNode.swift Sources/MarkdownCore/BlockNode.swift Tests/MarkdownKitTests/MathParsingTests.swift
git commit -m "feat(core): 新增 InlineNode.math / BlockNode.mathBlock IR 节点"
```

---

## Task 3: MathScanner — 源码层定界符扫描

扫描原始源码，返回有序的数学区段（不修改字符串）。规则见 spec §4.2 步骤 1 与 §4.4。

**Files:**
- Create: `Sources/MarkdownCore/MathScanner.swift`
- Test: `Tests/MarkdownKitTests/MathScannerTests.swift`

- [ ] **Step 1: 写失败测试**

Create `Tests/MarkdownKitTests/MathScannerTests.swift`:

```swift
@testable import MarkdownCore
import Testing

@Suite("MathScanner")
struct MathScannerTests {
    private func spans(_ s: String) -> [MathSpan] { MathScanner.scan(s) }

    @Test("行内 $…$")
    func inlineDollar() {
        let r = spans("a $x^2$ b")
        #expect(r.count == 1)
        #expect(r[0].latex == "x^2")
        #expect(r[0].display == false)
        #expect(r[0].range == 2 ..< 7)   // UTF-8 字节区间，含定界符
    }

    @Test("块级 $$…$$")
    func blockDollar() {
        let r = spans("$$\\int_0^1 x\\,dx$$")
        #expect(r.count == 1)
        #expect(r[0].latex == "\\int_0^1 x\\,dx")
        #expect(r[0].display == true)
    }

    @Test("\\(…\\) 行内 与 \\[…\\] 块级")
    func backslashDelims() {
        let r = spans("p \\(a+b\\) q \\[c=d\\] r")
        #expect(r.count == 2)
        #expect(r[0].latex == "a+b")
        #expect(r[0].display == false)
        #expect(r[1].latex == "c=d")
        #expect(r[1].display == true)
    }

    @Test("\\$ 转义不作定界符")
    func escapedDollar() {
        #expect(spans("cost is \\$5 and \\$6").isEmpty)
    }

    @Test("行内代码 / 围栏代码内不识别")
    func skipsCode() {
        #expect(spans("`$x$` not math").isEmpty)
        #expect(spans("```\n$x$\n```").isEmpty)
        #expect(spans("    $x$ indented code").isEmpty)
    }

    @Test("未配对定界符 → 不产出（当字面）")
    func unmatched() {
        #expect(spans("price $5 only").isEmpty)
        #expect(spans("open $$ but never close").isEmpty)
    }

    @Test("$$ 优先于 $（贪婪匹配块级）")
    func blockBeatsInline() {
        let r = spans("$$a$$")
        #expect(r.count == 1)
        #expect(r[0].display == true)
        #expect(r[0].latex == "a")
    }

    @Test("多个 span 按出现顺序")
    func ordering() {
        let r = spans("$a$ text $$b$$ text \\(c\\)")
        #expect(r.map(\.latex) == ["a", "b", "c"])
        #expect(r.map(\.display) == [false, true, false])
    }
}
```

- [ ] **Step 2: 运行验证失败**

Run: `swift test --filter "MathScanner"`
Expected: 编译失败，`cannot find 'MathScanner' in scope`。

- [ ] **Step 3: 实现 MathScanner**

Create `Sources/MarkdownCore/MathScanner.swift`:

```swift
import Foundation

/// 源码中一段数学区段（基于 UTF-8 字节偏移）。
public struct MathSpan: Sendable, Equatable {
    /// 含定界符的 UTF-8 字节区间。
    public let range: Range<Int>
    /// 去掉定界符后的公式串。
    public let latex: String
    /// true = 块级（`$$` / `\[\]`），false = 行内（`$` / `\(\)`）。
    public let display: Bool
}

/// 在原始 Markdown 源码上扫描数学区段。纯函数，不修改输入。
/// 跳过围栏代码块 / 缩进代码块 / 行内代码；`\$` 转义不作定界符；未配对当字面。
public enum MathScanner {
    public static func scan(_ source: String) -> [MathSpan] {
        let bytes = Array(source.utf8)
        let codeMask = codeRegionMask(source: source, byteCount: bytes.count)
        var spans: [MathSpan] = []
        var i = 0

        func isEscaped(_ idx: Int) -> Bool {
            var backslashes = 0
            var k = idx - 1
            while k >= 0, bytes[k] == 0x5C { backslashes += 1; k -= 1 }
            return backslashes % 2 == 1
        }

        func makeSpan(open: Int, openLen: Int, close: Int, closeLen: Int, display: Bool) -> MathSpan {
            let latexStart = open + openLen
            let latexBytes = Array(bytes[latexStart ..< close])
            let latex = String(decoding: latexBytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return MathSpan(range: open ..< (close + closeLen), latex: latex, display: display)
        }

        // 在 [from, end) 内找未被 code 覆盖、未转义的字面定界符序列。
        func findClose(_ marker: [UInt8], from: Int) -> Int? {
            var k = from
            while k + marker.count <= bytes.count {
                if !codeMask[k], !isEscaped(k), Array(bytes[k ..< k + marker.count]) == marker {
                    return k
                }
                k += 1
            }
            return nil
        }

        while i < bytes.count {
            if codeMask[i] || isEscaped(i) { i += 1; continue }
            let b = bytes[i]

            // $$ … $$（块级，贪婪优先于 $）
            if b == 0x24, i + 1 < bytes.count, bytes[i + 1] == 0x24 {
                if let close = findClose([0x24, 0x24], from: i + 2) {
                    spans.append(makeSpan(open: i, openLen: 2, close: close, closeLen: 2, display: true))
                    i = close + 2; continue
                }
                i += 1; continue
            }
            // $ … $（行内，闭合符不能是 $$ 的一部分；公式非空）
            if b == 0x24 {
                if let close = findClose([0x24], from: i + 1), close > i + 1 {
                    spans.append(makeSpan(open: i, openLen: 1, close: close, closeLen: 1, display: false))
                    i = close + 1; continue
                }
                i += 1; continue
            }
            // \[ … \] （块级）
            if b == 0x5C, i + 1 < bytes.count, bytes[i + 1] == 0x5B {
                if let close = findCloseBackslash(close: 0x5D, bytes: bytes, codeMask: codeMask, from: i + 2) {
                    spans.append(makeSpan(open: i, openLen: 2, close: close, closeLen: 2, display: true))
                    i = close + 2; continue
                }
                i += 2; continue
            }
            // \( … \) （行内）
            if b == 0x5C, i + 1 < bytes.count, bytes[i + 1] == 0x28 {
                if let close = findCloseBackslash(close: 0x29, bytes: bytes, codeMask: codeMask, from: i + 2) {
                    spans.append(makeSpan(open: i, openLen: 2, close: close, closeLen: 2, display: false))
                    i = close + 2; continue
                }
                i += 2; continue
            }
            i += 1
        }
        return spans
    }

    /// 找 `\)` 或 `\]`：闭合是「反斜杠 + 指定字节」，反斜杠本身不能被转义。
    private static func findCloseBackslash(
        close: UInt8, bytes: [UInt8], codeMask: [Bool], from: Int
    ) -> Int? {
        var k = from
        while k + 1 < bytes.count {
            if !codeMask[k], bytes[k] == 0x5C, bytes[k + 1] == close {
                var backslashes = 0, p = k - 1
                while p >= 0, bytes[p] == 0x5C { backslashes += 1; p -= 1 }
                if backslashes % 2 == 0 { return k }
            }
            k += 1
        }
        return nil
    }

    /// 标出落在围栏代码块 / 缩进代码块 / 行内代码内的字节（true = 在代码内，数学定界符忽略）。
    private static func codeRegionMask(source: String, byteCount: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: byteCount)
        let ns = source as NSString
        var loc = 0
        // 围栏代码块（``` 或 ~~~，缩进 ≤3）。
        while loc < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let indent = line.prefix(while: { $0 == " " }).count
            let content = indent <= 3 ? String(line.dropFirst(indent)) : line
            if let f = content.first, f == "`" || f == "~", content.prefix(while: { $0 == f }).count >= 3 {
                let fenceCount = content.prefix(while: { $0 == f }).count
                let start = utf8Offset(ns, lineRange.location)
                var cursor = lineRange.upperBound
                var end = byteCount
                while cursor < ns.length {
                    let r = ns.lineRange(for: NSRange(location: cursor, length: 0))
                    let l = ns.substring(with: r).trimmingCharacters(in: .newlines)
                    let li = l.prefix(while: { $0 == " " }).count
                    let lc = li <= 3 ? String(l.dropFirst(li)) : l
                    if lc.allSatisfy({ $0 == f || $0 == " " }), lc.prefix(while: { $0 == f }).count >= fenceCount {
                        end = utf8Offset(ns, r.upperBound)
                        cursor = r.upperBound
                        break
                    }
                    cursor = r.upperBound
                    end = utf8Offset(ns, r.upperBound)
                }
                for x in start ..< min(end, byteCount) { mask[x] = true }
                loc = cursor
                continue
            }
            loc = lineRange.upperBound
        }
        // 缩进代码块（行首 ≥4 空格且非列表续行；保守：整行 4 空格起）。
        loc = 0
        while loc < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let raw = ns.substring(with: lineRange)
            let body = raw.trimmingCharacters(in: .newlines)
            if body.hasPrefix("    "), !body.trimmingCharacters(in: .whitespaces).isEmpty {
                let s = utf8Offset(ns, lineRange.location)
                let e = utf8Offset(ns, lineRange.upperBound)
                for x in s ..< min(e, byteCount) { mask[x] = true }
            }
            loc = lineRange.upperBound
        }
        // 行内代码 `…`（同一行内成对反引号，反引号串长度匹配）。
        let codeSpan = try! NSRegularExpression(pattern: "(`+)(?:(?!\\1).)*\\1")
        codeSpan.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let s = utf8Offset(ns, m.range.location)
            let e = utf8Offset(ns, m.range.location + m.range.length)
            for x in s ..< min(e, byteCount) { mask[x] = true }
        }
        return mask
    }

    private static func utf8Offset(_ ns: NSString, _ utf16Loc: Int) -> Int {
        let prefix = ns.substring(to: min(utf16Loc, ns.length))
        return prefix.utf8.count
    }
}
```

- [ ] **Step 4: 运行验证通过**

Run: `swift test --filter "MathScanner"`
Expected: PASS（8 个用例全绿）。若某用例红，按 spec §4.2 规则修实现，单测逐个跑绿，不改测试期望。

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownCore/MathScanner.swift Tests/MarkdownKitTests/MathScannerTests.swift
git commit -m "feat(core): MathScanner 源码层四定界符扫描（转义/代码区/配对/分类）"
```

---

## Task 4: MathSentinel — 防伪造哨兵编解码

保留标量 `U+10FE00`；替换前转义源码中已存在的该标量，IR 构建后还原。spec §4.2 步骤 2。

**Files:**
- Create: `Sources/MarkdownCore/MathSentinel.swift`
- Test: `Tests/MarkdownKitTests/MathSentinelTests.swift`

- [ ] **Step 1: 写失败测试**

Create `Tests/MarkdownKitTests/MathSentinelTests.swift`:

```swift
@testable import MarkdownCore
import Testing

@Suite("MathSentinel")
struct MathSentinelTests {
    @Test("替换后用哨兵锚替掉公式区段，旁路表可还原")
    func substituteAndLookup() {
        let src = "a $x^2$ b $$y$$ c"
        let spans = MathScanner.scan(src)
        let result = MathSentinel.substitute(source: src, spans: spans)
        #expect(!result.transformed.contains("$"))
        #expect(result.table.count == 2)
        #expect(result.table[0].latex == "x^2")
        #expect(result.table[0].display == false)
        #expect(result.table[1].latex == "y")
        #expect(result.table[1].display == true)
        // 每个锚都能在 transformed 里被 anchorRanges 唯一定位。
        let anchors = MathSentinel.anchorRanges(in: result.transformed)
        #expect(anchors.map(\.index) == [0, 1])
    }

    @Test("源码本身含保留标量时被转义、还原后字节级不变")
    func spoofingEscaped() {
        let evil = "text \u{10FE00}0\u{10FE00} pretending to be an anchor $z$ end"
        let spans = MathScanner.scan(evil)
        let result = MathSentinel.substitute(source: evil, spans: spans)
        // 只有真实公式 z 进旁路表；伪造串不被认成锚。
        #expect(result.table.count == 1)
        #expect(result.table[0].latex == "z")
        let anchors = MathSentinel.anchorRanges(in: result.transformed)
        #expect(anchors.count == 1)
        // 还原：把锚位置之外的转义标量恢复，文本与原始（去掉真公式部分外）一致。
        let restored = MathSentinel.unescapeReservedScalar(result.transformed)
        #expect(restored.contains("\u{10FE00}0\u{10FE00} pretending"))
    }

    @Test("形似 哨兵+数字+哨兵 但无对应旁路表项 → 不算锚")
    func lookalikeNotAnchor() {
        let s = "\u{10FE00}99\u{10FE00}"
        let escaped = MathSentinel.escapeReservedScalar(s)
        #expect(MathSentinel.anchorRanges(in: escaped).isEmpty)
    }
}
```

- [ ] **Step 2: 运行验证失败**

Run: `swift test --filter "MathSentinel"`
Expected: 编译失败，`cannot find 'MathSentinel' in scope`。

- [ ] **Step 3: 实现 MathSentinel**

Create `Sources/MarkdownCore/MathSentinel.swift`:

```swift
import Foundation

/// 数学哨兵编解码。锚形如 `S<index>S`，其中 S = 保留标量 U+10FE00。
/// 替换前先把源码里已存在的 S 转义为 `S` + ESC(U+10FE01)，使「能存活的裸 S 锚」
/// 一定由本类注入，用户文本无法伪造或碰撞（spec §4.2、§11.7）。
public enum MathSentinel {
    public static let sentinel: Character = "\u{10FE00}"
    private static let escapeMark: Character = "\u{10FE01}"

    public struct Entry: Sendable, Equatable {
        public let latex: String
        public let display: Bool
    }

    public struct SubstituteResult: Sendable {
        public let transformed: String
        public let table: [Entry]
    }

    public struct Anchor: Sendable, Equatable {
        public let index: Int
        public let range: Range<String.Index>
    }

    /// 把源码中已存在的 sentinel 转义：S → S ESC（ESC 自身不会单独出现）。
    public static func escapeReservedScalar(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if ch == sentinel { out.append(sentinel); out.append(escapeMark) }
            else { out.append(ch) }
        }
        return out
    }

    /// 还原 escapeReservedScalar：S ESC → S。
    public static func unescapeReservedScalar(_ s: String) -> String {
        var out = ""
        var iter = s.makeIterator()
        var pending: Character?
        while let ch = pending ?? iter.next() {
            pending = nil
            if ch == sentinel {
                if let next = iter.next() {
                    if next == escapeMark { out.append(sentinel) }
                    else { out.append(sentinel); pending = next }
                } else { out.append(sentinel) }
            } else { out.append(ch) }
        }
        return out
    }

    /// 用 UTF-8 字节区间（来自 MathScanner）把公式替换成裸锚。
    public static func substitute(source: String, spans: [MathSpan]) -> SubstituteResult {
        let bytes = Array(source.utf8)
        var pieces: [String] = []
        var table: [Entry] = []
        var cursor = 0
        for span in spans {
            let pre = String(decoding: bytes[cursor ..< span.range.lowerBound], as: UTF8.self)
            pieces.append(escapeReservedScalar(pre))
            let idx = table.count
            table.append(Entry(latex: span.latex, display: span.display))
            pieces.append("\(sentinel)\(idx)\(sentinel)")
            cursor = span.range.upperBound
        }
        let tail = String(decoding: bytes[cursor ..< bytes.count], as: UTF8.self)
        pieces.append(escapeReservedScalar(tail))
        return SubstituteResult(transformed: pieces.joined(), table: table)
    }

    /// 在字符串里定位裸锚（S<digits>S，紧跟其后不是 escapeMark）。
    public static func anchorRanges(in s: String) -> [Anchor] {
        var anchors: [Anchor] = []
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == sentinel {
                let afterOpen = s.index(after: i)
                // 转义对 S ESC：跳过，不是锚。
                if afterOpen < s.endIndex, s[afterOpen] == escapeMark {
                    i = s.index(after: afterOpen); continue
                }
                var j = afterOpen
                var digits = ""
                while j < s.endIndex, s[j].isNumber { digits.append(s[j]); j = s.index(after: j) }
                if !digits.isEmpty, j < s.endIndex, s[j] == sentinel, let idx = Int(digits) {
                    anchors.append(Anchor(index: idx, range: i ... j == i ... j ? i ..< s.index(after: j) : i ..< s.index(after: j)))
                    i = s.index(after: j); continue
                }
            }
            i = s.index(after: i)
        }
        return anchors
    }
}
```

> 实现提示：`anchorRanges` 的 `range` 用 `i ..< s.index(after: j)`（含首尾 sentinel）。`anchorRanges(in:)` 在「形似但无旁路表项」时仍可能返回 Anchor（它只看格式）；是否真锚由回填阶段用 `table` 的 index 边界校验（Task 5）——本任务 `lookalikeNotAnchor` 用例验证的是被转义后的串里不出现裸锚。

- [ ] **Step 4: 运行验证通过**

Run: `swift test --filter "MathSentinel"`
Expected: PASS。若 `lookalikeNotAnchor` 红，确认 `escapeReservedScalar` 已把裸 S 拆成 `S ESC` 故 `anchorRanges` 不应识别为锚。

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownCore/MathSentinel.swift Tests/MarkdownKitTests/MathSentinelTests.swift
git commit -m "feat(core): MathSentinel 防伪造哨兵编解码（保留标量+转义+旁路表）"
```

---

## Task 5: DocumentParser 集成 — 预扫描 + 就地容器保留回填

spec §4.2 步骤 3-4。

> ⚠️ **Task 3 遗留已知限制（评审记录，本任务处理）：** `MathScanner` 的 `isList` 把空格分隔的主题分隔线 `* * *`（及 `* *`、`*  *  *`）误判为列表标记，导致紧跟其后的「缩进代码块」不被 mask——其中若含 `$…$` 会被当公式抽取、经哨兵替换后 **mangle 代码块内容**。本任务必须：(a) 加一条测试：`"text\n\n* * *\n\n    code with $x$ inside\n"` 解析后该缩进代码块原文（含 `$x$`）保持不变、不产生 `.math`/`.mathBlock`；(b) 若该测试红，在 `MathScanner` 的 `isList`（或其调用处）做窄修复：把整行去空白后仅由 `*`/`-`/`_` + 空白组成且字符数 ≥3 的行识别为 thematic break、不开 list context（不要扩成完整块解析）。修复连同测试并入本任务提交。

**Files:**
- Modify: `Sources/MarkdownCore/DocumentParser.swift`
- Modify: `Sources/MarkdownCore/MathScanner.swift`（仅当上述 (b) 需要时）
- Test: `Tests/MarkdownKitTests/MathParsingTests.swift`（追加）

- [ ] **Step 1: 追加失败测试**

在 `Tests/MarkdownKitTests/MathParsingTests.swift` 末尾追加：

```swift
@Suite("Math parsing integration")
struct MathParsingIntegrationTests {
    @Test("行内/块级公式进 IR 且去定界符")
    func basicParse() {
        let doc = MarkdownDocument(parsing: "Euler: $e^{i\\pi}+1=0$ done\n\n$$\\int_0^1 x\\,dx$$")
        guard case .paragraph(let inlines) = doc.blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(inlines.contains(.math(latex: "e^{i\\pi}+1=0")))
        #expect(doc.blocks[1] == .mathBlock(latex: "\\int_0^1 x\\,dx"))
    }

    @Test("块级公式在列表项内 → 留在该 ListItem，不上提顶层")
    func blockMathInsideList() {
        let doc = MarkdownDocument(parsing: "- before\n- $$x^2$$\n- after")
        guard case .bulletList(let items) = doc.blocks[0] else { Issue.record("expected list"); return }
        #expect(items.count == 3)
        #expect(items[1].blocks == [.mathBlock(latex: "x^2")])
        #expect(doc.blocks.count == 1)   // 没有顶层 mathBlock 被拎出
    }

    @Test("块级公式在块引用内 → 留在 blockquote")
    func blockMathInsideQuote() {
        let doc = MarkdownDocument(parsing: "> quote\n>\n> $$y=x$$")
        guard case .blockquote(let inner) = doc.blocks[0] else { Issue.record("expected blockquote"); return }
        #expect(inner.contains(.mathBlock(latex: "y=x")))
        #expect(doc.blocks.count == 1)
    }

    @Test("表格单元格内块定界符降级为行内 math")
    func blockMathInTableCellDegrades() {
        let doc = MarkdownDocument(parsing: "| a | b |\n|---|---|\n| $$z$$ | c |")
        guard case .table(_, _, let rows) = doc.blocks[0] else { Issue.record("expected table"); return }
        #expect(rows[0][0].content == [.math(latex: "z")])
    }

    @Test("段落中间块级公式就地拆为前/公式/后，留在原父容器")
    func splitParagraphInPlace() {
        let doc = MarkdownDocument(parsing: "pre $$mid$$ post")
        #expect(doc.blocks.count == 3)
        if case .paragraph(let a) = doc.blocks[0] { #expect(a == [.text("pre ")]) } else { Issue.record("b0") }
        #expect(doc.blocks[1] == .mathBlock(latex: "mid"))
        if case .paragraph(let c) = doc.blocks[2] { #expect(c == [.text(" post")]) } else { Issue.record("b2") }
    }

    @Test("源码含保留标量不被误判、文本无损")
    func spoofSafe() {
        let doc = MarkdownDocument(parsing: "raw \u{10FE00}0\u{10FE00} text $w$")
        guard case .paragraph(let inlines) = doc.blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(inlines.contains(.math(latex: "w")))
        let joined = inlines.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        #expect(joined.contains("\u{10FE00}0\u{10FE00}"))
    }
}
```

- [ ] **Step 2: 运行验证失败**

Run: `swift test --filter "Math parsing integration"`
Expected: FAIL（公式仍是纯文本，断言不满足）。

- [ ] **Step 3: 接入预扫描与回填**

`Sources/MarkdownCore/DocumentParser.swift`，改 `MarkdownDocument.init(parsing:)`：

```swift
    public init(parsing source: String) {
        let mathSpans = MathScanner.scan(source)
        let sub = MathSentinel.substitute(source: source, spans: mathSpans)
        let swiftMarkdownDoc = Markdown.Document(parsing: sub.transformed)
        let raw = DocumentParser().parse(source: sub.transformed, document: swiftMarkdownDoc)
        let resolved = MathBackfill.resolve(raw, table: sub.table)
        self.parsedBlocks = resolved
        self.blocks = self.parsedBlocks.map(\.block)
    }
```

在文件末尾（`extension String` 之后）追加 `MathBackfill`：

```swift
// MARK: - MathBackfill

/// 把哨兵锚就地换回 math 节点，严格保留容器结构（spec §4.2、§11.6）。
enum MathBackfill {
    static func resolve(_ blocks: [ParsedBlockNode], table: [MathSentinel.Entry]) -> [ParsedBlockNode] {
        blocks.flatMap { node -> [ParsedBlockNode] in
            resolveBlock(node.block, table: table).map {
                ParsedBlockNode(block: $0, sourceRange: node.sourceRange, fingerprint: node.fingerprint)
            }
        }
    }

    /// 一个 block 可能拆成多个（段落中间的块级公式），但都留在调用者的同一层。
    private static func resolveBlock(_ block: BlockNode, table: [MathSentinel.Entry]) -> [BlockNode] {
        switch block {
        case .paragraph(let inlines):
            return splitParagraph(inlines, table: table)
        case .heading(let level, let content):
            return [.heading(level: level, content: resolveInlines(content, table: table, allowBlock: false))]
        case .blockquote(let inner):
            return [.blockquote(inner.flatMap { resolveBlock($0, table: table) })]
        case .bulletList(let items):
            return [.bulletList(items: items.map { resolveListItem($0, table: table) })]
        case .orderedList(let start, let items):
            return [.orderedList(start: start, items: items.map { resolveListItem($0, table: table) })]
        case .table(let cols, let head, let rows):
            // 单元格只容纳 inline：块级哨兵在此降级为行内 math。
            return [.table(
                columns: cols,
                head: head.map { TableCell(content: resolveInlines($0.content, table: table, allowBlock: false)) },
                rows: rows.map { $0.map { TableCell(content: resolveInlines($0.content, table: table, allowBlock: false)) } }
            )]
        case .codeBlock, .thematicBreak, .htmlBlock:
            return [block]
        case .mathBlock:
            return [block]
        }
    }

    private static func resolveListItem(_ item: ListItem, table: [MathSentinel.Entry]) -> ListItem {
        ListItem(blocks: item.blocks.flatMap { resolveBlock($0, table: table) }, checkbox: item.checkbox)
    }

    /// 段落级：把锚还原为 inline math；块级锚若独占段落 → 单独 mathBlock；
    /// 块级锚夹在文字中 → 就地拆 [前段落, mathBlock, 后段落]，全部留在本层。
    private static func splitParagraph(
        _ inlines: [InlineNode], table: [MathSentinel.Entry]
    ) -> [BlockNode] {
        let expanded = resolveInlines(inlines, table: table, allowBlock: true)
        var result: [BlockNode] = []
        var buffer: [InlineNode] = []
        func flush() {
            if !buffer.isEmpty { result.append(.paragraph(buffer)); buffer = [] }
        }
        for node in expanded {
            if case .blockMathPlaceholder(let latex) = node {
                flush()
                result.append(.mathBlock(latex: latex))
            } else {
                buffer.append(node)
            }
        }
        flush()
        if result.isEmpty { result = [.paragraph(expanded.filter { !$0.isBlockMathPlaceholder })] }
        return result
    }

    /// 在 inline 序列里把锚文本替换为 math 节点。allowBlock=false 时块级锚降级为 inline math。
    private static func resolveInlines(
        _ inlines: [InlineNode], table: [MathSentinel.Entry], allowBlock: Bool
    ) -> [InlineNode] {
        inlines.flatMap { node -> [InlineNode] in
            switch node {
            case .text(let raw):
                return splitText(raw, table: table, allowBlock: allowBlock)
            case .emphasis(let c): return [.emphasis(resolveInlines(c, table: table, allowBlock: allowBlock))]
            case .strong(let c): return [.strong(resolveInlines(c, table: table, allowBlock: allowBlock))]
            case .strikethrough(let c): return [.strikethrough(resolveInlines(c, table: table, allowBlock: allowBlock))]
            case .link(let d, let t, let c):
                return [.link(destination: d, title: t, children: resolveInlines(c, table: table, allowBlock: allowBlock))]
            default:
                return [node]
            }
        }
    }

    private static func splitText(
        _ raw: String, table: [MathSentinel.Entry], allowBlock: Bool
    ) -> [InlineNode] {
        let anchors = MathSentinel.anchorRanges(in: raw).filter { table.indices.contains($0.index) }
        guard !anchors.isEmpty else {
            return [.text(MathSentinel.unescapeReservedScalar(raw))]
        }
        var out: [InlineNode] = []
        var cursor = raw.startIndex
        for anchor in anchors {
            if cursor < anchor.range.lowerBound {
                out.append(.text(MathSentinel.unescapeReservedScalar(String(raw[cursor ..< anchor.range.lowerBound]))))
            }
            let entry = table[anchor.index]
            if entry.display, allowBlock {
                out.append(.blockMathPlaceholder(latex: entry.latex))
            } else {
                out.append(.math(latex: entry.latex))
            }
            cursor = anchor.range.upperBound
        }
        if cursor < raw.endIndex {
            out.append(.text(MathSentinel.unescapeReservedScalar(String(raw[cursor ..< raw.endIndex]))))
        }
        return out
    }
}

// 内部用：标记一个待提升为 BlockNode.mathBlock 的占位 inline（不对外暴露）。
extension InlineNode {
    static func blockMathPlaceholder(latex: String) -> InlineNode { .html("\u{10FE02}\(latex)\u{10FE02}") }
    var isBlockMathPlaceholder: Bool {
        if case .html(let s) = self { return s.hasPrefix("\u{10FE02}") && s.hasSuffix("\u{10FE02}") }
        return false
    }
}

extension InlineNode {
    /// 解构 blockMathPlaceholder。
    static func ~= (pattern: (latex: String) -> Void, value: InlineNode) -> Bool { false }
}
```

> 设计说明：`blockMathPlaceholder` 借 `.html` 载荷在 inline 流里临时携带「这是块级公式」的信号（用 U+10FE02 包裹，不会与真实 HTML 冲突，因为真实内联 HTML 不会以该私有标量开头）。`splitParagraph` 据此就地切块，**不上提**。`splitText` 里 `if case .blockMathPlaceholder(let latex)` 这种模式匹配不可用，改为在 `splitParagraph` 用 `if node.isBlockMathPlaceholder { 取 latex }`。下一步修正该处。

- [ ] **Step 4: 修正块级占位的取值方式**

把上一步 `splitParagraph` 内循环改为不依赖不存在的 case 模式：

```swift
        for node in expanded {
            if node.isBlockMathPlaceholder, case .html(let s) = node {
                flush()
                let latex = String(s.dropFirst().dropLast())  // 去掉首尾 U+10FE02
                result.append(.mathBlock(latex: latex))
            } else {
                buffer.append(node)
            }
        }
```

并删除 `splitParagraph` 里 `if case .blockMathPlaceholder(let latex) = node` 那段旧代码与文件末尾无用的 `static func ~=`。

- [ ] **Step 5: 运行验证通过**

Run: `swift test --filter "Math parsing integration"`
Expected: PASS（6 用例全绿）。

- [ ] **Step 6: 跑全量回归确保旧解析不破**

Run: `swift test --filter "MarkdownCore incremental parsing"`
Expected: PASS（既有指纹/增量测试不回归）。

- [ ] **Step 7: Commit**

```bash
git add Sources/MarkdownCore/DocumentParser.swift Tests/MarkdownKitTests/MathParsingTests.swift
git commit -m "feat(core): 预扫描+就地容器保留回填，块级公式不上提、表格降级行内"
```

---

## Task 6: parsingAppend 数学感知重解析边界

spec §4.3、§11.4。开界符在被保留 prefix、闭界符在追加文本时，结果必须与全量解析一致。

**Files:**
- Modify: `Sources/MarkdownCore/DocumentParser.swift`
- Test: `Tests/MarkdownKitTests/MathParsingTests.swift`（追加）

- [ ] **Step 1: 追加失败测试**

追加到 `MathParsingIntegrationTests`（同文件内新 `@Suite`）：

```swift
@Suite("Math incremental boundary")
struct MathIncrementalBoundaryTests {
    @Test("跨保留块的 $$ 流式追加，增量 == 全量")
    func crossBlockStreaming() {
        let prev = "intro paragraph\n\n$$\n\\frac{a}{b}\n"
        let next = prev + "\\frac{c}{d}\n$$\n\ntail"
        let incremental = MarkdownDocument(parsing: prev).parsingAppend(to: next, previousSource: prev)
        let full = MarkdownDocument(parsing: next)
        #expect(incremental.blocks == full.blocks)
    }

    @Test("追加不含跨界公式时仍走增量且结果正确")
    func normalAppendStillWorks() {
        let prev = "# Title\n\nfirst $a$ done"
        let next = prev + "\n\nsecond paragraph"
        let incremental = MarkdownDocument(parsing: prev).parsingAppend(to: next, previousSource: prev)
        let full = MarkdownDocument(parsing: next)
        #expect(incremental.blocks == full.blocks)
    }

    @Test("代码围栏内 $$ 不触发误判，增量 == 全量")
    func codeFenceNotMisread() {
        let prev = "```\n$$ not math\n"
        let next = prev + "still code\n```\n\nreal $x$"
        let incremental = MarkdownDocument(parsing: prev).parsingAppend(to: next, previousSource: prev)
        #expect(incremental.blocks == MarkdownDocument(parsing: next).blocks)
    }
}
```

- [ ] **Step 2: 运行验证失败**

Run: `swift test --filter "Math incremental boundary"`
Expected: FAIL（`crossBlockStreaming` 增量与全量不一致）。

- [ ] **Step 3: 在 parsingAppend 入口加边界判定**

`Sources/MarkdownCore/DocumentParser.swift`，`parsingAppend` 方法体最前面插入：

```swift
    public func parsingAppend(to newSource: String, previousSource: String) -> MarkdownDocument {
        // 数学感知：若被保留的 prefix 可能含会被追加文本闭合的未闭合数学开界符，
        // suffix-only 扫描看不到开界符，直接全量解析以保证与全量一致（spec §4.3）。
        if Self.previousSourceHasOpenMathDelimiter(previousSource) {
            return MarkdownDocument(parsing: newSource)
        }
        guard
            newSource.hasPrefix(previousSource),
            ...
```

（其余原逻辑不变。）在 `MarkdownDocument` 内追加静态判定：

```swift
    /// previousSource 末尾是否处于「数学定界符未闭合」状态。
    /// 复用 MathScanner 的代码区/转义规则：若存在任何开界符但 scan 未把它配成 span，
    /// 说明闭合符尚未出现，追加文本可能闭合它 → 必须全量。
    static func previousSourceHasOpenMathDelimiter(_ source: String) -> Bool {
        let spans = MathScanner.scan(source)
        let bytes = Array(source.utf8)
        // 收集所有「裸的、非代码区、未转义」的候选开界符位置。
        let covered = spans.map(\.range)
        func isCovered(_ i: Int) -> Bool { covered.contains { $0.contains(i) } }
        let mask = MathScanner.debugCodeMask(source: source)
        var i = 0
        while i < bytes.count {
            if mask[i] { i += 1; continue }
            // 未转义反斜杠计数
            var bs = 0, k = i - 1
            while k >= 0, bytes[k] == 0x5C { bs += 1; k -= 1 }
            let escaped = bs % 2 == 1
            if !escaped, !isCovered(i) {
                if bytes[i] == 0x24 { return true }                         // $ 或 $$
                if bytes[i] == 0x5C, i + 1 < bytes.count,
                   bytes[i + 1] == 0x28 || bytes[i + 1] == 0x5B { return true } // \( 或 \[
            }
            i += 1
        }
        return false
    }
```

并在 `MathScanner` 暴露内部 mask 供此判定复用（保持「高亮/解析/边界」三者同一套规则）：在 `MathScanner` 末尾追加：

```swift
    /// 供增量边界判定复用同一套代码区规则。
    public static func debugCodeMask(source: String) -> [Bool] {
        codeRegionMask(source: source, byteCount: Array(source.utf8).count)
    }
```

- [ ] **Step 4: 运行验证通过**

Run: `swift test --filter "Math incremental boundary"`
Expected: PASS（3 用例全绿）。

- [ ] **Step 5: 回归既有增量测试**

Run: `swift test --filter "MarkdownCore incremental parsing"`
Expected: PASS（无公式时 `previousSourceHasOpenMathDelimiter` 返回 false，仍走原增量路径）。

- [ ] **Step 6: Commit**

```bash
git add Sources/MarkdownCore/DocumentParser.swift Sources/MarkdownCore/MathScanner.swift Tests/MarkdownKitTests/MathParsingTests.swift
git commit -m "feat(core): parsingAppend 数学感知边界，跨保留块公式全量回退"
```

---

## Task 7: RenderKit math 类型与注入协议

spec §5.1、§5.3。

**Files:**
- Create: `Sources/MarkdownRenderKit/MathRendering.swift`
- Test: `Tests/MarkdownKitTests/MathRenderingTests.swift`

- [ ] **Step 1: 写失败测试**

Create `Tests/MarkdownKitTests/MathRenderingTests.swift`:

```swift
import MarkdownRenderKit
import Testing
import Foundation

@Suite("Math rendering types")
struct MathRenderingTypeTests {
    @Test("有效字号 = 文本字号 × mathScale，单点计算")
    func effectivePointSize() {
        #expect(MathMetrics.effectivePointSize(textPointSize: 16, mathScale: 1.0) == 16)
        #expect(MathMetrics.effectivePointSize(textPointSize: 16, mathScale: 1.5) == 24)
    }

    @Test("MathCacheKey 任一维度不同则不相等")
    func cacheKeyIdentity() {
        let base = MathCacheKey(latex: "x", display: false, pointSize: 16,
                                colorHex: "#000", rasterScale: 2, rendererGeneration: 1)
        #expect(base == MathCacheKey(latex: "x", display: false, pointSize: 16,
                                     colorHex: "#000", rasterScale: 2, rendererGeneration: 1))
        #expect(base != MathCacheKey(latex: "x", display: false, pointSize: 24,
                                     colorHex: "#000", rasterScale: 2, rendererGeneration: 1))
        #expect(base != MathCacheKey(latex: "x", display: false, pointSize: 16,
                                     colorHex: "#000", rasterScale: 2, rendererGeneration: 2))
    }
}
```

- [ ] **Step 2: 运行验证失败**

Run: `swift test --filter "Math rendering types"`
Expected: 编译失败，`cannot find 'MathMetrics' in scope`。

- [ ] **Step 3: 实现类型与协议**

Create `Sources/MarkdownRenderKit/MathRendering.swift`:

```swift
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension NSAttributedString.Key {
    /// 未渲染数学占位标记，载荷为 "<display 0|1>\u{1F}<latex>"，对标 .markdownImageSource。
    public static let markdownMathSource = NSAttributedString.Key("MarkdownKit.mathSource")
}

/// 渲染好的公式字形。
public struct MathRenderedGlyph: Sendable {
    public init(image: PlatformImage, baselineOffsetEx: CGFloat) {
        self.image = image
        self.baselineOffsetEx = baselineOffsetEx
    }
    public let image: PlatformImage
    /// 由 SVG vertical-align 解析得到的基线偏移（ex 单位，正值=下移）。
    public let baselineOffsetEx: CGFloat
}

/// 渲染结果三态（spec §5.3）：消除 nil 无法区分取消与硬失败的歧义。
public enum MathRenderOutcome: Sendable {
    case rendered(MathRenderedGlyph)
    case failed
    case cancelled
}

/// 数学缓存键。`pointSize` 已是「有效字号」（文本字号 × mathScale）。
public struct MathCacheKey: Hashable, Sendable {
    public init(latex: String, display: Bool, pointSize: CGFloat,
                colorHex: String, rasterScale: CGFloat, rendererGeneration: Int) {
        self.latex = latex
        self.display = display
        self.pointSize = pointSize
        self.colorHex = colorHex
        self.rasterScale = rasterScale
        self.rendererGeneration = rendererGeneration
    }
    public let latex: String
    public let display: Bool
    public let pointSize: CGFloat
    public let colorHex: String
    public let rasterScale: CGFloat
    public let rendererGeneration: Int
}

/// 注入协议：MarkdownMath 提供实现，RenderKit 不依赖任何 MathJax。
public protocol MathRendering: Sendable {
    /// pointSize 已是有效字号（文本字号 × mathScale）；scale 为屏幕光栅化 scale。
    func render(latex: String, display: Bool, pointSize: CGFloat,
                scale: CGFloat, color: PlatformColor) async -> MathRenderOutcome
}

/// 有效字号契约（spec §5.1）：键计算与 render 调用都必须用这一个公式、同一处算出。
public enum MathMetrics {
    public static func effectivePointSize(textPointSize: CGFloat, mathScale: CGFloat) -> CGFloat {
        textPointSize * mathScale
    }

    /// 颜色转稳定 hex（含 alpha），用于缓存键。
    public static func colorHex(_ color: PlatformColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif canImport(AppKit)
        (color.usingColorSpace(.sRGB) ?? color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        func h(_ v: CGFloat) -> String { String(format: "%02X", Int((v * 255).rounded())) }
        return "#\(h(r))\(h(g))\(h(b))\(h(a))"
    }
}
```

- [ ] **Step 4: 运行验证通过**

Run: `swift test --filter "Math rendering types"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownRenderKit/MathRendering.swift Tests/MarkdownKitTests/MathRenderingTests.swift
git commit -m "feat(renderkit): MathRendering 协议、MathRenderOutcome、MathCacheKey、有效字号契约"
```

---

## Task 8: RenderKit 渲染 .math / .mathBlock

spec §5.2。命中缓存→attachment+基线；未命中→占位文本+属性；块级居中。

**Files:**
- Modify: `Sources/MarkdownRenderKit/AttributedStringRenderer.swift`
- Test: `Tests/MarkdownKitTests/MathRenderingTests.swift`（追加）

- [ ] **Step 1: 追加失败测试**

```swift
import MarkdownCore

@Suite("Math attributed rendering")
struct MathAttributedRenderingTests {
    @Test("未命中缓存 → 占位文本带 markdownMathSource 属性")
    func placeholderWhenMiss() {
        let r = AttributedStringRenderer(style: .default)
        let s = r.render([.paragraph([.text("a "), .math(latex: "x^2")])])
        var found = false
        s.enumerateAttribute(.markdownMathSource, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let payload = v as? String { #expect(payload == "0\u{1F}x^2"); found = true }
        }
        #expect(found)
    }

    @Test("命中缓存 → NSTextAttachment，基线按 baselineOffsetEx 下移")
    func attachmentWhenHit() {
        var r = AttributedStringRenderer(style: .default)
        let img = makePixel()
        let key = MathCacheKey(latex: "x^2", display: false,
                               pointSize: MathMetrics.effectivePointSize(textPointSize: 16, mathScale: 1.0),
                               colorHex: MathMetrics.colorHex(.label),
                               rasterScale: 1, rendererGeneration: 0)
        r.mathCache[key] = MathRenderedGlyph(image: img, baselineOffsetEx: 0.5)
        let s = r.render([.paragraph([.math(latex: "x^2")])])
        var hasAttachment = false
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if v is NSTextAttachment { hasAttachment = true }
        }
        #expect(hasAttachment)
    }
}

#if canImport(UIKit)
import UIKit
private func makePixel() -> PlatformImage {
    UIGraphicsImageRenderer(size: .init(width: 4, height: 4)).image { _ in }
}
#elseif canImport(AppKit)
import AppKit
private func makePixel() -> PlatformImage {
    let i = NSImage(size: .init(width: 4, height: 4)); i.lockFocus(); i.unlockFocus(); return i
}
#endif
```

- [ ] **Step 2: 运行验证失败**

Run: `swift test --filter "Math attributed rendering"`
Expected: FAIL（**注意**：`.math`/`.mathBlock` 在 Task 2 已作为「原样输出 latex 文本」的存根存在，所以这里不是编译失败，而是**行为失败**——占位文本无 `.markdownMathSource` 属性、命中缓存也不出 `NSTextAttachment`）。

- [ ] **Step 3: 加 mathCache 与渲染分支（替换 Task 2 存根，不是新增 case）**

> ⚠️ Task 2 已在 inline switch（`.html` 之前）与 block switch（`.table` 之前）各加了一个 `.math`/`.mathBlock` **存根 case**（`NSAttributedString(string: latex, ...)` 原样回退）。本步骤是**就地替换这两个存根 case 的实现体**，**不要新增 case**（重复 case 会编译报错）。位置：inline 存根约在 `renderInline` 的 `.html` 分支前、block 存根约在 `renderBlock` 的 `.table` 分支前。

`AttributedStringRenderer.swift`，在 `public var imageCache` 声明后追加：

```swift
    /// 渲染好的公式字形缓存，键含有效字号/颜色/scale/renderer 代际。平台层填充。
    public var mathCache: [MathCacheKey: MathRenderedGlyph] = [:]
    /// 当前光栅化 scale 与 renderer 代际，参与缓存键（平台层设置）。
    public var mathRasterScale: CGFloat = 1
    public var mathRendererGeneration: Int = 0
```

把 Task 2 的 inline `.math` 存根（`.html` 分支前那个 `case .math(let latex): return NSAttributedString(string: latex, ...)`）的实现体**替换**为：

```swift
        case .math(let latex):
            return self.renderMath(latex: latex, display: false, baseAttributes: attributes)
```

把 Task 2 的 block `.mathBlock` 存根（`renderBlock` 里 `.table` 分支前那个 `case .mathBlock(let latex):` 原样回退）的实现体**替换**为：

```swift
        case .mathBlock(let latex):
            return self.renderMathBlock(latex: latex)
```

在 `// MARK: - Attribute helpers` 之前追加方法：

```swift
    private func mathPayload(latex: String, display: Bool) -> String {
        "\(display ? "1" : "0")\u{1F}\(latex)"
    }

    private func effectiveMathPointSize() -> CGFloat {
        let base = (self.style.bodyFont as PlatformFont).pointSize
        return MathMetrics.effectivePointSize(textPointSize: base, mathScale: self.style.mathScale)
    }

    private func mathColor() -> PlatformColor {
        self.style.mathColorOverride ?? self.style.textColor
    }

    private func renderMath(
        latex: String, display: Bool, baseAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let key = MathCacheKey(
            latex: latex, display: display,
            pointSize: self.effectiveMathPointSize(),
            colorHex: MathMetrics.colorHex(self.mathColor()),
            rasterScale: self.mathRasterScale,
            rendererGeneration: self.mathRendererGeneration
        )
        if let glyph = self.mathCache[key] {
            let attachment = NSTextAttachment()
            attachment.image = glyph.image
            let sz = glyph.image.size
            let exToPoints = self.effectiveMathPointSize() * 0.5
            attachment.bounds = CGRect(
                x: 0, y: -glyph.baselineOffsetEx * exToPoints,
                width: sz.width, height: sz.height
            )
            return NSAttributedString(attachment: attachment)
        }
        var a = baseAttributes
        a[.font] = self.style.codeFont
        a[.foregroundColor] = self.style.secondaryTextColor
        a[.markdownMathSource] = self.mathPayload(latex: latex, display: display)
        let shown = display ? latex : latex
        return NSAttributedString(string: shown, attributes: a)
    }

    private func renderMathBlock(latex: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = self.style.paragraphSpacing
        let base = self.bodyAttributes().merging([.paragraphStyle: para]) { _, new in new }
        let body = self.renderMath(latex: latex, display: true, baseAttributes: base)
        let m = NSMutableAttributedString(attributedString: body)
        m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
        return m
    }
```

> 注：`renderInline` 当前签名携带 `attributes`，按现有该函数实参名传入 `baseAttributes`。若现有 inline 渲染方法名/参数名不同，以文件实际为准接线，渲染语义不变。

- [ ] **Step 4: 运行验证通过**

Run: `swift test --filter "Math attributed rendering"`
Expected: PASS

- [ ] **Step 5: 回归既有渲染测试**

Run: `swift test --filter "MarkdownRenderKit"`
Expected: PASS（既有渲染行为不回归）。

- [ ] **Step 6: Commit**

```bash
git add Sources/MarkdownRenderKit/AttributedStringRenderer.swift Tests/MarkdownKitTests/MathRenderingTests.swift
git commit -m "feat(renderkit): 渲染 .math/.mathBlock，命中出 attachment、未命中出占位"
```

---

## Task 9: RenderStyle 新增 mathTokenColor（mathScale/mathColorOverride 已由 Task 8 提前加入）

spec §9。

> ⚠️ **Task 8 评审协调：** Task 8 已提前在 `RenderStyle` 加入 `mathScale: CGFloat = 1.0` 与 `mathColorOverride: PlatformColor?`（带默认值），并已在 `isSemanticallyEqual` 中比较这两者、把 `Tests/MarkdownKitTests/MarkdownRenderKitTests.swift` 里「覆盖每个存储属性」的属性计数守卫从 20 → 22。**本任务不得重复添加这两个字段**，只新增 `mathTokenColor`；并相应：在 `isSemanticallyEqual` 增加对 `mathTokenColor` 的比较、把属性计数守卫 22 → 23。

**Files:**
- Modify: `Sources/MarkdownRenderKit/RenderStyle.swift`
- Modify: `Tests/MarkdownKitTests/MarkdownRenderKitTests.swift`（属性计数守卫 22→23）
- Test: `Tests/MarkdownKitTests/MathRenderingTests.swift`（追加）

- [ ] **Step 1: 追加失败测试**

```swift
@Suite("RenderStyle math fields")
struct RenderStyleMathTests {
    @Test("默认值：mathScale=1，mathColorOverride=nil，mathTokenColor 非空")
    func defaults() {
        let s = RenderStyle.default
        #expect(s.mathScale == 1.0)            // Task 8 已加，断言仍应成立
        #expect(s.mathColorOverride == nil)    // Task 8 已加，断言仍应成立
        _ = s.mathTokenColor                   // 本任务新增——存在即可
    }
}
```

- [ ] **Step 2: 运行验证失败**

Run: `swift test --filter RenderStyleMathTests`
Expected: 编译失败，`value of type 'RenderStyle' has no member 'mathTokenColor'`（`mathScale`/`mathColorOverride` 已存在，只有 `mathTokenColor` 缺失）。

- [ ] **Step 3: 只加 `mathTokenColor`（带默认值）**

`RenderStyle.swift` 的 `struct RenderStyle` 内，紧邻已存在的 `mathScale`/`mathColorOverride` 之后追加：

```swift
    /// 编辑器中数学定界符 token 的高亮色。
    public var mathTokenColor: PlatformColor = {
        #if canImport(UIKit)
        return UIColor.systemTeal
        #elseif canImport(AppKit)
        return NSColor.systemTeal
        #endif
    }()
```

> 不要再添加 `mathScale` / `mathColorOverride`（已存在会导致重复声明编译错误）。默认值保证现有 `RenderStyle(...)` 初始化器与 `.default` 工厂仍编译。

- [ ] **Step 4: 同步 isSemanticallyEqual 与属性计数守卫**

在 `RenderStyle.isSemanticallyEqual` 中，紧随已有的 `mathScale`/`mathColorOverride` 比较，增加对 `mathTokenColor` 的比较（与现有 `PlatformColor` 比较风格一致，如 `lhs.mathTokenColor.isEqual(rhs.mathTokenColor)` 或代码库既有等值写法）。在 `Tests/MarkdownKitTests/MarkdownRenderKitTests.swift` 的「覆盖每个存储属性」守卫里，把期望属性数 **22 → 23**（连同其注释一并更新）。

- [ ] **Step 5: 运行验证通过**

Run: `swift test --filter RenderStyleMathTests` 与 `swift test --filter MarkdownRenderKitTests`
Expected: 均 PASS（含属性计数守卫 23）。

- [ ] **Step 6: 回归**

Run: `swift build && swift test 2>&1 | tail -8`
Expected: 退出码 0；全量绿、零回归。

- [ ] **Step 7: Commit**

```bash
git add Sources/MarkdownRenderKit/RenderStyle.swift Tests/MarkdownKitTests/MarkdownRenderKitTests.swift Tests/MarkdownKitTests/MathRenderingTests.swift
git commit -m "feat(renderkit): RenderStyle 新增 mathTokenColor（mathScale/Override 已于 Task 8 加入）"
```

---

## Task 10: MathLoadCoordinator — 平台无关异步加载/负缓存/失效

spec §6、§6.1。这是平台层逻辑核心，纯逻辑、可在 macOS 跑测。

**Files:**
- Create: `Sources/MarkdownPlatformView/MathLoadCoordinator.swift`
- Test: `Tests/MarkdownKitTests/MathLoadCoordinatorTests.swift`

- [ ] **Step 1: 写失败测试**

Create `Tests/MarkdownKitTests/MathLoadCoordinatorTests.swift`:

```swift
@testable import MarkdownPlatformView
import MarkdownRenderKit
import Testing
import Foundation

private actor CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

private struct StubRenderer: MathRendering {
    let outcome: @Sendable () -> MathRenderOutcome
    let counter: CallCounter
    func render(latex: String, display: Bool, pointSize: CGFloat,
                scale: CGFloat, color: PlatformColor) async -> MathRenderOutcome {
        await counter.bump()
        return outcome()
    }
}

@Suite("MathLoadCoordinator")
struct MathLoadCoordinatorTests {
    private func key(_ latex: String, gen: Int = 1) -> MathCacheKey {
        MathCacheKey(latex: latex, display: false, pointSize: 16,
                     colorHex: "#000", rasterScale: 2, rendererGeneration: gen)
    }

    @Test("nil renderer → 不派发")
    func nilRendererNoDispatch() async {
        let c = MathLoadCoordinator()
        let dispatched = await c.loadIfNeeded(key: key("x"), latex: "x", display: false,
                                              pointSize: 16, scale: 2, color: .black)
        #expect(dispatched == false)
    }

    @Test(".rendered → 进正缓存，再次不重复派发")
    func renderedCachedOnce() async {
        let counter = CallCounter()
        let c = MathLoadCoordinator()
        let img = pixel()
        await c.setRenderer(StubRenderer(outcome: { .rendered(.init(image: img, baselineOffsetEx: 0)) },
                                         counter: counter))
        _ = await c.loadIfNeeded(key: key("x"), latex: "x", display: false, pointSize: 16, scale: 2, color: .black)
        await c.drain()
        #expect(await c.glyph(for: key("x")) != nil)
        _ = await c.loadIfNeeded(key: key("x"), latex: "x", display: false, pointSize: 16, scale: 2, color: .black)
        await c.drain()
        #expect(await counter.count == 1)
    }

    @Test(".failed → 负缓存，后续 pass 不再派发")
    func failedNegativeCached() async {
        let counter = CallCounter()
        let c = MathLoadCoordinator()
        await c.setRenderer(StubRenderer(outcome: { .failed }, counter: counter))
        for _ in 0 ..< 5 {
            _ = await c.loadIfNeeded(key: key("bad"), latex: "bad", display: false, pointSize: 16, scale: 2, color: .black)
            await c.drain()
        }
        #expect(await counter.count == 1)
        #expect(await c.glyph(for: key("bad")) == nil)
    }

    @Test(".cancelled → 不写任何缓存，可重试")
    func cancelledRetryable() async {
        let counter = CallCounter()
        let c = MathLoadCoordinator()
        await c.setRenderer(StubRenderer(outcome: { .cancelled }, counter: counter))
        _ = await c.loadIfNeeded(key: key("c"), latex: "c", display: false, pointSize: 16, scale: 2, color: .black)
        await c.drain()
        _ = await c.loadIfNeeded(key: key("c"), latex: "c", display: false, pointSize: 16, scale: 2, color: .black)
        await c.drain()
        #expect(await counter.count == 2)
    }

    @Test("换 renderer → generation 自增且清正/负/loading 缓存")
    func rendererSwapClears() async {
        let counter = CallCounter()
        let c = MathLoadCoordinator()
        await c.setRenderer(StubRenderer(outcome: { .failed }, counter: counter))
        let g1 = await c.generation
        _ = await c.loadIfNeeded(key: key("z", gen: g1), latex: "z", display: false, pointSize: 16, scale: 2, color: .black)
        await c.drain()
        await c.setRenderer(StubRenderer(outcome: {
            .rendered(.init(image: pixel(), baselineOffsetEx: 0)) }, counter: counter))
        let g2 = await c.generation
        #expect(g2 == g1 + 1)
        #expect(await c.isNegativeCached(key("z", gen: g1)) == false)  // 旧负缓存被清
    }
}

#if canImport(UIKit)
import UIKit
private func pixel() -> PlatformImage { UIGraphicsImageRenderer(size: .init(width: 2, height: 2)).image { _ in } }
#elseif canImport(AppKit)
import AppKit
private func pixel() -> PlatformImage { let i = NSImage(size: .init(width: 2, height: 2)); i.lockFocus(); i.unlockFocus(); return i }
#endif
```

- [ ] **Step 2: 运行验证失败**

Run: `swift test --filter "MathLoadCoordinator"`
Expected: 编译失败，`cannot find 'MathLoadCoordinator' in scope`。

- [ ] **Step 3: 实现 coordinator**

Create `Sources/MarkdownPlatformView/MathLoadCoordinator.swift`:

```swift
import Foundation
import MarkdownRenderKit

/// 平台无关的数学渲染协调器：去重派发、三态分派、负缓存、代际失效。
/// 由平台视图持有；视图负责枚举 .markdownMathSource 并在完成回调里 setNeedsLayout/重渲染。
public actor MathLoadCoordinator {
    public init() {}

    private var renderer: (any MathRendering)?
    public private(set) var generation: Int = 0

    private var positive: [MathCacheKey: MathRenderedGlyph] = [:]
    private var negative: Set<MathCacheKey> = []
    private var inFlight: Set<MathCacheKey> = []
    private var tasks: [Task<Void, Never>] = []

    /// 设置/替换渲染器：代际自增并清正/负/loading（spec §6）。
    public func setRenderer(_ r: (any MathRendering)?) {
        renderer = r
        generation += 1
        positive.removeAll()
        negative.removeAll()
        inFlight.removeAll()
    }

    /// scale 变化时清缓存并由调用方用新 rasterScale 重建键。
    public func invalidateForScaleChange() {
        positive.removeAll(); negative.removeAll(); inFlight.removeAll()
    }

    public func glyph(for key: MathCacheKey) -> MathRenderedGlyph? { positive[key] }
    public func isNegativeCached(_ key: MathCacheKey) -> Bool { negative.contains(key) }

    /// 需要时派发渲染。返回是否真的派发了任务（用于测试与去抖）。
    @discardableResult
    public func loadIfNeeded(
        key: MathCacheKey, latex: String, display: Bool,
        pointSize: CGFloat, scale: CGFloat, color: PlatformColor
    ) -> Bool {
        guard let renderer else { return false }                 // nil → early-out
        if positive[key] != nil || negative.contains(key) || inFlight.contains(key) { return false }
        inFlight.insert(key)
        let task = Task { [weak self] in
            let outcome = await renderer.render(
                latex: latex, display: display, pointSize: pointSize, scale: scale, color: color)
            await self?.finish(key: key, outcome: outcome)
        }
        tasks.append(task)
        return true
    }

    private func finish(key: MathCacheKey, outcome: MathRenderOutcome) {
        inFlight.remove(key)
        switch outcome {
        case .rendered(let glyph): positive[key] = glyph
        case .failed: negative.insert(key)            // 确定性失败 → 负缓存，不再派发
        case .cancelled: break                        // 瞬态 → 不缓存，允许重试
        }
    }

    /// 测试辅助：等所有在途任务结束。
    public func drain() async {
        let snapshot = tasks
        tasks.removeAll()
        for t in snapshot { _ = await t.value }
    }
}
```

- [ ] **Step 4: 运行验证通过**

Run: `swift test --filter "MathLoadCoordinator"`
Expected: PASS（6 用例全绿）。

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownPlatformView/MathLoadCoordinator.swift Tests/MarkdownKitTests/MathLoadCoordinatorTests.swift
git commit -m "feat(platformview): MathLoadCoordinator 异步派发/三态/负缓存/代际失效"
```

---

## Task 11: 接入 MarkdownLabelView（AppKit 路径跑测，iOS 路径对称构建校验）

spec §6。把 coordinator 接到读视图：渲染产出占位 → 视图枚举 `.markdownMathSource` → 派发 → 完成回写 `renderer.mathCache` → 重渲染。

**Files:**
- Modify: `Sources/MarkdownPlatformView/MarkdownLabelView.swift`
- Test: `Tests/MarkdownKitTests/MathLoadCoordinatorTests.swift`（追加端到端用例）

- [ ] **Step 1: 追加端到端失败测试（驱动 coordinator + renderer 回写闭环，不依赖真实 NSView 布局）**

```swift
@Suite("Math view wiring")
struct MathViewWiringTests {
    @Test("占位属性可被枚举并驱动 coordinator，回写后渲染出附件")
    func placeholderDrivesCoordinator() async {
        var renderer = AttributedStringRenderer(style: .default)
        let attr = renderer.render([.paragraph([.math(latex: "x")])])

        // 模拟视图的枚举逻辑（与 MarkdownLabelView.triggerMathLoads 同构）。
        var payloads: [String] = []
        attr.enumerateAttribute(.markdownMathSource, in: NSRange(location: 0, length: attr.length)) { v, _, _ in
            if let p = v as? String { payloads.append(p) }
        }
        #expect(payloads == ["0\u{1F}x"])

        let c = MathLoadCoordinator()
        await c.setRenderer(StubRenderer(outcome: {
            .rendered(.init(image: pixel(), baselineOffsetEx: 0)) }, counter: CallCounter()))
        let gen = await c.generation
        let key = MathCacheKey(latex: "x", display: false,
                               pointSize: (RenderStyle.default.bodyFont as PlatformFont).pointSize,
                               colorHex: MathMetrics.colorHex(RenderStyle.default.textColor),
                               rasterScale: 1, rendererGeneration: gen)
        _ = await c.loadIfNeeded(key: key, latex: "x", display: false,
                                 pointSize: key.pointSize, scale: 1, color: RenderStyle.default.textColor)
        await c.drain()
        renderer.mathRendererGeneration = gen
        renderer.mathCache[key] = await c.glyph(for: key)
        let attr2 = renderer.render([.paragraph([.math(latex: "x")])])
        var hasAttachment = false
        attr2.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr2.length)) { v, _, _ in
            if v is NSTextAttachment { hasAttachment = true }
        }
        #expect(hasAttachment)
    }
}
```

- [ ] **Step 2: 运行验证失败/通过基线**

Run: `swift test --filter "Math view wiring"`
Expected: PASS（此用例只依赖已实现的 renderer + coordinator；作为接线契约基线。若红，说明 Task 8/10 接口漂移，先修正接口）。

- [ ] **Step 3: 在 MarkdownLabelView 接线（iOS UIView 路径）**

`MarkdownLabelView.swift` 的 `#if canImport(UIKit)` 分支，参照既有 `_imageCache` / `triggerImageLoads` / `loadImage` / `finishImageLoad` 的结构，新增对称成员（放在 `_imageCache` 邻近）：

```swift
    private let _mathCoordinator = MathLoadCoordinator()
    public var mathRenderer: (any MathRendering)? {
        didSet { Task { await _mathCoordinator.setRenderer(mathRenderer) } }
    }

    private func triggerMathLoads(in range: NSRange) {
        guard mathRenderer != nil, let str = contentStorage.attributedString else { return }
        let safe = range.clamped(to: str.length)
        guard safe.length > 0 else { return }
        let scale = self.window?.screen.scale ?? UIScreen.main.scale
        str.enumerateAttribute(.markdownMathSource, in: safe) { value, _, _ in
            guard let payload = value as? String,
                  let sep = payload.firstIndex(of: "\u{1F}") else { return }
            let display = payload[payload.startIndex] == "1"
            let latex = String(payload[payload.index(after: sep)...])
            let color = self.renderStyle.mathColorOverride ?? self.renderStyle.textColor
            let pt = MathMetrics.effectivePointSize(
                textPointSize: (self.renderStyle.bodyFont as PlatformFont).pointSize,
                mathScale: self.renderStyle.mathScale)
            Task { [weak self] in
                guard let self else { return }
                let gen = await self._mathCoordinator.generation
                let key = MathCacheKey(latex: latex, display: display, pointSize: pt,
                                       colorHex: MathMetrics.colorHex(color),
                                       rasterScale: scale, rendererGeneration: gen)
                let dispatched = await self._mathCoordinator.loadIfNeeded(
                    key: key, latex: latex, display: display,
                    pointSize: pt, scale: scale, color: color)
                if dispatched {
                    await self._mathCoordinator.drain()
                    if let glyph = await self._mathCoordinator.glyph(for: key) {
                        await MainActor.run {
                            self._cachedRenderer?.mathRasterScale = scale
                            self._cachedRenderer?.mathRendererGeneration = gen
                            self._cachedRenderer?.mathCache[key] = glyph
                            self.updateContent()
                        }
                    }
                }
            }
        }
    }
```

在既有触发图片加载的同一处（`triggerImageLoads(in:)` 调用点，通常在布局/可见区域更新后）紧随调用 `self.triggerMathLoads(in: <同一 range>)`。

- [ ] **Step 4: 在 AppKit 路径做同构接线**

`#elseif canImport(AppKit)` 分支，参照其 `_imageCache`/`loadImage`（约 1349–1780 行）做与 Step 3 等价的实现：差异仅 `scale` 取 `self.window?.backingScaleFactor ?? 2`，其余逻辑、键计算、回写、`updateContent()` 完全一致（不要写 "同 Step 3"，按其 AppKit 上下文实名落地）。

- [ ] **Step 5: 构建校验两路**

Run: `swift build`
Expected: 退出码 0（宿主 macOS 编译 AppKit 路径）。
Run: `xcodebuild -scheme MarkdownKit -destination 'generic/platform=iOS' build` （若无 iOS SDK 环境，跳过并记录「iOS 路径仅静态对称、未机器校验」）
Expected: 成功或显式记录跳过原因。

- [ ] **Step 6: 回归**

Run: `swift test --filter "Math view wiring"` 与 `swift test --filter "MarkdownRenderKit"`
Expected: PASS。

- [ ] **Step 7: Commit**

```bash
git add Sources/MarkdownPlatformView/MarkdownLabelView.swift Tests/MarkdownKitTests/MathLoadCoordinatorTests.swift
git commit -m "feat(platformview): MarkdownLabelView 接入数学异步加载（iOS+AppKit 对称）"
```

---

## Task 12: SwiftUI `.mathRenderer(_:)` 修饰符

spec §7。

**Files:**
- Create: `Sources/MarkdownKit/MathRendererModifier.swift`
- Test: `Tests/MarkdownKitTests/MathRenderingTests.swift`（追加）

- [ ] **Step 1: 追加失败测试**

```swift
import MarkdownKit
import SwiftUI

@Suite("SwiftUI math renderer env")
struct MathRendererEnvTests {
    @Test("环境值默认 nil，设置后可取回")
    func envValue() {
        var env = EnvironmentValues()
        #expect(env.markdownMathRenderer == nil)
        struct Dummy: MathRendering {
            func render(latex: String, display: Bool, pointSize: CGFloat,
                        scale: CGFloat, color: PlatformColor) async -> MathRenderOutcome { .failed }
        }
        env.markdownMathRenderer = Dummy()
        #expect(env.markdownMathRenderer != nil)
    }
}
```

- [ ] **Step 2: 运行验证失败**

Run: `swift test --filter "SwiftUI math renderer env"`
Expected: 编译失败，`value of type 'EnvironmentValues' has no member 'markdownMathRenderer'`。

- [ ] **Step 3: 实现环境键与修饰符**

Create `Sources/MarkdownKit/MathRendererModifier.swift`:

```swift
import SwiftUI
import MarkdownRenderKit

private struct MarkdownMathRendererKey: EnvironmentKey {
    static let defaultValue: (any MathRendering)? = nil
}

extension EnvironmentValues {
    public var markdownMathRenderer: (any MathRendering)? {
        get { self[MarkdownMathRendererKey.self] }
        set { self[MarkdownMathRendererKey.self] = newValue }
    }
}

extension View {
    /// 注入数学渲染器；未调用则公式降级为原始 LaTeX 文本。
    public func mathRenderer(_ renderer: any MathRendering) -> some View {
        environment(\.markdownMathRenderer, renderer)
    }
}
```

- [ ] **Step 4: 把环境值接到读视图 representable**

在承载 `MarkdownLabelView` 的 SwiftUI 包装（`MarkdownText` / `MarkdownStreamingText` 对应的 `UIViewRepresentable`/`NSViewRepresentable`，文件 `Sources/MarkdownKit/MarkdownText.swift` 等）里，读 `@Environment(\.markdownMathRenderer)` 并在 `updateUIView`/`updateNSView` 中赋值：

```swift
    @Environment(\.markdownMathRenderer) private var mathRenderer
    // updateUIView/updateNSView 内：
    view.mathRenderer = mathRenderer
```

（若 `MarkdownText` 用的是值类型 representable，按其既有 `renderStyle` 注入方式同处接线。）

- [ ] **Step 5: 运行验证通过 + 构建**

Run: `swift test --filter "SwiftUI math renderer env"`
Expected: PASS
Run: `swift build`
Expected: 退出码 0。

- [ ] **Step 6: Commit**

```bash
git add Sources/MarkdownKit/MathRendererModifier.swift Sources/MarkdownKit Tests/MarkdownKitTests/MathRenderingTests.swift
git commit -m "feat(kit): SwiftUI .mathRenderer(_:) 修饰符与环境注入"
```

---

## Task 13: MarkdownMath — SVGRasterizer

spec §8。SVG 字符串 → 颜色注入 → 解析 ex/viewBox/vertical-align → SwiftDraw 光栅化 → `PlatformImage` + 基线。

> ⚠️ **点尺寸契约（Task 8 评审强制）：** 返回的 `MathRenderedGlyph.image` 的 `.size` **必须是「点」单位**（= 目标文本空间渲染尺寸），**不是像素**。`AttributedStringRenderer` 直接拿 `image.size` 当 `NSTextAttachment.bounds`，所以若 `.size` 等于 `pointSize×scale`（像素），行内公式会在 Retina 上放大 scale 倍。SwiftDraw `rasterize(with:scale:)` 产出 `size×scale` 像素位图但应把结果图像 `.size` 报告为**点** `size`（UIImage 用 `scale:` 初始化；NSImage 显式设 `.size = 点尺寸`）——实现必须保证这一点，并由上面 `rasterize()` 测试的「size 与 scale 无关、随 pointSize 增长」断言守住。

**Files:**
- Create: `Sources/MarkdownMath/SVGRasterizer.swift`
- Test: `Tests/MarkdownMathTests/SVGRasterizerTests.swift`（追加，替换 spike 文件中的占位 suite 为正式 suite）

- [ ] **Step 1: 追加失败测试**

在 `Tests/MarkdownMathTests/SVGRasterizerTests.swift` 追加：

```swift
@testable import MarkdownMath
import MarkdownRenderKit

@Suite("SVGRasterizer")
struct SVGRasterizerUnitTests {
    private let sample = """
    <svg xmlns="http://www.w3.org/2000/svg" width="2.5ex" height="1.2ex" \
    viewBox="0 -442 1041 466" style="vertical-align: -0.25ex;"><g fill="currentColor">\
    <rect x="0" y="0" width="100" height="100"/></g></svg>
    """

    @Test("注入颜色：currentColor 被替换为指定 hex")
    func colorInjection() {
        let out = SVGRasterizer.injectColor(into: sample, hex: "#FF0000")
        #expect(!out.contains("currentColor"))
        #expect(out.contains("#FF0000"))
    }

    @Test("解析 vertical-align(ex) 为基线偏移")
    func parseBaseline() {
        #expect(SVGRasterizer.parseVerticalAlignEx(sample) == -0.25)
    }

    @Test("光栅化产出非退化位图 + 基线 + 点尺寸契约")
    func rasterize() throws {
        let glyph = try SVGRasterizer.rasterize(
            svg: sample, hex: "#000000", pointSize: 16, scale: 2)
        #expect(glyph.image.size.width > 1)
        #expect(glyph.baselineOffsetEx == -0.25)
        // 契约（Task 8 评审）：image.size 必须是「点」单位（= 目标渲染文本空间尺寸），
        // 不是像素；栅格密度由平台图像的 scale/backing 编码，绝不体现在 size 上。
        // AttributedStringRenderer 直接把 image.size 当 NSTextAttachment.bounds，
        // 若这里返回像素尺寸（pointSize×scale）行内公式会在 Retina 上放大 scale 倍。
        // 断言 size 与目标点高成比例、且不随 scale 翻倍：
        let glyph1x = try SVGRasterizer.rasterize(
            svg: sample, hex: "#000000", pointSize: 16, scale: 1)
        #expect(abs(glyph.image.size.height - glyph1x.image.size.height) < 0.5)   // size 与 scale 无关（点单位）
        let glyphBig = try SVGRasterizer.rasterize(
            svg: sample, hex: "#000000", pointSize: 32, scale: 2)
        #expect(glyphBig.image.size.height > glyph.image.size.height)             // size 随 pointSize 增长
    }
}
```

- [ ] **Step 2: 运行验证失败**

Run: `swift test --filter "SVGRasterizer"`
Expected: 编译失败，`cannot find 'SVGRasterizer' in scope`。

- [ ] **Step 3: 实现 SVGRasterizer**

Create `Sources/MarkdownMath/SVGRasterizer.swift`:

```swift
import Foundation
import SwiftDraw
import MarkdownRenderKit

enum SVGRasterizerError: Error { case parseFailed, rasterizeFailed }

enum SVGRasterizer {
    /// 把 SVG 里的 currentColor / fill 占位换成具体颜色。
    static func injectColor(into svg: String, hex: String) -> String {
        svg.replacingOccurrences(of: "currentColor", with: hex)
    }

    /// 解析 style="vertical-align: -0.25ex" → -0.25（无则 0）。
    static func parseVerticalAlignEx(_ svg: String) -> CGFloat {
        guard let r = svg.range(of: "vertical-align:") else { return 0 }
        let tail = svg[r.upperBound...]
        let token = tail.prefix(while: { $0 != ";" && $0 != "\"" })
            .trimmingCharacters(in: .whitespaces)
        let numeric = token.replacingOccurrences(of: "ex", with: "")
            .trimmingCharacters(in: .whitespaces)
        return CGFloat(Double(numeric) ?? 0)
    }

    /// 解析根 svg 的 height（优先 ex 单位）用于按 pointSize 定像素高。
    static func parseHeightEx(_ svg: String) -> CGFloat {
        guard let r = svg.range(of: "height=\"") else { return 2 }
        let tail = svg[r.upperBound...]
        let token = tail.prefix(while: { $0 != "\"" })
        let numeric = token.replacingOccurrences(of: "ex", with: "")
        return CGFloat(Double(numeric) ?? 2)
    }

    static func rasterize(
        svg: String, hex: String, pointSize: CGFloat, scale: CGFloat
    ) throws -> MathRenderedGlyph {
        let colored = injectColor(into: svg, hex: hex)
        guard let data = colored.data(using: .utf8),
              let drawing = SwiftDraw.SVG(data: data) else {
            throw SVGRasterizerError.parseFailed
        }
        // ex ≈ 0.5em；目标高 = heightEx * 0.5 * pointSize（点），再乘 scale 取像素。
        let heightPoints = max(1, parseHeightEx(svg) * 0.5 * pointSize)
        let aspect = drawing.size.height > 0 ? drawing.size.width / drawing.size.height : 1
        let targetPointSize = CGSize(width: heightPoints * aspect, height: heightPoints)
        let image = drawing.rasterize(with: targetPointSize, scale: scale)
        guard image.size.width > 1, image.size.height > 1 else {
            throw SVGRasterizerError.rasterizeFailed
        }
        return MathRenderedGlyph(image: image, baselineOffsetEx: parseVerticalAlignEx(svg))
    }
}
```

> 注：`SwiftDraw.SVG` 的 `rasterize` 精确签名以 Task 1 spike 中确认的实际 API 为准（可能是 `rasterize(scale:)` 或 `rasterize(with:scale:)`）；保持「按 pointSize 定高、按 scale 出像素、尺寸退化则抛 `.rasterizeFailed`」语义不变。

- [ ] **Step 4: 运行验证通过**

Run: `swift test --filter "SVGRasterizer"`
Expected: PASS（颜色注入 / 基线解析 / 非退化光栅化）。

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownMath/SVGRasterizer.swift Tests/MarkdownMathTests/SVGRasterizerTests.swift
git commit -m "feat(math): SVGRasterizer 颜色注入/基线解析/SwiftDraw 光栅化"
```

---

## Task 14: MarkdownMath — MathJaxRenderer

spec §8、§5.3。共享 MathJax 实例、failed 标志、取消、三态映射。

> ⚠️ **Task 13 评审强制契约（必须在本任务钉死）：** SVGRasterizer 的输入契约是「MathJax 默认 **inline** SVG」（根 `width="<num>ex"` + `viewBox`）。MathJax 的 **container/SVG-tag 模式**输出根 `width="100%"` 且根无 `viewBox` → SwiftDraw 解析返回 nil → 对**合法公式**静默 `.parseFailed`。本任务**必须**：
> 1. 显式配置 MathJax 为 **非 container**（默认 inline）模式产 SVG（确认 `SVGOutputProcessorOptions`/转换选项不开 container/SVG-tag）。
> 2. 加配置契约测试：真实 `tex2svg` 输出根含 `width="<num>ex"` 且**不含** `width="100%"`。
> 3. 加真实 fixture 颜色注入测试：对真实 MathJax SVG 跑 `SVGRasterizer.injectColor`，断言 `currentColor` 在 **`stroke=` 与 `fill=` 两处**都被替换为目标 hex 且结果不再含 `currentColor`（真实 MathJax 根是 `<g stroke="currentColor" fill="currentColor">`，合成样本只覆盖 fill）。
> 4. 加真实 fixture 端到端 `rasterize` 测试：真实合法公式 → 不抛错、`baselineOffsetEx` 为解析出的真实负值、`image.size` 为点尺寸量级（非 pixel×scale）。

**Files:**
- Create: `Sources/MarkdownMath/MathJaxRenderer.swift`
- Test: `Tests/MarkdownMathTests/MathJaxRendererTests.swift`

- [ ] **Step 1: 写失败测试**

Create `Tests/MarkdownMathTests/MathJaxRendererTests.swift`:

```swift
import Testing
import Foundation
import MarkdownMath
import MarkdownRenderKit

@Suite("MathJaxRenderer")
struct MathJaxRendererTests {
    @Test("合法公式 → .rendered，尺寸为正")
    func validRenders() async {
        let r = MathJaxRenderer()
        let out = await r.render(latex: "x^2+1", display: false,
                                 pointSize: 16, scale: 2, color: .black)
        guard case .rendered(let g) = out else { Issue.record("expected .rendered, got \(out)"); return }
        #expect(g.image.size.width > 1)
    }

    @Test("非法公式 → 仍 .rendered（MathJax 错误 SVG 算成功）")
    func invalidStillRenders() async {
        let r = MathJaxRenderer()
        let out = await r.render(latex: "\\thisCommandDoesNotExist", display: false,
                                 pointSize: 16, scale: 2, color: .black)
        if case .failed = out { Issue.record("LaTeX 语法错误不应是 .failed") }
        // .rendered 或（极端环境）.cancelled 均可；不应是 .failed。
    }

    @Test("取消的 Task → .cancelled，不污染")
    func cancellation() async {
        let r = MathJaxRenderer()
        let task = Task { await r.render(latex: "\\int_0^1 x", display: true,
                                         pointSize: 16, scale: 2, color: .black) }
        task.cancel()
        let out = await task.value
        if case .failed = out { Issue.record("取消不应映射为 .failed") }
    }
}
```

- [ ] **Step 2: 运行验证失败**

Run: `swift test --filter "MathJaxRenderer"`
Expected: 编译失败，`cannot find 'MathJaxRenderer' in scope`。

- [ ] **Step 3: 实现 MathJaxRenderer**

Create `Sources/MarkdownMath/MathJaxRenderer.swift`:

```swift
import Foundation
import MathJaxSwift
import MarkdownRenderKit

/// MathJax(JavaScriptCore) + SwiftDraw 实现 MathRendering。
/// init 抛错只记一次（failed 标志），后续直接 .failed。
public final class MathJaxRenderer: MathRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var _mathjax: MathJax?
    private var _failed = false

    public init() {}

    private func instance() -> MathJax? {
        lock.lock(); defer { lock.unlock() }
        if _failed { return nil }
        if let m = _mathjax { return m }
        do {
            let m = try MathJax(preferredOutputFormat: .svg)
            _mathjax = m
            return m
        } catch {
            _failed = true
            return nil
        }
    }

    public func render(
        latex: String, display: Bool, pointSize: CGFloat,
        scale: CGFloat, color: PlatformColor
    ) async -> MathRenderOutcome {
        if Task.isCancelled { return .cancelled }
        guard let mathjax = instance() else { return .failed }

        let svg: String
        do {
            svg = try await mathjax.tex2svg(
                latex,
                conversionOptions: ConversionOptions(display: display),
                inputOptions: TeXInputProcessorOptions(loadPackages: TeXInputProcessorOptions.Packages.all),
                outputOptions: SVGOutputProcessorOptions()
            )
        } catch is CancellationError {
            return .cancelled
        } catch {
            // tex2svg 对语法错误不抛（返回错误 SVG）；抛出多为 JS/引擎硬失败。
            return .failed
        }
        if Task.isCancelled { return .cancelled }

        do {
            let glyph = try SVGRasterizer.rasterize(
                svg: svg,
                hex: MathMetrics.colorHex(color),
                pointSize: pointSize,
                scale: scale
            )
            return .rendered(glyph)
        } catch {
            return .failed
        }
    }
}
```

- [ ] **Step 4: 运行验证通过**

Run: `swift test --filter "MathJaxRenderer"`
Expected: PASS（3 用例；`invalidStillRenders`/`cancellation` 只断言「非 .failed」语义）。

- [ ] **Step 5: 把依赖从 branch 收敛到 pin 版本**

读取 `Package.resolved` 里 `MathJaxSwift`、`SwiftDraw` 实际解析到的 `version`，把 `Package.swift` 两条 `branch: "main"` 改为 `.upToNextMajor(from: "<resolved-version>")`（用 `Package.resolved` 中的真实版本号填入，不臆造）。

Run: `swift package resolve && swift build`
Expected: 退出码 0，`Package.resolved` 版本不变。

- [ ] **Step 6: Commit**

```bash
git add Sources/MarkdownMath/MathJaxRenderer.swift Package.swift Package.resolved Tests/MarkdownMathTests/MathJaxRendererTests.swift
git commit -m "feat(math): MathJaxRenderer 三态映射/failed 标志/取消，依赖 pin 版本"
```

---

## Task 15: 编辑器数学 token 高亮

spec §9。复用 `MathScanner` 的同一套规则，只染色不渲染。

**Files:**
- Modify: `Sources/MarkdownRenderKit/MarkdownSourceHighlighter.swift`
- Test: `Tests/MarkdownKitTests/MathEditorHighlightTests.swift`

- [ ] **Step 1: 写失败测试**

Create `Tests/MarkdownKitTests/MathEditorHighlightTests.swift`:

```swift
import MarkdownRenderKit
import Testing
import Foundation

@Suite("Math editor highlight")
struct MathEditorHighlightTests {
    private func color(_ s: NSAttributedString, at i: Int) -> PlatformColor? {
        s.attribute(.foregroundColor, at: i, effectiveRange: nil) as? PlatformColor
    }

    @Test("$x$ 区段着 mathTokenColor，普通文本不着")
    func inlineMathColored() {
        let style = RenderStyle.default
        let h = MarkdownSourceHighlighter(style: style)
        let src = "ab $x^2$ cd"
        let out = h.highlight(src)
        let dollarIdx = (src as NSString).range(of: "$x^2$").location
        #expect(color(out, at: dollarIdx) == style.mathTokenColor)
        #expect(color(out, at: 0) != style.mathTokenColor)   // "a"
    }

    @Test("代码块内 $x$ 不被当公式高亮")
    func codeNotColored() {
        let style = RenderStyle.default
        let h = MarkdownSourceHighlighter(style: style)
        let src = "```\n$x$\n```"
        let out = h.highlight(src)
        let idx = (src as NSString).range(of: "$x$").location
        #expect(color(out, at: idx) != style.mathTokenColor)
    }
}
```

- [ ] **Step 2: 运行验证失败**

Run: `swift test --filter "Math editor highlight"`
Expected: FAIL（math 区段未着色）。

- [ ] **Step 3: 在 highlighter 加 math 着色（复用 MathScanner）**

`MarkdownSourceHighlighter.swift`，`highlight(_:)` 内在 `applyInlineHighlights` 之后、`paragraphStyle` 之前插入：

```swift
        self.applyMathHighlights(to: result, source: source)
```

并新增方法（放在 `applyInlineHighlights` 之后）：

```swift
    private func applyMathHighlights(to result: NSMutableAttributedString, source: String) {
        let ns = source as NSString
        let spans = MathScanner.scan(source)   // 与解析/增量同一套规则
        for span in spans {
            // MathSpan.range 是 UTF-8 字节区间，转回 NSString(UTF-16) 区间。
            let lower = utf16Index(ns, utf8Offset: span.range.lowerBound)
            let upper = utf16Index(ns, utf8Offset: span.range.upperBound)
            guard lower >= 0, upper > lower, upper <= ns.length else { continue }
            result.addAttribute(.foregroundColor, value: self.style.mathTokenColor,
                                range: NSRange(location: lower, length: upper - lower))
        }
    }

    private func utf16Index(_ ns: NSString, utf8Offset: Int) -> Int {
        // 线性映射：累加每个 UTF-16 单元对应的 UTF-8 字节数直到达到 offset。
        var u8 = 0
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            let s = String(utf16CodeUnits: [c], count: 1)
            let bytes = s.utf8.count
            if u8 >= utf8Offset { return i }
            u8 += bytes
            i += 1
        }
        return u8 >= utf8Offset ? i : -1
    }
```

> `MathScanner` 已是 `MarkdownCore` 的 public 类型；`MarkdownRenderKit` 已 `import MarkdownCore`（确认文件顶部存在该 import；`AttributedStringRenderer.swift` 已有）。本文件若未 import，则在顶部加 `import MarkdownCore`。

- [ ] **Step 4: 运行验证通过**

Run: `swift test --filter "Math editor highlight"`
Expected: PASS

- [ ] **Step 5: 回归编辑器既有高亮**

Run: `swift test --filter "MarkdownRenderKit"`
Expected: PASS（既有 heading/emphasis/code 高亮不回归）。

- [ ] **Step 6: Commit**

```bash
git add Sources/MarkdownRenderKit/MarkdownSourceHighlighter.swift Tests/MarkdownKitTests/MathEditorHighlightTests.swift
git commit -m "feat(renderkit): 编辑器复用 MathScanner 做数学 token 高亮（只染色不渲染）"
```

---

## Task 16: 端到端集成与全量回归

spec §12 验收。

**Files:**
- Test: `Tests/MarkdownMathTests/MathJaxRendererTests.swift`（追加端到端）

- [ ] **Step 1: 追加端到端用例（真实 MathJaxRenderer 驱动 RenderKit 出 attachment）**

```swift
@Suite("Math end to end")
struct MathEndToEndTests {
    @Test("MarkdownText 管线：解析→未命中占位→真实 renderer→命中出 attachment")
    func fullPipeline() async {
        let doc = MarkdownDocument(parsing: "Energy: $E=mc^2$\n\n$$\\sum_{i=1}^n i$$")
        var renderer = AttributedStringRenderer(style: .default)
        let first = renderer.render(doc.blocks)
        var payloads: [(String, Bool)] = []
        first.enumerateAttribute(.markdownMathSource, in: NSRange(location: 0, length: first.length)) { v, _, _ in
            if let p = v as? String, let sep = p.firstIndex(of: "\u{1F}") {
                payloads.append((String(p[p.index(after: sep)...]), p.first == "1"))
            }
        }
        #expect(payloads.contains(where: { $0.0 == "E=mc^2" && $0.1 == false }))
        #expect(payloads.contains(where: { $0.0 == "\\sum_{i=1}^n i" && $0.1 == true }))

        let mj = MathJaxRenderer()
        for (latex, display) in payloads {
            let pt = MathMetrics.effectivePointSize(
                textPointSize: (RenderStyle.default.bodyFont as PlatformFont).pointSize, mathScale: 1)
            let out = await mj.render(latex: latex, display: display, pointSize: pt,
                                      scale: 2, color: RenderStyle.default.textColor)
            guard case .rendered(let g) = out else { Issue.record("\(latex) not rendered"); continue }
            let key = MathCacheKey(latex: latex, display: display, pointSize: pt,
                                   colorHex: MathMetrics.colorHex(RenderStyle.default.textColor),
                                   rasterScale: 2, rendererGeneration: 1)
            renderer.mathRasterScale = 2
            renderer.mathRendererGeneration = 1
            renderer.mathCache[key] = g
        }
        let second = renderer.render(doc.blocks)
        var attachments = 0
        second.enumerateAttribute(.attachment, in: NSRange(location: 0, length: second.length)) { v, _, _ in
            if v is NSTextAttachment { attachments += 1 }
        }
        #expect(attachments == 2)
    }

    @Test("改 mathScale 后有效字号变、键变、需重渲染（不复用旧字形）")
    func mathScaleInvalidation() {
        var style = RenderStyle.default
        let base = (style.bodyFont as PlatformFont).pointSize
        let k1 = MathMetrics.effectivePointSize(textPointSize: base, mathScale: style.mathScale)
        style.mathScale = 2.0
        let k2 = MathMetrics.effectivePointSize(textPointSize: base, mathScale: style.mathScale)
        #expect(k1 != k2)
    }
}
```

- [ ] **Step 2: 运行端到端**

Run: `swift test --filter "Math end to end"`
Expected: PASS。

- [ ] **Step 3: 全量回归**

Run: `swift test`
Expected: 全绿。任何既有用例（图片/表格/列表/增量/编辑器命令/proxy）失败 → 回到对应 Task 修复，不改既有测试期望。

- [ ] **Step 4: 文档**

`README.md` 的「📋 Supported Markdown Features」列表加一行 `- ✅ LaTeX math via MarkdownMath ($…$, $$…$$, \(…\), \[…\])`；「📖 Public Modules」加 `MarkdownMath` 一条；新增简短「数学公式」小节，示例：

```swift
import MarkdownKit
import MarkdownMath

MarkdownText("Euler: $e^{i\\pi}+1=0$")
    .mathRenderer(MathJaxRenderer())
```

- [ ] **Step 5: Commit**

```bash
git add Tests/MarkdownMathTests/MathJaxRendererTests.swift README.md
git commit -m "test(math): 端到端管线 + mathScale 失效；文档补 MarkdownMath 用法"
```

---

## Self-Review

**Spec coverage：**
- §4.1 IR → Task 2 ✅；§4.2 扫描/哨兵/就地回填/表格降级/段落拆分 → Task 3/4/5 ✅；§4.3 增量边界 → Task 6 ✅；§4.4 共享扫描 → Task 3 + Task 15 复用 ✅
- §5.1 缓存键(含 rasterScale/generation/有效字号) → Task 7/8 ✅；§5.2 占位/命中/块级居中 → Task 8 ✅；§5.3 MathRenderOutcome 协议 → Task 7 ✅
- §6 nil early-out/清缓存/scale 失效 + §6.1 三态/负缓存/init 一次 → Task 10（逻辑）+ Task 11（接线）✅
- §7 SwiftUI 修饰符 → Task 12 ✅；§8 MarkdownMath/SVGRasterizer/MathJaxRenderer/pin 版本 → Task 1/13/14 ✅；§9 RenderStyle + 编辑器高亮 → Task 9/15 ✅
- §10 测试矩阵 → 分散到各 Task 的 TDD 用例（容器保留 T5、防伪造 T4/T5、增量边界 T6、失败负缓存/取消 T10、缓存失效 T10/T16、编辑器 T15、MarkdownMath gated T13/14）✅
- §11 风险：SwiftDraw 还原度 spike → Task 1 go/no-go ✅；§12 验收 → Task 16 ✅

**Placeholder 扫描：** 无 TBD/TODO；改码步骤均给完整代码；spike/接线步骤给出明确「实际 API 以解析后为准、语义不变」的判定标准而非含糊措辞。

**类型一致性：** `MathSpan`/`MathSentinel.Entry`/`MathCacheKey`(6 字段)/`MathRenderOutcome`(.rendered/.failed/.cancelled)/`MathRenderedGlyph`(image,baselineOffsetEx)/`MathRendering.render(latex:display:pointSize:scale:color:)`/`MathLoadCoordinator`(setRenderer/loadIfNeeded/glyph/generation/drain) 在 Task 3→16 间引用一致。占位载荷统一 `"<0|1>\u{1F}<latex>"`（Task 8 产出、Task 11/16 消费一致）。`MathMetrics.effectivePointSize` 单点计算（Task 7 定义，Task 8/11/16 调用一致）。

> 已知实现期需对真实 API 适配的点（已在对应步骤显式标注、不阻塞计划）：SwiftDraw `SVG`/`rasterize` 精确签名（Task 1 spike 锁定）、`MarkdownLabelView` 既有 inline 渲染方法/参数名与图片加载触发点（Task 8/11 以文件实际为准接线，语义不变）。
