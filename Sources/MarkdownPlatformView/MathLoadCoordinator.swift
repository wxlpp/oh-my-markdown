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
    private var tasks: [MathCacheKey: Task<Void, Never>] = [:]

    // spec §6：缓存设上限，避免流式长对话内存膨胀。
    // positive：LRU（lruOrder 末尾 = 最近使用）；negative：计数封顶后整体清空。
    private let positiveCap = 256
    private let negativeCap = 1024
    private var lruOrder: [MathCacheKey] = []

    /// 记录某 key 为最近使用：从 lruOrder 移除旧位置后追加到末尾。
    private func touchLRU(_ key: MathCacheKey) {
        if let idx = lruOrder.firstIndex(of: key) { lruOrder.remove(at: idx) }
        lruOrder.append(key)
    }

    /// 设置/替换渲染器：代际自增并清正/负/loading（spec §6）。
    public func setRenderer(_ r: (any MathRendering)?) {
        renderer = r
        generation += 1
        positive.removeAll()
        negative.removeAll()
        inFlight.removeAll()
        tasks.removeAll()
        lruOrder.removeAll()
    }

    /// scale 变化时清缓存并由调用方用新 rasterScale 重建键。
    public func invalidateForScaleChange() {
        positive.removeAll(); negative.removeAll(); inFlight.removeAll()
        tasks.removeAll(); lruOrder.removeAll()
    }

    public func glyph(for key: MathCacheKey) -> MathRenderedGlyph? {
        guard let glyph = positive[key] else { return nil }
        touchLRU(key)
        return glyph
    }
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
        tasks[key] = task
        return true
    }

    private func finish(key: MathCacheKey, outcome: MathRenderOutcome) {
        inFlight.remove(key)
        tasks[key] = nil
        switch outcome {
        case .rendered(let glyph):
            // 注：被取代的 renderer/代际的迟到完成可能写入一个 key 携带旧
            // rendererGeneration 的条目；它永不会被读取（查找始终用当前代际），
            // 并由下面的 LRU 上限自然回收 —— 这是有意为之，勿"修复"。
            positive[key] = glyph
            touchLRU(key)
            if positive.count > positiveCap, let lru = lruOrder.first {
                positive[lru] = nil
                lruOrder.removeFirst()
            }
        case .failed:
            if negative.count >= negativeCap { negative.removeAll() }
            negative.insert(key)
        case .cancelled: break
        }
    }

    /// 测试辅助：等所有在途任务结束。
    /// 每个被等待的任务在其 finish 中会先移除自身的 tasks[key]，
    /// 故循环每次重读 tasks.first 时该项已消失，循环必然终止（确定性）。
    public func drain() async {
        while let entry = tasks.first {
            _ = await entry.value.value
        }
    }
}
