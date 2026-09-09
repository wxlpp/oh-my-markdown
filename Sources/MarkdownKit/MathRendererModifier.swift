import MarkdownRenderKit
import SwiftUI

extension EnvironmentValues {
    @Entry public var markdownMathRenderer: MathRendererConfiguration?
}

extension View {
    /// 注入数学渲染器；未调用则公式降级为原始 LaTeX 文本。
    /// 参数可选：传 `nil` 即在运行时禁用 math（与可选 env 一致），
    /// 无需为开关 math 而 branch 视图树。
    ///
    /// Pass `nil` to disable math at runtime without branching the view tree.
    public func mathRenderer(_ renderer: MathRendererConfiguration?) -> some View {
        environment(\.markdownMathRenderer, renderer)
    }
}
