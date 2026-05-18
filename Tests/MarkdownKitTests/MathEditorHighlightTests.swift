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
        #expect(color(out, at: 0) != style.mathTokenColor)
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

    @Test("emoji 前缀后的 $x^2$ 仍正确着 mathTokenColor（补充平面字符不破坏 offset）")
    func emojiPrefixMathColored() {
        let style = RenderStyle.default
        let h = MarkdownSourceHighlighter(style: style)
        let src = "🎉 $x^2$ done"
        let out = h.highlight(src)
        let dollarIdx = (src as NSString).range(of: "$x^2$").location   // 🎉=2 UTF-16 + space=1 → 3
        // 契约订正（非弱化，仿 round-1 fixture 订正先例）：mathTokenColor 文档/
        // README/命名均为「只 token-highlight 数学**定界符**」；旧 `dollarIdx+1`
        // （内容字符 `x`）== mathTokenColor 这一断言编码的是「整 span 着色」的
        // 旧错误期望。按既有契约：开界 `$`(dollarIdx) 与闭界 `$`(dollarIdx+4)
        // 着色，中间 LaTeX 内容（`x^2`，dollarIdx+1..+3）不着色。
        #expect(color(out, at: dollarIdx) == style.mathTokenColor)      // 开界 `$`
        #expect(color(out, at: dollarIdx + 1) != style.mathTokenColor)  // 内容 `x` 不着（定界符-only）
        #expect(color(out, at: dollarIdx + 4) == style.mathTokenColor)  // 闭界 `$`（$x^2$ 共 5 个 UTF-16）
        #expect(color(out, at: 0) != style.mathTokenColor)              // emoji 不着
        let spaceIdx = (src as NSString).range(of: " $x^2$").location  // emoji 后那个空格（NSString index=2）
        #expect(color(out, at: spaceIdx) != style.mathTokenColor)       // 空格不在公式区间——buggy 会误染，fixed 不染
    }

    @Test("CJK 前缀后的 $y$ 仍正确着色")
    func cjkPrefixMathColored() {
        let style = RenderStyle.default
        let h = MarkdownSourceHighlighter(style: style)
        let src = "汉字 $y$ 尾"
        let out = h.highlight(src)
        let idx = (src as NSString).range(of: "$y$").location
        #expect(color(out, at: idx) == style.mathTokenColor)
        #expect(color(out, at: 0) != style.mathTokenColor)
    }
}

/// PR #4 第 4 轮 Copilot review 改动 #2 守卫：editor 数学高亮收窄到定界符。
///
/// 根因：`applyMathHighlights` 曾把 `mathTokenColor` 涂到**整个** math span
/// （含 `$…$` / `\(…\)` 内的 LaTeX 内容），与公开命名 `mathTokenColor`
/// （doc「math **delimiter** tokens」）+ README「editor only token-highlights
/// the math **delimiters**」相悖。
///
/// 修复：仅对开定界符区间与闭定界符区间施 `mathTokenColor`，不涂中间 LaTeX
/// 内容。对四种定界符（`$…$` / `$$…$$` / `\(…\)` / `\[…\]`）均正确。
@Suite("Math editor highlight narrowed to delimiters (PR #4 round 4 change #2)")
struct MathEditorHighlightDelimiterScopeTests {
    private func color(_ s: NSAttributedString, at i: Int) -> PlatformColor? {
        s.attribute(.foregroundColor, at: i, effectiveRange: nil) as? PlatformColor
    }

    /// 对一个 `prefix + open + content + close + suffix` 形态的源，断言：
    /// 开界每个 UTF-16 位置着 mathTokenColor、闭界每个位置着色、中间 content
    /// 每个位置**不**着色。索引按纯 ASCII 前缀计算（UTF-16==字符数）。
    private func assertDelimiterScoped(
        open: String, content: String, close: String,
        line: UInt = #line
    ) {
        let style = RenderStyle.default
        let h = MarkdownSourceHighlighter(style: style)
        let prefix = "ab "
        let suffix = " cd"
        let src = prefix + open + content + close + suffix
        let out = h.highlight(src)
        let base = (prefix as NSString).length // 前缀纯 ASCII

        // 开界符每个 UTF-16 位置着色。
        for k in 0 ..< (open as NSString).length {
            #expect(
                color(out, at: base + k) == style.mathTokenColor,
                "open delimiter byte \(k) of \(open)…\(close) must be mathTokenColor"
            )
        }
        // 中间 LaTeX 内容**不**着色（定界符-only 契约）。
        let contentStart = base + (open as NSString).length
        for k in 0 ..< (content as NSString).length {
            #expect(
                color(out, at: contentStart + k) != style.mathTokenColor,
                "content char \(k) of \(open)\(content)\(close) must NOT be mathTokenColor (delimiter-only)"
            )
        }
        // 闭界符每个 UTF-16 位置着色。
        let closeStart = contentStart + (content as NSString).length
        for k in 0 ..< (close as NSString).length {
            #expect(
                color(out, at: closeStart + k) == style.mathTokenColor,
                "close delimiter byte \(k) of \(open)…\(close) must be mathTokenColor"
            )
        }
        // 前后散文不着色。
        #expect(color(out, at: 0) != style.mathTokenColor, "prefix prose must not be colored")
        #expect(
            color(out, at: closeStart + (close as NSString).length) != style.mathTokenColor,
            "suffix prose must not be colored"
        )
    }

    @Test("行内 $…$：开/闭 `$` 着色，内容不着")
    func inlineDollar() {
        self.assertDelimiterScoped(open: "$", content: "x^2", close: "$")
    }

    @Test("块级 $$…$$：开/闭 `$$` 着色，内容不着")
    func blockDollar() {
        self.assertDelimiterScoped(open: "$$", content: "E=mc^2", close: "$$")
    }

    @Test("行内 \\(…\\)：开 `\\(` / 闭 `\\)` 着色，内容不着")
    func inlineParen() {
        self.assertDelimiterScoped(open: #"\("#, content: "a+b", close: #"\)"#)
    }

    @Test("块级 \\[…\\]：开 `\\[` / 闭 `\\]` 着色，内容不着")
    func blockBracket() {
        self.assertDelimiterScoped(open: #"\["#, content: "x=1", close: #"\]"#)
    }
}
