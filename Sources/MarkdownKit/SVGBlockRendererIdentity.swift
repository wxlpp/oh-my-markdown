import MarkdownRenderKit

// MARK: - SVG block renderer identity

/// SVG 块渲染器身份比较：集中一处，与 `isSameMathRenderer` 同形，避免
/// `MarkdownText` / `MarkdownStreamingText` 各自复制副本而身份语义漂移。
/// `internal` 可见性即够——同模块两文件直接调用，不对外暴露 API。
///
/// Single source of truth for ```svg renderer identity, shared by both
/// representables to prevent two private copies from drifting apart.
func isSameSVGBlockRenderer(_ a: (any SVGBlockRendering)?, _ b: (any SVGBlockRendering)?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    // SVGBlockRendering 约束 AnyObject，`===` 直接比较类实例身份、无装箱。
    case let (x?, y?): return x === y
    default: return false
    }
}
