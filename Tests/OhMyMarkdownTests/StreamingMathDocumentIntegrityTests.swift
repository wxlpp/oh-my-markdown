@testable import MarkdownCore
import Testing

/// Bug 1 真根因守卫（第 2 层，忠实 Example 文档结构守卫）。
///
/// 用与 Example StreamTab 完全一致的 `streamTokens` 文本（含 9 列宽表的
/// 裸价格列 `$5.00 / $3.00 / $3.50`、`## 适用场景`、` ```swift ` 代码块、
/// 行内高斯求和公式、块级 `$$e^{i\pi}+1=0$$`），经忠实 Example 解析路径
/// （`MarkdownDocument(parsing:)` 全量 + 逐 2-char token `parsingAppend`
/// 流式两路）断言文档结构未被贪婪 `$…$` 误配损坏。
///
/// 修复前：宽表价格列裸 `$` 被当行内数学定界符、与真实公式开界 `$`
/// 误配，吞掉代码块 + 标题 + 表行成伪 `.math`，真实公式降级纯文本（设备
/// 「公式坏掉 + 竖线混到一起」两症状同此一根因）。
///
/// 预期值依据：判决性对照（把 `$5.00/$3.00/$3.50` 中性化为非 `$` 文本）
/// 实测得 block count==29、inlineMath==1、blockMath==1、宽表 cols=9 rows=5、
/// 窄表 cols=3 rows=5；本守卫保留裸 `$` 原文，pandoc 规则下应得同一结构。
@Suite("Streaming math document integrity (Bug 1)")
@MainActor
struct StreamingMathDocumentIntegrityTests {
    /// 与 Example/Sources/ContentView.swift StreamTab 完全一致的源文本。
    /// raw 多行字面量（自定义 `#"""…"""#` 定界符）：LaTeX 反斜杠与裸 `$`
    /// 均无需转义，内容逐字节忠实。
    private static let streamText = #"""
    # 流式输出演示

    这段文字模拟了大语言模型 **逐 token** 输出的场景，覆盖了 OhMyMarkdown 支持的各类语法元素。

    ## 工作原理

    每次收到新的文本 chunk，解析器会重新解析**整个累积字符串**，然后与上一次的块列表做 diff，只更新发生变化的区块，从而实现无闪烁的流式渲染。

    ```swift
    // 核心增量渲染逻辑
    public func appendMarkdown(_ chunk: String) {
        streamingSource += chunk
        _parseTask?.cancel()          // 丢弃上一次未完成的解析
        _parseTask = Task {
            let newBlocks = await Task.detached(priority: .userInitiated) {
                MarkdownDocument(parsing: streamingSource).blocks
            }.value
            applyBlocks(newBlocks,
                        prevBlocks: prevBlocks,
                        prevStarts: prevStarts)
        }
    }
    ```

    ## 特性验证

    - [x] 增量渲染，无闪烁
    - [x] 标题实时出现，字体权重正确
    - [x] 代码块逐字显示，背景不跳动
    - [x] 表格实时建立，列宽稳定
    - [x] 引用块、列表、分割线
    - [ ] 代码语法高亮（规划中）
    - [ ] 图片内联（规划中）

    ## 流式表格（窄）

    | 阶段 | 耗时 | 说明 |
    |------|-----:|------|
    | 解析 | ~0.3 ms | cmark 原生解析 |
    | 渲染 | ~0.5 ms | AttributedString 生成 |
    | 排版 | ~0.8 ms | TextKit 2 行片段 |
    | 绘制 | ~0.2 ms | Core Graphics |
    | **合计** | **~1.8 ms** | **60 fps 绰绰有余** |

    ## 流式表格（宽 — 测试横向滚动）

