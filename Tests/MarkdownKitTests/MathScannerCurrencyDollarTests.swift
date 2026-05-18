@testable import MarkdownCore
import Testing

/// Bug 1 真根因守卫（第 1 层，纯函数）。
///
/// 钉死 `MathScanner.scan` 行内 `$ … $` 的 pandoc / remark-math 定界符规则：
/// 开界 `$` 后非空白；闭界 `$` 前非空白且其后一字节非 ASCII 数字；行内
/// `$…$` 不跨段落空行。出处：pandoc Markdown `tex_math_dollars` 扩展
/// 与 remark-math。意图：货币写法（`$5.00` / `cost $5 vs $9`）不得被当
/// 行内数学定界符贪婪配对、吞掉其后真实公式与整段内容。
@Suite("MathScanner currency-$ pandoc rule")
struct MathScannerCurrencyDollarTests {
    private func spans(_ s: String) -> [MathSpan] { MathScanner.scan(s) }

    @Test("货币：两个裸 $ 不配对成数学")
    func currencyTwoBareDollars() {
        // `$5.00 and $3.00`：开界 `$5` 后非空白成候选，但唯一候选闭界
        // `$3` 前一字节是空白(空格) → 无合规闭界 → 全字面。
        #expect(spans("$5.00 and $3.00").isEmpty)
    }

    @Test("真实行内公式仍识别")
    func realInlineMathStillWorks() {
        let r = spans("$E=mc^2$")
        #expect(r.count == 1)
        #expect(r[0].latex == "E=mc^2")
        #expect(r[0].display == false)
    }

    @Test("空格内填充 $ x $ → 非数学（开界后空白 / 闭界前空白）")
    func spacePaddedNotMath() {
        #expect(spans("$ x $").isEmpty)
    }

    @Test("文本中嵌入 a $x$ b → 1 行内 span")
    func embeddedInlineMath() {
        let r = spans("a $x$ b")
        #expect(r.count == 1)
        #expect(r[0].latex == "x")
        #expect(r[0].display == false)
    }

    @Test("货币句 cost $5 vs $9 done → 非数学")
    func currencySentence() {
        // 闭界候选 `$9` 的 `$` 后一字节是数字 9 且前一字节是空白 → 不合规。
        #expect(spans("cost $5 vs $9 done").isEmpty)
    }

    @Test("行内 $…$ 不得跨段落空行 → 非数学")
    func noCrossBlankLine() {
        #expect(spans("$a\n\nb$").isEmpty)
    }

    @Test("单换行（非空行）不阻断行内公式")
    func singleNewlineAllowed() {
        let r = spans("$a\nb$")
        #expect(r.count == 1)
        #expect(r[0].latex == "a\nb" || r[0].latex == "a b" || r[0].latex.contains("a"))
        #expect(r[0].display == false)
    }

    @Test("块级 $$…$$ 规则不受影响")
    func blockUnaffected() {
        let r = spans("$$e^{i\\pi}+1=0$$")
        #expect(r.count == 1)
        #expect(r[0].display == true)
        #expect(r[0].latex == "e^{i\\pi}+1=0")
    }

    @Test("\\(…\\) / \\[…\\] 不受影响")
    func backslashUnaffected() {
        let r = spans("p \\(x\\) q \\[y\\] r")
        #expect(r.count == 2)
        #expect(r[0].latex == "x")
        #expect(r[0].display == false)
        #expect(r[1].latex == "y")
        #expect(r[1].display == true)
    }

    @Test("开界后接数字仍允许（$5x$ 数学可数字开头）")
    func openFollowedByDigitStillAllowed() {
        let r = spans("$5x$")
        #expect(r.count == 1)
        #expect(r[0].latex == "5x")
        #expect(r[0].display == false)
    }

    @Test("闭界 $ 前非空白且其后是标点（高斯求和真实公式）")
    func realGaussSum() {
        let r = spans("行内：高斯求和 $1+2+\\dots+n=\\frac{n(n+1)}{2}$。块级：")
        #expect(r.count == 1)
        #expect(r[0].latex == "1+2+\\dots+n=\\frac{n(n+1)}{2}")
        #expect(r[0].display == false)
    }
}
