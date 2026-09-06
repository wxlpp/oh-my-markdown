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
        if let idx = lruOrder.firstIndex(of: key) { self.lruOrder.remove(at: idx) }
        self.lruOrder.append(key)
    }

    /// 设置/替换渲染器：代际自增并清正/负/loading（spec §6）。
    public func setRenderer(_ r: (any MathRendering)?) {
        self.renderer = r
        self.generation += 1
        self.positive.removeAll()
        self.negative.removeAll()
        self.inFlight.removeAll()
        self.tasks.removeAll()
        self.lruOrder.removeAll()
    }

    /// scale 变化时清缓存并由调用方用新 rasterScale 重建键。
    public func invalidateForScaleChange() {
        self.positive.removeAll(); self.negative.removeAll(); self.inFlight.removeAll()
        self.tasks.removeAll(); self.lruOrder.removeAll()
    }

    public func glyph(for key: MathCacheKey) -> MathRenderedGlyph? {
        guard let glyph = positive[key] else { return nil }
        self.touchLRU(key)
        return glyph
    }

    public func isNegativeCached(_ key: MathCacheKey) -> Bool {
        self.negative.contains(key)
    }

    /// 需要时派发渲染。返回是否真的派发了任务（用于测试与去抖）。
    @discardableResult
    public func loadIfNeeded(
        key: MathCacheKey, latex: String, display: Bool,
        pointSize: CGFloat, scale: CGFloat, color: PlatformColor
    ) -> Bool {
        guard let renderer else { return false }
        if self.positive[key] != nil || self.negative.contains(key) || self.inFlight.contains(key) { return false }
        self.inFlight.insert(key)
        let task = Task { [weak self] in
            let outcome = await renderer.render(
                latex: latex, display: display, pointSize: pointSize, scale: scale, color: color
            )
            await self?.finish(key: key, outcome: outcome)
        }
        self.tasks[key] = task
        return true
    }

    private func finish(key: MathCacheKey, outcome: MathRenderOutcome) {
        self.inFlight.remove(key)
        self.tasks[key] = nil
        switch outcome {
        case .rendered(let glyph):
            // 注：被取代的 renderer/代际的迟到完成可能写入一个 key 携带旧
            // rendererGeneration 的条目；它永不会被读取（查找始终用当前代际），
            // 并由下面的 LRU 上限自然回收 —— 这是有意为之，勿"修复"。
            self.positive[key] = glyph
            self.touchLRU(key)
            if self.positive.count > self.positiveCap, let lru = lruOrder.first {
                self.positive[lru] = nil
                self.lruOrder.removeFirst()
            }
        case .failed:
            if self.negative.count >= self.negativeCap { self.negative.removeAll() }
            self.negative.insert(key)
        case .cancelled: break
        }
    }

    /// Await just this key's in-flight render task (if any) then return its glyph.
    /// Production-safe alternative to `drain()` (which is test-only, awaits ALL tasks).
    public func awaitGlyph(for key: MathCacheKey) async -> MathRenderedGlyph? {
        if let t = tasks[key] { _ = await t.value }
        return self.glyph(for: key)
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

extension MathLoadCoordinator {
    /// 进程级共享实例（**opt-in**）。MarkdownLabelView **默认不使用**——每个 view
    /// 仍持有自己的 `init()` 实例以保证测试隔离。需要跨 view cache 的调用方可在
    /// 装配处显式接入。约束同 `SVGBlockLoadCoordinator.shared`：共用此实例的调用
    /// 方应保证全 process 用同一个 MathRendering，否则 setRenderer 会反复清 cache。
    ///
    /// A process-wide shared coordinator instance, **opt-in**. `MarkdownLabelView`
    /// does NOT use it by default; each view owns a private `init()` instance.
    public static let shared = MathLoadCoordinator()
}
