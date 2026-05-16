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
