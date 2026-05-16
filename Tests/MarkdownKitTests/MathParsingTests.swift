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
        #expect(doc.blocks.count == 1)
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
        let joined = inlines.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
        #expect(joined.contains("\u{10FE00}0\u{10FE00}"))
    }

    @Test("emphasis/strong/link 内的块定界符降级为行内 math，且 IR 不残留哨兵")
    func blockMathNestedInInlineDegrades() {
        let docs = [
            MarkdownDocument(parsing: "*pre $$x$$ post*"),
            MarkdownDocument(parsing: "**bold $$bx$$ tail**"),
            MarkdownDocument(parsing: "[txt $$lx$$](https://e.com)"),
            MarkdownDocument(parsing: "*$$only$$*"),
        ]
        /// 收集整棵 IR 里所有 InlineNode，断言：无任何 .html 含 U+10FE02 哨兵；至少出现一个 .math。
        func inlines(_ b: BlockNode) -> [InlineNode] {
            switch b {
            case .paragraph(let n), .heading(_, let n): n.flatMap(flatten)
            case .blockquote(let bs): bs.flatMap(inlines)
            case .bulletList(let items), .orderedList(_, let items):
                items.flatMap { $0.blocks.flatMap(inlines) }
            case .table(_, let head, let rows):
                head.flatMap { $0.content.flatMap(flatten) }
                    + rows.flatMap { $0.flatMap { $0.content.flatMap(flatten) } }
            default: []
            }
        }
        func flatten(_ n: InlineNode) -> [InlineNode] {
            switch n {
            case .emphasis(let c), .strong(let c), .strikethrough(let c): [n] + c.flatMap(flatten)
            case .link(_, _, let c): [n] + c.flatMap(flatten)
            default: [n]
            }
        }
        for doc in docs {
            let all = doc.blocks.flatMap(inlines)
            let hasSentinelHTML = all.contains { if case .html(let s) = $0 { s.unicodeScalars.contains("\u{10FE02}") } else { false } }
            #expect(!hasSentinelHTML)
            let hasMath = all.contains { if case .math = $0 { true } else { false } }
            #expect(hasMath)
        }
    }
}

@Suite("Math code-block integrity")
struct MathCodeBlockIntegrityTests {
    @Test("* * * 主题分隔线后的缩进代码块不被当公式（Task 3 遗留修复）")
    func thematicBreakThenIndentedCode() {
        let doc = MarkdownDocument(parsing: "text\n\n* * *\n\n    code with $x$ inside\n")
        /// 不应产生任何 math / mathBlock 节点；代码块原文（含 $x$）保持。
        func hasMath(_ b: BlockNode) -> Bool {
            switch b {
            case .mathBlock: true
            case .paragraph(let ns), .heading(_, let ns): ns.contains { if case .math = $0 { true } else { false } }
            case .blockquote(let bs): bs.contains(where: hasMath)
            case .bulletList(let items), .orderedList(_, let items): items.contains { $0.blocks.contains(where: hasMath) }
            default: false
            }
        }
        #expect(!doc.blocks.contains(where: hasMath))
        let joined = doc.blocks.compactMap { if case .codeBlock(_, let body) = $0 { body } else { nil } }.joined()
        #expect(joined.contains("$x$"))
    }
}

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

    @Test("跨保留块的 \\[ \\] 流式追加，增量 == 全量")
    func crossBlockBracketStreaming() {
        let prev = "intro\n\n\\[\n\\frac{a}{b}\n"
        let next = prev + "\\frac{c}{d}\n\\]\n\ntail"
        let incremental = MarkdownDocument(parsing: prev).parsingAppend(to: next, previousSource: prev)
        #expect(incremental.blocks == MarkdownDocument(parsing: next).blocks)
    }
}

@Suite("Math incremental sourceRange offset")
struct MathIncrementalSourceRangeTests {
    @Test("前置保留块含闭合行内公式后追加：增量 == 全量 (case 1)")
    func preservedBlockInlineMathThenAppend() {
        let prev = "para with $a$ inline\n\nlast para"
        let next = prev + " more"
        let inc = MarkdownDocument(parsing: prev).parsingAppend(to: next, previousSource: prev)
        #expect(inc.blocks == MarkdownDocument(parsing: next).blocks)
    }

    @Test("前置保留块含公式后追加块级公式：增量 == 全量 (case 2)")
    func preservedBlockInlineMathThenBlockAppend() {
        let prev = "done $a$ ok\n\npara two"
        let next = prev + "\n\n$$\nx"
        let inc = MarkdownDocument(parsing: prev).parsingAppend(to: next, previousSource: prev)
        #expect(inc.blocks == MarkdownDocument(parsing: next).blocks)
    }

    @Test("多个前置保留块各含公式后追加：增量 == 全量")
    func multiplePreservedMathBlocks() {
        let prev = "a $x$ one\n\nb $yy$ two\n\nc \\(z\\) three\n\ntail"
        let next = prev + " appended"
        let inc = MarkdownDocument(parsing: prev).parsingAppend(to: next, previousSource: prev)
        #expect(inc.blocks == MarkdownDocument(parsing: next).blocks)
    }

    @Test("无公式的前置块（回归保护，不得破坏既有增量）")
    func noMathPreservedStillIncrementalCorrect() {
        let prev = "# Title\n\nplain prefix paragraph\n\nlast"
        let next = prev + " more"
        let inc = MarkdownDocument(parsing: prev).parsingAppend(to: next, previousSource: prev)
        #expect(inc.blocks == MarkdownDocument(parsing: next).blocks)
    }
}
