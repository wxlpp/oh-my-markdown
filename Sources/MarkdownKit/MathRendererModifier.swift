import SwiftUI
import MarkdownRenderKit

private struct MarkdownMathRendererKey: EnvironmentKey {
    static let defaultValue: (any MathRendering)? = nil
}

extension EnvironmentValues {
    public var markdownMathRenderer: (any MathRendering)? {
        get { self[MarkdownMathRendererKey.self] }
        set { self[MarkdownMathRendererKey.self] = newValue }
    }
}

extension View {
    /// 注入数学渲染器；未调用则公式降级为原始 LaTeX 文本。
    public func mathRenderer(_ renderer: any MathRendering) -> some View {
        environment(\.markdownMathRenderer, renderer)
    }
}
