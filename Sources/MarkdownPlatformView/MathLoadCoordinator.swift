import Foundation
import MarkdownRenderKit

/// 平台无关的数学渲染协调器：去重派发、三态分派、负缓存、代际失效。
/// 由平台视图持有；视图负责枚举 .markdownMathSource 并在完成回调里 setNeedsLayout/重渲染。
public actor MathLoadCoordinator {
    public init() {}

    private var renderer: (any MathRendering)?
    public private(set) var generation: Int = 0

    private var positive: [MathCacheKey: MathRenderedGlyph] = [:]
    private var negative: Set<MathCacheKey> = []
    private var inFlight: Set<MathCacheKey> = []
    private var tasks: [Task<Void, Never>] = []

    /// 设置/替换渲染器：代际自增并清正/负/loading（spec §6）。
    public func setRenderer(_ r: (any MathRendering)?) {
        renderer = r
        generation += 1
        positive.removeAll()
        negative.removeAll()
        inFlight.removeAll()
    }

    /// scale 变化时清缓存并由调用方用新 rasterScale 重建键。
    public func invalidateForScaleChange() {
        positive.removeAll(); negative.removeAll(); inFlight.removeAll()
    }

    public func glyph(for key: MathCacheKey) -> MathRenderedGlyph? { positive[key] }
    public func isNegativeCached(_ key: MathCacheKey) -> Bool { negative.contains(key) }

    /// 需要时派发渲染。返回是否真的派发了任务（用于测试与去抖）。
    @discardableResult
    public func loadIfNeeded(
        key: MathCacheKey, latex: String, display: Bool,
        pointSize: CGFloat, scale: CGFloat, color: PlatformColor
    ) -> Bool {
        guard let renderer else { return false }
        if positive[key] != nil || negative.contains(key) || inFlight.contains(key) { return false }
        inFlight.insert(key)
        let task = Task { [weak self] in
            let outcome = await renderer.render(
                latex: latex, display: display, pointSize: pointSize, scale: scale, color: color)
            await self?.finish(key: key, outcome: outcome)
        }
        tasks.append(task)
        return true
    }

    private func finish(key: MathCacheKey, outcome: MathRenderOutcome) {
        inFlight.remove(key)
        switch outcome {
        case .rendered(let glyph): positive[key] = glyph
        case .failed: negative.insert(key)
        case .cancelled: break
        }
    }

    /// 测试辅助：等所有在途任务结束。
    public func drain() async {
        let snapshot = tasks
        tasks.removeAll()
        for t in snapshot { _ = await t.value }
    }
}
