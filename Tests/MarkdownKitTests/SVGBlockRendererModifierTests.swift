@testable import MarkdownKit
@testable import MarkdownRenderKit
import SwiftUI
import Testing

private final class StubSVGRenderer: SVGBlockRendering, @unchecked Sendable {
    func render(svg _: String, availableWidth _: CGFloat, scale _: CGFloat) async -> SVGBlockOutcome {
        .failed
    }
}

@Suite("svgRenderer modifier + identity")
@MainActor
struct SVGBlockRendererModifierTests {
    @Test("env 默认 nil；具体值往返；nil 清空")
    func envRoundTrip() {
        var env = EnvironmentValues()
        #expect(env.markdownSVGBlockRenderer == nil)
        let r = SVGRendererConfiguration(renderer: StubSVGRenderer())
        env.markdownSVGBlockRenderer = r
        #expect(env.markdownSVGBlockRenderer?.configurationID == r.configurationID)
        env.markdownSVGBlockRenderer = nil
        #expect(env.markdownSVGBlockRenderer == nil)
    }

    @Test("isSameSVGBlockRenderer：nil/nil true；one-nil false；同实例 true；异实例 false")
    func identitySemantics() {
        let a = SVGRendererConfiguration(renderer: StubSVGRenderer()); let b = SVGRendererConfiguration(renderer: StubSVGRenderer())
        #expect(isSameSVGBlockRenderer(nil, nil))
        #expect(!isSameSVGBlockRenderer(a, nil))
        #expect(!isSameSVGBlockRenderer(nil, b))
        #expect(isSameSVGBlockRenderer(a, a))
        #expect(!isSameSVGBlockRenderer(a, b))
    }

    @Test("修饰符接受具体与 nil（编译 + 运行时禁用）")
    func modifierAcceptsOptional() {
        _ = Text("x").svgRenderer(SVGRendererConfiguration(renderer: StubSVGRenderer()))
        _ = Text("x").svgRenderer(nil) // 非可选签名会在此编译失败 —— git-反证锚点
    }
}
