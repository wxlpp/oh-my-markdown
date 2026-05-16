@testable import MarkdownPlatformView
import MarkdownRenderKit
import Testing
import Foundation

private actor CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

private struct StubRenderer: MathRendering {
    let outcome: @Sendable () -> MathRenderOutcome
    let counter: CallCounter
    func render(latex: String, display: Bool, pointSize: CGFloat,
                scale: CGFloat, color: PlatformColor) async -> MathRenderOutcome {
        await counter.bump()
        return outcome()
    }
}

@Suite("MathLoadCoordinator")
struct MathLoadCoordinatorTests {
    private func key(_ latex: String, gen: Int = 1) -> MathCacheKey {
        MathCacheKey(latex: latex, display: false, pointSize: 16,
                     colorHex: "#000", rasterScale: 2, rendererGeneration: gen)
    }

    @Test("nil renderer → 不派发")
    func nilRendererNoDispatch() async {
        let c = MathLoadCoordinator()
        let dispatched = await c.loadIfNeeded(key: key("x"), latex: "x", display: false,
                                              pointSize: 16, scale: 2, color: .black)
        #expect(dispatched == false)
    }

    @Test(".rendered → 进正缓存，再次不重复派发")
    func renderedCachedOnce() async {
        let counter = CallCounter()
        let c = MathLoadCoordinator()
        let img = pixel()
        await c.setRenderer(StubRenderer(outcome: { .rendered(.init(image: img, baselineOffsetEx: 0)) },
                                         counter: counter))
        _ = await c.loadIfNeeded(key: key("x"), latex: "x", display: false, pointSize: 16, scale: 2, color: .black)
        await c.drain()
        #expect(await c.glyph(for: key("x")) != nil)
        _ = await c.loadIfNeeded(key: key("x"), latex: "x", display: false, pointSize: 16, scale: 2, color: .black)
        await c.drain()
        #expect(await counter.count == 1)
    }

    @Test(".failed → 负缓存，后续 pass 不再派发")
    func failedNegativeCached() async {
        let counter = CallCounter()
        let c = MathLoadCoordinator()
        await c.setRenderer(StubRenderer(outcome: { .failed }, counter: counter))
        for _ in 0 ..< 5 {
            _ = await c.loadIfNeeded(key: key("bad"), latex: "bad", display: false, pointSize: 16, scale: 2, color: .black)
            await c.drain()
        }
        #expect(await counter.count == 1)
        #expect(await c.glyph(for: key("bad")) == nil)
    }

    @Test(".cancelled → 不写任何缓存，可重试")
    func cancelledRetryable() async {
        let counter = CallCounter()
        let c = MathLoadCoordinator()
        await c.setRenderer(StubRenderer(outcome: { .cancelled }, counter: counter))
        _ = await c.loadIfNeeded(key: key("c"), latex: "c", display: false, pointSize: 16, scale: 2, color: .black)
        await c.drain()
        _ = await c.loadIfNeeded(key: key("c"), latex: "c", display: false, pointSize: 16, scale: 2, color: .black)
        await c.drain()
        #expect(await counter.count == 2)
    }

    @Test("换 renderer → generation 自增且清正/负/loading 缓存")
    func rendererSwapClears() async {
        let counter = CallCounter()
        let c = MathLoadCoordinator()
        await c.setRenderer(StubRenderer(outcome: { .failed }, counter: counter))
        let g1 = await c.generation
        _ = await c.loadIfNeeded(key: key("z", gen: g1), latex: "z", display: false, pointSize: 16, scale: 2, color: .black)
        await c.drain()
        await c.setRenderer(StubRenderer(outcome: {
            .rendered(.init(image: pixel(), baselineOffsetEx: 0)) }, counter: counter))
        let g2 = await c.generation
        #expect(g2 == g1 + 1)
        #expect(await c.isNegativeCached(key("z", gen: g1)) == false)
    }
}

#if canImport(UIKit)
import UIKit
private func pixel() -> PlatformImage { UIGraphicsImageRenderer(size: .init(width: 2, height: 2)).image { _ in } }
#elseif canImport(AppKit)
import AppKit
private func pixel() -> PlatformImage { let i = NSImage(size: .init(width: 2, height: 2)); i.lockFocus(); i.unlockFocus(); return i }
#endif