    | 模型 | 提供商 | 上下文窗口 | 输出速度 | 多模态 | 函数调用 | 流式 | 延迟 | 价格/1M tokens |
    |------|--------|:----------:|:--------:|:------:|:--------:|:----:|:----:|---------------:|
    | GPT-4o | OpenAI | 128 k | 快 | ✅ | ✅ | ✅ | 低 | $5.00 |
    | Claude 4 Sonnet | Anthropic | 200 k | 快 | ✅ | ✅ | ✅ | 低 | $3.00 |
    | Gemini 2.5 Pro | Google | 1 M | 中 | ✅ | ✅ | ✅ | 中 | $3.50 |
    | Llama 3.3 70B | Meta | 128 k | 快 | ❌ | ✅ | ✅ | 低 | 开源 |
    | Qwen 2.5 72B | Alibaba | 128 k | 快 | ✅ | ✅ | ✅ | 低 | 开源 |

    ## 适用场景

    1. **ChatGPT / Claude** 等 LLM 接口的实时响应展示
    2. **代码补全**预览，支持语法块渐进显示
    3. **文档生成**工具，边生成边预览
    4. 任何需要**渐进式文字展示**的场合

    ## 代码示例 — SwiftUI 集成

    ```swift
    struct ChatView: View {
        @State private var markdown = ""

        var body: some View {
            ScrollView {
                MarkdownText(markdown)
                    .padding()
            }
            .task {
                // 模拟流式接收
                for try await token in llmStream {
                    markdown += token
                }
            }
        }
    }
    ```

    ## 数学公式（流式）

    流式场景下数学公式同样增量渲染。行内：高斯求和 $1+2+\dots+n=\frac{n(n+1)}{2}$。块级：

    $$e^{i\pi}+1=0$$

    ## 引用块测试

    > **TextKit 2** 是苹果在 WWDC 2021 推出的全新文字排版引擎，以 `NSTextLayoutManager` 为核心。
    >
    > 相比 TextKit 1，它提供了更精确的行片段布局、原生 RTL 支持以及更高效的懒加载渲染。
    >
    > > 嵌套引用：`NSTextLayoutFragment` 是 TextKit 2 的最小布局单元，
    > > 每个段落、列表项、代码块都对应一个 fragment。
    > >
    > > > 三层嵌套：fragment 内部通过 `NSTextLineFragment` 表示单行，
    > > > 支持跨行的连字（ligature）与双向文字（bidi）。

    ## 嵌套列表

    - **解析层**
      - `MarkdownParser` — 调用 swift-markdown，输出 `[BlockNode]`
      - `BlockNode` — 统一的中间表示，与平台无关
        - `.paragraph`, `.heading`, `.codeBlock`, `.table`…
    - **渲染层**
      - `MaterializationFixture` — 值类型，线程安全
        - 接收 `availableWidth`，内联计算 tab stops
        - 溢出表格：文字置透明，写入 `.markdownTableNaturalWidth`
    - **显示层**
      - `MarkdownLabelView` — 平台视图（UIView / NSView）
        - TextKit 2 直接驱动，无中间层
        - 溢出表格由 `_syncTableOverlays()` 注入独立 ScrollView

    ---

    ## 性能指标

    在 iPhone 15 Pro 上，渲染 **500 行** Markdown（含表格、代码块、嵌套列表）：

    - 首次渲染：< **8 ms**
    - 流式追加（单 token）：< **2 ms**
    - 内存占用：< **4 MB**
    - CPU（持续流式）：< **3%**

    > 以上数据在 Release 模式、关闭 Instruments 附加的条件下测量。

    ---

