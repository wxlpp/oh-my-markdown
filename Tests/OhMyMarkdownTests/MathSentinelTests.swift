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
        let anchors = MathSentinel.anchorRanges(in: result.transformed)
        #expect(anchors.map(\.index) == [0, 1])
    }

    @Test("源码本身含保留标量时被转义、还原后字节级不变")
    func spoofingEscaped() {
        let evil = "text \u{10FE00}0\u{10FE00} pretending to be an anchor $z$ end"
        let spans = MathScanner.scan(evil)
        let result = MathSentinel.substitute(source: evil, spans: spans)
        #expect(result.table.count == 1)
        #expect(result.table[0].latex == "z")
        let anchors = MathSentinel.anchorRanges(in: result.transformed)
        #expect(anchors.count == 1)
        let restored = MathSentinel.unescapeReservedScalar(result.transformed)
        #expect(restored.contains("\u{10FE00}0\u{10FE00} pretending"))
    }

    @Test("形似 哨兵+数字+哨兵 但无对应旁路表项 → 不算锚")
    func lookalikeNotAnchor() {
        let s = "\u{10FE00}99\u{10FE00}"
        let escaped = MathSentinel.escapeReservedScalar(s)
        #expect(MathSentinel.anchorRanges(in: escaped).isEmpty)
    }

    @Test("escape∘unescape 在含 S/ESC 的对抗输入上是精确逆", arguments: [
        "a\u{10FE01}b",
        "\u{10FE00}\u{10FE01}",
        "\u{10FE01}\u{10FE00}",
        "x\u{10FE00}",
        "\u{10FE00}\u{10FE00}",
        "\u{10FE00}\u{10FE01}\u{10FE00}",
        "\u{10FE01}",
        "plain text no specials",
        "\u{10FE00}5\u{10FE00}",
    ])
    func escapeUnescapeRoundTrip(_ x: String) {
        let restored = MathSentinel.unescapeReservedScalar(MathSentinel.escapeReservedScalar(x))
        #expect(restored == x)
    }

    @Test("多位数索引锚（idx >= 10）可被定位")
    func multiDigitAnchor() {
        let s = "\u{10FE00}42\u{10FE00}"
        let anchors = MathSentinel.anchorRanges(in: s)
        #expect(anchors.map(\.index) == [42])
    }

    @Test("相邻公式 span 之间空切片不崩、锚连续")
    func adjacentSpans() {
        // 原 fixture `$x$$y$` 非 pandoc / remark-math 合规（两个 $…$ 之间
        // 无分隔，中段 `$$` 在 pandoc 语义下是块级定界符——仅旧贪婪扫描器
        // 才会把它拆成两个相邻行内 span）。本测试意图是钉 MathSentinel 对
        // 「两个零间隔相邻 span」的空切片/锚连续鲁棒性，与该畸形串无关。
        // 改用零间隔、无歧义的相邻 `\(a\)\(b\)`，同样产出两个紧邻 span。
        let src = "\\(a\\)\\(b\\)"
        let spans = MathScanner.scan(src)
        let result = MathSentinel.substitute(source: src, spans: spans)
        #expect(result.table.count == spans.count)
        let anchors = MathSentinel.anchorRanges(in: result.transformed)
        #expect(anchors.map(\.index) == Array(0 ..< result.table.count))
        #expect(!result.transformed.contains("$"))
    }
}
