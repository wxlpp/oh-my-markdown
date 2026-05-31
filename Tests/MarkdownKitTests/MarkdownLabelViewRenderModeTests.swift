@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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

    /// 不直接 inspect 私有 `_cachedRenderer`——通过 mode 字段的最终一致性旁证：
    /// static → streaming → static 的链路必须真的把 renderMode 写到 `.static`，
    /// 而非粘在 `.streaming`。`_cachedRenderer` 失效由 `didSet` 在 mode 真正翻转
    /// 时清掉；下次 `cachedRenderer` 取值会用新 mode 构造 `AttributedStringRenderer`。
    /// 端到端的「下次 render 用新 mode」由既有 SVGBlockViewWiringTests +
    /// StreamingSVGBlockCacheSurvivesRendererRecreationTests 的 streaming-miss
    /// regression 套件兜底——一旦透传链路断掉，那边会立刻变红。
    /// Soft test: contract = mode toggles invalidate cached renderer; the
    /// streaming-miss regression suites catch any wiring breakage.
    @Test func renderModeToggleInvalidatesCachedRenderer() {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.setMarkdown("```svg\n<svg viewBox=\"0 0 10 6\"/>\n```")
        #expect(view.renderMode == .static)
        view.appendMarkdown("\n\nmore")
        #expect(view.renderMode == .streaming)
        view.setMarkdown("again")
        #expect(view.renderMode == .static)
    }
}