    **流式输出完成！** 🎉 感谢体验 OhMyMarkdown。
    """#

    /// Example 把源文本按 2 个字符切 token。
    private static func twoCharTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let next = text.index(idx, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
            tokens.append(String(text[idx ..< next]))
            idx = next
        }
        return tokens
    }

    /// 递归统计 IR 中行内 `.math` 与块级 `.mathBlock` 数量。
    private static func countMath(_ blocks: [BlockNode]) -> (inline: Int, block: Int) {
        var inl = 0
        var blk = 0
        func walkInlines(_ ns: [InlineNode]) {
            for n in ns {
                switch n {
                case .math: inl += 1
                case .emphasis(let c), .strong(let c), .strikethrough(let c): walkInlines(c)
                case .link(_, _, let c): walkInlines(c)
                default: break
                }
            }
        }
        func walk(_ bs: [BlockNode]) {
            for b in bs {
                switch b {
                case .mathBlock: blk += 1
                case .paragraph(let i), .heading(_, let i): walkInlines(i)
                case .blockquote(let inner): walk(inner)
                case .bulletList(let items), .orderedList(_, let items):
                    for it in items {
                        walk(it.blocks)
                    }
                case .table(_, let head, let rows):
                    for c in head {
                        walkInlines(c.content)
                    }
                    for r in rows {
                        for c in r {
                            walkInlines(c.content)
                        }
                    }
                default: break
                }
            }
        }
        walk(blocks)
        return (inl, blk)
    }

    private static func headingTexts(_ blocks: [BlockNode]) -> [String] {
        blocks.compactMap { b -> String? in
            guard case .heading(_, let ins) = b else { return nil }
            return ins.compactMap { if case .text(let s) = $0 { s } else { nil } }.joined()
        }
    }

    private static func wideTable(_ blocks: [BlockNode]) -> (cols: Int, rows: Int)? {
        for b in blocks {
            if case .table(let c, _, let rows) = b, c.count == 9 { return (c.count, rows.count) }
        }
        return nil
    }

    private static func narrowTable(_ blocks: [BlockNode]) -> (cols: Int, rows: Int)? {
        for b in blocks {
            if case .table(let c, _, let rows) = b, c.count == 3 { return (c.count, rows.count) }
        }
        return nil
    }

    /// 宽 9 列表所有单元格的纯文本拼接（含定界符的字面 `$`）。
    /// 直接探 IR 而非渲染串：宽表在窄宽度下会塌成 overflow 占位符（文字置空），
    /// 渲染串不含单元格文本——但 IR 单元格内容必须保留字面 `$5.00` 等，
    /// 这才是「裸 `$` 未被当数学定界符吞掉」的判决性断言。
    private static func wideTableCellText(_ blocks: [BlockNode]) -> String {
        func inlineText(_ ns: [InlineNode]) -> String {
            ns.map { n -> String in
                switch n {
                case .text(let s): return s
                case .math(let l): return "\u{0}MATH(\(l))\u{0}" // 进 IR 的伪 math 会带哨兵，便于失败定位
                case .emphasis(let c), .strong(let c), .strikethrough(let c): return inlineText(c)
                case .link(_, _, let c): return inlineText(c)
                case .inlineCode(let c): return c
                default: return ""
                }
            }.joined()
        }
        for b in blocks {
            guard case .table(let c, let head, let rows) = b, c.count == 9 else { continue }
            var out = head.map { inlineText($0.content) }.joined(separator: "|")
            for r in rows {
                out += "\n" + r.map { inlineText($0.content) }.joined(separator: "|")
            }
            return out
        }
        return ""
    }

    private func assertHealthy(_ blocks: [BlockNode], _ label: String) {
        let m = Self.countMath(blocks)
        #expect(blocks.count == 29, "[\(label)] block count: got \(blocks.count), expected 29 (control baseline)")
        #expect(m.inline == 1, "[\(label)] inlineMath: got \(m.inline), expected 1 (gauss sum)")
        #expect(m.block == 1, "[\(label)] blockMath: got \(m.block), expected 1 (e^{ipi}+1=0)")
        if let w = Self.wideTable(blocks) {
            #expect(w.rows == 5, "[\(label)] wide 9-col table rows: got \(w.rows), expected 5")
        } else {
            Issue.record("[\(label)] wide 9-col table missing (swallowed into pseudo-math)")
        }
        if let n = Self.narrowTable(blocks) {
            #expect(n.cols == 3 && n.rows == 5, "[\(label)] narrow table cols/rows: \(n)")
        } else {
            Issue.record("[\(label)] narrow 3-col table missing")
        }
        let hs = Self.headingTexts(blocks)
        #expect(hs.contains("适用场景"), "[\(label)] '## 适用场景' heading swallowed")
        #expect(hs.contains("代码示例 — SwiftUI 集成"), "[\(label)] '## 代码示例' heading swallowed")
        #expect(hs.contains("数学公式（流式）"), "[\(label)] '## 数学公式' heading swallowed")
        let codeBlocks = blocks.compactMap {
            if case .codeBlock(_, let body) = $0 { body } else { nil as String? }
        }
        #expect(codeBlocks.count == 2, "[\(label)] expected 2 fenced code blocks, got \(codeBlocks.count)")
        // 裸价格列 `$` 必须以字面文本保留在宽表单元格 IR（未被当数学定界符吞掉，
        // 也未降级成单元格内伪 `.math`）。
        let cells = Self.wideTableCellText(blocks)
        #expect(cells.contains("$5.00"), "[\(label)] literal $5.00 not kept in wide-table cell IR")
        #expect(cells.contains("$3.00"), "[\(label)] literal $3.00 not kept in wide-table cell IR")
        #expect(cells.contains("$3.50"), "[\(label)] literal $3.50 not kept in wide-table cell IR")
        #expect(!cells.contains("MATH("), "[\(label)] wide-table cell contains pseudo .math (bare $ mis-paired)")
        // 真实块级公式去定界符进 IR（不残留字面 $$）。
        let hasEuler = blocks.contains {
            if case .mathBlock(let l) = $0 { l == "e^{i\\pi}+1=0" } else { false }
        }
        #expect(hasEuler, "[\(label)] block math e^{i\\pi}+1=0 not a clean mathBlock")
    }

    @Test("忠实 Example 全量解析 MarkdownDocument(parsing:) 文档结构未损坏")
    func oneShotParseIntact() {
        let blocks = MarkdownDocument(parsing: Self.streamText).blocks
        self.assertHealthy(blocks, "one-shot")
    }

    @Test("忠实 Example 流式 parsingAppend 逐 2-char token 文档结构未损坏")
    func streamingAppendIntact() {
        let tokens = Self.twoCharTokens(Self.streamText)
        var src = ""
        var prev = ""
        var doc = MarkdownDocument(parsedBlocks: [])
        for t in tokens {
            src += t
            doc = MarkdownDocument(parsedBlocks: doc.parsedBlocks)
                .parsingAppend(to: src, previousSource: prev)
            prev = src
        }
        self.assertHealthy(doc.blocks, "streamed")
    }
}

/// Bug 1 真根因守卫的衍生守卫：`previousSourceHasOpenMathDelimiter` 收窄到
/// reparse 尾窗后，必须同时满足两条不变量——
/// 1. **正确性不回归**：尾窗内确有未闭合开界符时仍强制全量（append 闭合它
///    应与全量逐块一致），收窄没重开跨界 math 损坏；
/// 2. **perf 真收窄**：中段稳定 `$5.00`（其后有空行/块边界、再有更多内容）
///    在尾窗判定下返回 false（旧全篇扫描会 true），即含字面 `$` 文档流式
///    不再每 token 全量 = 消除 O(n²)。
@Suite("Open math delimiter narrowed to reparse tail window (Bug 1 perf)")
@MainActor
struct OpenMathDelimiterTailWindowTests {
    /// 守卫 1（correctness）：尾窗内真·未闭合 `$x`，append 一个 `$` 应闭合
    /// 成 math。收窄后该真开界仍被 detect → 强制全量，结果与全量逐块一致。
    @Test("尾窗内真未闭合开界符仍正确强制全量（与全量逐块一致，不漏）")
    func tailWindowOpenDelimiterStillForcesFullParse() {
        // previousSource 末块（尾窗内）含未闭合 `$x`（无闭合 $）。
        let previousSource = """
        # Title

