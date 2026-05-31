import Foundation
import MarkdownRenderKit

/// 平台无关的 SVG 代码块渲染协调器：去重派发、三态分派、负缓存、代际失效。
/// 由平台视图持有；视图负责枚举 .markdownSVGBlockSource 并在完成回调里 setNeedsLayout/重渲染。
/// 镜像 MathLoadCoordinator —— 设计差异仅在 render 签名与不携带 color。
public actor SVGBlockLoadCoordinator {
    public init() {}

    private var renderer: (any SVGBlockRendering)?
    public private(set) var generation: Int = 0

    private var positive: [SVGBlockCacheKey: SVGBlockGlyph] = [:]
    private var negative: Set<SVGBlockCacheKey> = []
    private var inFlight: Set<SVGBlockCacheKey> = []
    private var tasks: [SVGBlockCacheKey: Task<Void, Never>] = [:]

    // 与 math 同：缓存设上限，避免流式长对话内存膨胀。
    // positive：LRU（lruOrder 末尾 = 最近使用）；negative：计数封顶后整体清空。
    private let positiveCap = 256
    private let negativeCap = 1024
    private var lruOrder: [SVGBlockCacheKey] = []

    /// 记录某 key 为最近使用：从 lruOrder 移除旧位置后追加到末尾。
    private func touchLRU(_ key: SVGBlockCacheKey) {
        if let idx = lruOrder.firstIndex(of: key) { lruOrder.remove(at: idx) }
        lruOrder.append(key)
    }

    /// 设置/替换渲染器：代际自增并清正/负/loading。
    public func setRenderer(_ r: (any SVGBlockRendering)?) {
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

    public func glyph(for key: SVGBlockCacheKey) -> SVGBlockGlyph? {
        guard let glyph = positive[key] else { return nil }
        touchLRU(key)
        return glyph
    }
    public func isNegativeCached(_ key: SVGBlockCacheKey) -> Bool { negative.contains(key) }

    /// 需要时派发渲染。返回是否真的派发了任务（用于测试与去抖）。
    @discardableResult
    public func loadIfNeeded(
        key: SVGBlockCacheKey, svg: String, availableWidth: CGFloat, scale: CGFloat
    ) -> Bool {
        guard let renderer else { return false }
        if positive[key] != nil || negative.contains(key) || inFlight.contains(key) { return false }
        inFlight.insert(key)
        let task = Task { [weak self] in
            let outcome = await renderer.render(svg: svg, availableWidth: availableWidth, scale: scale)
            await self?.finish(key: key, outcome: outcome)
        }
        tasks[key] = task
        return true
    }

    private func finish(key: SVGBlockCacheKey, outcome: SVGBlockOutcome) {
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

    /// Await just this key's in-flight render task (if any) then return its glyph.
    /// Production-safe alternative to `drain()` (which is test-only, awaits ALL tasks).
    public func awaitGlyph(for key: SVGBlockCacheKey) async -> SVGBlockGlyph? {
        if let t = tasks[key] { _ = await t.value }
        return glyph(for: key)
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

extension SVGBlockLoadCoordinator {
    /// 进程级共享实例（**opt-in**）。MarkdownLabelView **默认不使用**——每个 view
    /// 仍持有自己的 `init()` 实例以保证测试隔离（不同 test 各自 setRenderer 不会
    /// 互清 cache）。需要跨 view cache 的调用方可在装配处显式接入这个实例。
    ///
    /// 既存 LRU(256) / negative(1024) / dedup / 代际逻辑全部继承——共用此实例的
    /// 所有调用者共享 cache。`setRenderer` 会清整体 cache + 代际自增，因此**共用
    /// 此实例的调用方应保证全 process 用同一个 SVGBlockRendering 实例**，否则
    /// setRenderer 会反复清 cache（spec §7 已知约束）。
    ///
    /// A process-wide shared coordinator instance, **opt-in**. `MarkdownLabelView`
    /// does NOT use it by default; each view owns a private `init()` instance to
    /// keep tests independent. Call sites that want cross-view cache reuse must
    /// wire this in explicitly.
    public static let shared = SVGBlockLoadCoordinator()
}
