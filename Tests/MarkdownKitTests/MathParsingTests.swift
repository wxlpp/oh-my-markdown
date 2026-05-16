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
        // 收集整棵 IR 里所有 InlineNode，断言：无任何 .html 含 U+10FE02 哨兵；至少出现一个 .math。
        func inlines(_ b: BlockNode) -> [InlineNode] {
            switch b {
            case .paragraph(let n), .heading(_, let n): return n.flatMap(flatten)
            case .blockquote(let bs): return bs.flatMap(inlines)
            case .bulletList(let items), .orderedList(_, let items):
                return items.flatMap { $0.blocks.flatMap(inlines) }
            case .table(_, let head, let rows):
                return head.flatMap { $0.content.flatMap(flatten) }
                    + rows.flatMap { $0.flatMap { $0.content.flatMap(flatten) } }
            default: return []
            }
        }
        func flatten(_ n: InlineNode) -> [InlineNode] {
            switch n {
            case .emphasis(let c), .strong(let c), .strikethrough(let c): return [n] + c.flatMap(flatten)
            case .link(_, _, let c): return [n] + c.flatMap(flatten)
            default: return [n]
            }
        }
        for doc in docs {
            let all = doc.blocks.flatMap(inlines)
            let hasSentinelHTML = all.contains { if case .html(let s) = $0 { return s.unicodeScalars.contains("\u{10FE02}") } else { return false } }
            #expect(!hasSentinelHTML)
            let hasMath = all.contains { if case .math = $0 { return true } else { return false } }
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
