import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite("Shared coordinator singletons")
struct SharedCoordinatorTests {
    @Test func svgSharedSingletonReturnsSameInstance() async {
        let a = SVGBlockLoadCoordinator.shared
        let b = SVGBlockLoadCoordinator.shared
        #expect(a === b)
    }

    @Test func mathSharedSingletonReturnsSameInstance() async {
        let a = MathLoadCoordinator.shared
        let b = MathLoadCoordinator.shared
        #expect(a === b)
    }

    @Test func independentInitInstancesAreNotShared() async {
        let a = SVGBlockLoadCoordinator()
        let b = SVGBlockLoadCoordinator()
        #expect(a !== b)
        #expect(a !== SVGBlockLoadCoordinator.shared)
    }

    @Test func mathIndependentInitInstancesAreNotShared() async {
        let a = MathLoadCoordinator()
        let b = MathLoadCoordinator()
        #expect(a !== b)
        #expect(a !== MathLoadCoordinator.shared)
    }

    /// 跨调用 cache 共享幂等：同一 coordinator 实例下，相同 key 第二次 loadIfNeeded
    /// 必须返回 false（已命中 cache），renderer 不应被再次调用。
    ///
    /// 用 init() 独立实例做隔离避免污染 .shared（其它测试共享）。语义等价：
    /// 「同 coordinator 多次复用」== 「.shared 跨 view 复用」（如果调用方接入 .shared）。
    /// 钉住的契约：positive cache 命中后 loadIfNeeded 即时返回 false，不入 inFlight、
    /// 不再次派发 renderer.render。
    ///
    /// Cross-call cache idempotence: a second `loadIfNeeded` with the same key on
    /// the same coordinator must return false (cache hit) and must not re-invoke
    /// the renderer. Uses an independent `init()` instance to avoid polluting `.shared`.
    @Test func sameCoordinatorSecondLoadIsCacheHitNoReDispatch() async {
        let counter = RenderCallCounter()
        let renderer = CountingSVGRenderer(counter: counter)
        // 独立实例做隔离测试，不污染 .shared 全局状态
        let coord = SVGBlockLoadCoordinator()
        await coord.setRenderer(renderer)

        let key = SVGBlockCacheKey(svg: "<svg/>", availableWidth: 100, rasterScale: 2, rendererGeneration: 0)

        // 1st call: 入 inFlight 派发，返回 true
        let dispatched1 = await coord.loadIfNeeded(key: key, svg: "<svg/>", availableWidth: 100, scale: 2)
        #expect(dispatched1)
        await coord.drain()
        #expect(await coord.glyph(for: key) != nil, "drain 后应有 glyph 落 cache")
        #expect(await counter.count == 1, "1st loadIfNeeded 应调 renderer 1 次")

        // 2nd call: positive cache 命中，直接返回 false 不再派发
        let dispatched2 = await coord.loadIfNeeded(key: key, svg: "<svg/>", availableWidth: 100, scale: 2)
        #expect(dispatched2 == false, "已 cache 的 key 第二次 loadIfNeeded 必须返回 false")
        #expect(await counter.count == 1, "cache 命中后 renderer 不应被再次调用")
    }
}

private actor RenderCallCounter {
    var count = 0
    func inc() { self.count += 1 }
}

private final class CountingSVGRenderer: SVGBlockRendering, @unchecked Sendable {
    private let counter: RenderCallCounter
    #if canImport(UIKit)
    private let stub: PlatformImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    #elseif canImport(AppKit)
    private let stub: PlatformImage = NSImage(size: CGSize(width: 1, height: 1))
    #endif

    init(counter: RenderCallCounter) { self.counter = counter }

    func render(svg _: String, availableWidth _: CGFloat, scale _: CGFloat) async -> SVGBlockOutcome {
        await self.counter.inc()
        return .rendered(SVGBlockGlyph(image: self.stub))
    }
}