        Stable paragraph with no math at all.

        Tail paragraph opening math $x
        """
        // append 一个 `$` 把尾窗内的 `$x` 闭合成行内 math。
        let newSource = previousSource + "+1$ done."

        let previous = MarkdownDocument(parsing: previousSource)
        let incremental = previous.parsingAppend(to: newSource, previousSource: previousSource)
        let full = MarkdownDocument(parsing: newSource)

        // 收窄后尾窗确有未闭合 `$` → 谓词须仍返回 true（强制全量）。
        let reparseStart = previous.tailReparseStartIndexForTest()
        #expect(
            MarkdownDocument.previousSourceHasOpenMathDelimiter(
                previousSource, fromReparseBoundary: reparseStart
            ),
            "tail-window open `$x` must still be detected → force full parse"
        )
        // 增量路径结果与全量逐块一致（跨界 math 未被收窄重开损坏）。
        #expect(
            incremental.blocks == full.blocks,
            "incremental must match full parse when tail window has open delimiter"
        )
        // 闭合后应得 1 个行内 math（`x+1`）。
        var inlineMath = 0
        func walkInlines(_ ns: [InlineNode]) {
            for n in ns {
                switch n {
                case .math: inlineMath += 1
                case .emphasis(let c), .strong(let c), .strikethrough(let c): walkInlines(c)
                case .link(_, _, let c): walkInlines(c)
                default: break
                }
            }
        }
        for b in full.blocks {
            if case .paragraph(let i) = b { walkInlines(i) }
            if case .heading(_, let i) = b { walkInlines(i) }
        }
        #expect(inlineMath == 1, "closed `$x+1$` should be exactly 1 inline math, got \(inlineMath)")
    }

    /// 守卫 2（perf）：中段稳定 `$5.00`，其后空行 + 块边界 + 更多内容。
    /// reparse 尾窗起点落在中段 `$5.00` 之后；旧全篇扫描会因这枚字面 `$`
    /// 返回 true（每 token 全量 = O(n²)），收窄后尾窗内无未闭合开界符 →
    /// false，走增量路径。
    @Test("中段稳定 $5.00 在尾窗判定下为 false（不再每 token 全量），增量与全量一致")
    func midDocumentLiteralDollarNoLongerForcesFullParse() throws {
        // 中段：含字面 `$5.00` 的稳定段落，其后有空行（段落边界）与多段内容。
        let previousSource = """
        # Pricing

