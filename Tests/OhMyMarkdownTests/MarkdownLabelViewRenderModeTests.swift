import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing

@Suite("MarkdownLabelView renderMode tracking")
@MainActor
struct MarkdownLabelViewRenderModeTests {
    /// 构造后 view 处于 `.static` —— 空内容场景默认就是静态首屏。
    /// Newly constructed view starts in `.static`.
    @Test func initialRenderModeIsStatic() {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        #expect(view.renderMode == .static)
    }

    /// `setMarkdown` 之后无论之前是什么 mode 都翻 `.static`。
    /// setMarkdown always lands in `.static`.
    @Test func setMarkdownSetsRenderModeStatic() {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        view.appendMarkdown("foo")
        #expect(view.renderMode == .streaming)
        view.setMarkdown("bar")
        #expect(view.renderMode == .static)
    }

    /// `appendMarkdown` 之后无论之前是什么 mode 都翻 `.streaming`。
    /// appendMarkdown always lands in `.streaming`.
    @Test func appendMarkdownSetsRenderModeStreaming() {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        view.setMarkdown("foo")
        #expect(view.renderMode == .static)
        view.appendMarkdown(" bar")
        #expect(view.renderMode == .streaming)
    }

    /// 连续 setMarkdown 保持 `.static`（no-flip 路径不破坏）。
    /// Consecutive setMarkdown stays `.static`.
    @Test func consecutiveSetMarkdownStaysStatic() {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        view.setMarkdown("a")
        view.setMarkdown("b")
        #expect(view.renderMode == .static)
    }

    /// 连续 appendMarkdown 保持 `.streaming`（no-flip 路径不破坏）。
    /// Consecutive appendMarkdown stays `.streaming`.
    @Test func consecutiveAppendMarkdownStaysStreaming() {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        view.appendMarkdown("a")
        view.appendMarkdown(" b")
        #expect(view.renderMode == .streaming)
    }

    // 「mode 翻转后下次 render 用新 mode」由既有 streaming-miss regression suites
    // 兜底（SVGBlockViewWiringTests / StreamingSVGBlockCacheSurvivesRendererRecreationTests）：
    // 一旦 _cachedRenderer 失效或 placeholderMode 透传断掉，那边会立刻变红。
    // 因此这里不再单独写一个 toggle test——前面 5 个 mode-字段最终一致性测试 +
    // 端到端 regression 套件已经覆盖了完整链路。
}
