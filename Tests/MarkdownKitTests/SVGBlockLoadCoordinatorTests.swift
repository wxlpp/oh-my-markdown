import CoreGraphics
@testable import MarkdownPlatformView
import MarkdownRenderKit
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// SVGBlockRendering 约束 AnyObject（与 math 协议一致：唯一生产实现为 final class
/// SwiftDrawSVGBlockRenderer）。测试替身用 final class，与 MathLoadCoordinatorTests
/// 的 StubRenderer 同形。
private final class StubSVGRenderer: SVGBlockRendering, @unchecked Sendable {
    let outcome: SVGBlockOutcome
    init(_ o: SVGBlockOutcome) {
        self.outcome = o
    }

    func render(svg _: String, availableWidth _: CGFloat, scale _: CGFloat) async -> SVGBlockOutcome {
        self.outcome
    }
}

private func svgKey(_ s: String = "<svg/>", gen: Int = 0) -> SVGBlockCacheKey {
    SVGBlockCacheKey(svg: s, availableWidth: 100, rasterScale: 1, rendererGeneration: gen)
}

private func sampleGlyph() -> SVGBlockGlyph {
    #if canImport(UIKit)
    return SVGBlockGlyph(image: UIGraphicsImageRenderer(size: .init(width: 10, height: 10)).image { _ in })
    #elseif canImport(AppKit)
    let i = NSImage(size: .init(width: 10, height: 10))
    i.lockFocus(); i.unlockFocus()
    return SVGBlockGlyph(image: i)
    #else
    return SVGBlockGlyph(image: PlatformImage())
    #endif
}

@Suite("SVGBlockLoadCoordinator")
struct SVGBlockLoadCoordinatorTests {
    @Test("nil renderer → 不派发")
    func nilRendererNoDispatch() async {
        let c = SVGBlockLoadCoordinator()
        let dispatched = await c.loadIfNeeded(
            key: svgKey(), svg: "<svg/>", availableWidth: 100, scale: 1
        )
        #expect(dispatched == false)
    }

    @Test(".rendered → 进正缓存，再次不重复派发；awaitGlyph 拿得到")
    func renderedCachedOnce() async {
        let c = SVGBlockLoadCoordinator()
        await c.setRenderer(StubSVGRenderer(.rendered(sampleGlyph())))
        #expect(await c.loadIfNeeded(
            key: svgKey(), svg: "<svg/>", availableWidth: 100, scale: 1
        ) == true)
        #expect(await c.awaitGlyph(for: svgKey()) != nil)
        #expect(await c.loadIfNeeded(
            key: svgKey(), svg: "<svg/>", availableWidth: 100, scale: 1
        ) == false)
    }

    @Test(".failed → 负缓存，后续不再派发")
    func failedNegativeCached() async {
        let c = SVGBlockLoadCoordinator()
        await c.setRenderer(StubSVGRenderer(.failed))
        _ = await c.loadIfNeeded(
            key: svgKey(), svg: "<svg/>", availableWidth: 100, scale: 1
        )
        _ = await c.awaitGlyph(for: svgKey())
        #expect(await c.isNegativeCached(svgKey()))
        #expect(await c.loadIfNeeded(
            key: svgKey(), svg: "<svg/>", availableWidth: 100, scale: 1
        ) == false)
        #expect(await c.glyph(for: svgKey()) == nil)
    }

    @Test(".cancelled → 不写任何缓存，可重试")
    func cancelledRetryable() async {
        let c = SVGBlockLoadCoordinator()
        await c.setRenderer(StubSVGRenderer(.cancelled))
        _ = await c.loadIfNeeded(
            key: svgKey(), svg: "<svg/>", availableWidth: 100, scale: 1
        )
        _ = await c.awaitGlyph(for: svgKey())
        #expect(await c.isNegativeCached(svgKey()) == false)
        #expect(await c.glyph(for: svgKey()) == nil)
    }

    @Test("setRenderer → generation 自增且清正/负/loading 缓存")
    func setRendererBumpsGeneration() async {
        let c = SVGBlockLoadCoordinator()
        await c.setRenderer(StubSVGRenderer(.rendered(sampleGlyph())))
        let g0 = await c.generation
        _ = await c.loadIfNeeded(
            key: svgKey(gen: g0), svg: "<svg/>", availableWidth: 100, scale: 1
        )
        _ = await c.awaitGlyph(for: svgKey(gen: g0))
        #expect(await c.glyph(for: svgKey(gen: g0)) != nil)
        await c.setRenderer(StubSVGRenderer(.rendered(sampleGlyph())))
        #expect(await c.generation == g0 + 1)
        #expect(await c.glyph(for: svgKey(gen: g0)) == nil)
    }

    @Test("invalidateForScaleChange 清缓存但不改 generation")
    func invalidateForScaleClears() async {
        let c = SVGBlockLoadCoordinator()
        await c.setRenderer(StubSVGRenderer(.rendered(sampleGlyph())))
        _ = await c.loadIfNeeded(
            key: svgKey(), svg: "<svg/>", availableWidth: 100, scale: 1
        )
        _ = await c.awaitGlyph(for: svgKey())
        let g = await c.generation
        await c.invalidateForScaleChange()
        #expect(await c.generation == g)
        #expect(await c.glyph(for: svgKey()) == nil)
    }

    @Test("setRenderer 同实例两次仍各自 bump generation（守卫归 representable 层）")
    func setRendererNotIdempotent() async {
        let c = SVGBlockLoadCoordinator()
        let r = StubSVGRenderer(.failed)
        await c.setRenderer(r); let g1 = await c.generation
        await c.setRenderer(r); let g2 = await c.generation
        #expect(g2 == g1 + 1)
    }
}