        The cost is $5.00 for the basic tier.

        ## Details

        Some stable explanatory paragraph here.

        Another stable paragraph that has settled.
        """
        let newSource = previousSource + "\n\nFinal appended paragraph."

        let previous = MarkdownDocument(parsing: previousSource)
        let reparseStart = previous.tailReparseStartIndexForTest()

        // 旧全篇扫描（fromReparseBoundary: 0）会因中段字面 `$5.00` → true。
        #expect(
            MarkdownDocument.previousSourceHasOpenMathDelimiter(previousSource, fromReparseBoundary: 0),
            "whole-source scan returns true on mid-document literal $5.00 (old O(n^2) behavior)"
        )
        // 收窄后：reparse 尾窗起点 > 中段 `$5.00` 偏移 → 尾窗内无开界符 → false。
        let dollarByteOffset = try #require(Array(previousSource.utf8).firstIndex(of: 0x24))
        #expect(
            reparseStart > dollarByteOffset,
            "reparse boundary (\(reparseStart)) must be past mid-document $ (\(dollarByteOffset))"
        )
        #expect(
            !MarkdownDocument.previousSourceHasOpenMathDelimiter(
                previousSource, fromReparseBoundary: reparseStart
            ),
            "narrowed tail-window predicate must be false for stable mid-document $5.00 (no per-token full reparse → O(n) not O(n^2))"
        )
        // 谓词 false → 走增量路径；增量结果仍与全量逐块一致。
        let incremental = previous.parsingAppend(to: newSource, previousSource: previousSource)
        let full = MarkdownDocument(parsing: newSource)
        #expect(
            incremental.blocks == full.blocks,
            "incremental path (taken because predicate false) must still match full parse"
        )
    }
}

/// 测试专用：复算 `parsingAppend` 内部用的 reparse 边界 UTF-8 字节偏移
/// （`tailReparseStartIndex()` → `reparseBlock.sourceRange?.lowerBound ??
/// tailRange.lowerBound`），与生产口径完全一致（同一 internal 方法）。
extension MarkdownDocument {
    func tailReparseStartIndexForTest() -> Int {
        guard let tail = parsedBlocks.last, let tailRange = tail.sourceRange else { return 0 }
        let idx = self.tailReparseStartIndex()
        return self.parsedBlocks[idx].sourceRange?.lowerBound ?? tailRange.lowerBound
    }
}
