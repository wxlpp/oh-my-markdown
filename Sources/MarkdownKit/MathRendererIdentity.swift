import MarkdownRenderKit

// MARK: - Math renderer identity

/// 数学渲染器身份比较：集中一处，消除两个 representable
/// （`MarkdownText` / `MarkdownStreamingText`）各自维护副本而产生
/// 身份语义漂移的风险。`internal` 可见性即够——同模块两文件直接调用，
/// 不对外暴露 API。逻辑与 round-1 的 `x === y` 身份语义逐字节一致。
/// (Copilot PR #4 R5 #1/#2)
///
/// Single source of truth for math-renderer identity, shared by both
/// representables to prevent the two private copies from drifting apart.
func isSameMathRenderer(_ a: (any MathRendering)?, _ b: (any MathRendering)?) -> Bool {
    switch (a, b) {
    case (nil, nil): true
    // MathRendering 现已约束 AnyObject，`===` 直接比较类实例身份、无装箱。
    case (let x?, let y?): x === y
    default: false
    }
}
