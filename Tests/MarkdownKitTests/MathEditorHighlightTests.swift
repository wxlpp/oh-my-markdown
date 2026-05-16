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
        #expect(color(out, at: dollarIdx) == style.mathTokenColor)
        #expect(color(out, at: dollarIdx + 1) == style.mathTokenColor)  // span 内
        #expect(color(out, at: 0) != style.mathTokenColor)              // emoji 不着
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
