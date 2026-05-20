import SwiftUI
import MarkdownRenderKit

private struct MarkdownSVGBlockRendererKey: EnvironmentKey {
    static let defaultValue: (any SVGBlockRendering)? = nil
}

extension EnvironmentValues {
    public var markdownSVGBlockRenderer: (any SVGBlockRendering)? {
        get { self[MarkdownSVGBlockRendererKey.self] }
        set { self[MarkdownSVGBlockRendererKey.self] = newValue }
    }
}

extension View {
    /// 注入 ```svg 代码块渲染器；未调用则降级为高亮的源码块。
    /// 参数可选：传 `nil` 即在运行时禁用 svg 渲染（与可选 env 一致），
    /// 无需为开关 svg 而 branch 视图树。
    ///
    /// Pass `nil` to disable ```svg rendering at runtime without branching
    /// the view tree.
    public func svgRenderer(_ renderer: (any SVGBlockRendering)?) -> some View {
        environment(\.markdownSVGBlockRenderer, renderer)
    }
}
