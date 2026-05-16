@testable import MarkdownPlatformView
import MarkdownCore
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

    @Test("invalidateForScaleChange 清空正/负缓存但不改 generation")
    func invalidateForScaleChangeClears() async {
        let counter = CallCounter()
        let c = MathLoadCoordinator()
        await c.setRenderer(StubRenderer(outcome: { .rendered(.init(image: pixel(), baselineOffsetEx: 0)) }, counter: counter))
        let gen = await c.generation
        _ = await c.loadIfNeeded(key: key("s"), latex: "s", display: false, pointSize: 16, scale: 2, color: .black)
        await c.drain()
        #expect(await c.glyph(for: key("s")) != nil)
        await c.invalidateForScaleChange()
        #expect(await c.glyph(for: key("s")) == nil)        // 正缓存清空
        #expect(await c.generation == gen)                  // generation 不变（区别于 setRenderer）
    }

    @Test("positive 超过上限触发 LRU 逐出")
    func positiveLRUEviction() async {
        let counter = CallCounter()
        let c = MathLoadCoordinator()
        await c.setRenderer(StubRenderer(outcome: { .rendered(.init(image: pixel(), baselineOffsetEx: 0)) }, counter: counter))
        // 填超过 cap（cap=256）个不同 key；最早的应被逐出。
        for i in 0 ..< 300 {
            _ = await c.loadIfNeeded(key: key("f\(i)"), latex: "f\(i)", display: false, pointSize: 16, scale: 2, color: .black)
            await c.drain()
        }
        #expect(await c.glyph(for: key("f0")) == nil)        // 最早的被逐出
        #expect(await c.glyph(for: key("f299")) != nil)      // 最近的保留
    }

    @Test("setRenderer 同实例两次仍各自 bump generation（故守卫必须在 representable 层）")
    func setRendererNotIdempotent() async {
        let c = MathLoadCoordinator()
        let r = StubRenderer(outcome: { .failed }, counter: CallCounter())
        await c.setRenderer(r); let g1 = await c.generation
        await c.setRenderer(r); let g2 = await c.generation
        #expect(g2 == g1 + 1)
    }

    @Test("awaitGlyph 仅等该 key 的任务即可拿到字形（无需 drain）")
    func awaitGlyphPerKey() async {
        let counter = CallCounter()
        let c = MathLoadCoordinator()
        await c.setRenderer(StubRenderer(outcome: {
            .rendered(.init(image: pixel(), baselineOffsetEx: 0)) }, counter: counter))
        var keys: [MathCacheKey] = []
        for i in 0 ..< 5 {
            let k = key("g\(i)")
            keys.append(k)
            _ = await c.loadIfNeeded(key: k, latex: "g\(i)", display: false, pointSize: 16, scale: 2, color: .black)
        }
        for k in keys {
            #expect(await c.awaitGlyph(for: k) != nil)   // 不调用 drain，按 key 等待即得字形
        }
        #expect(await counter.count == 5)
    }
}

@Suite("Math view wiring")
struct MathViewWiringTests {
    @Test("占位属性可被枚举并驱动 coordinator，回写后渲染出附件")
    func placeholderDrivesCoordinator() async {
        var renderer = AttributedStringRenderer(style: .default)
        let attr = renderer.render([.paragraph([.math(latex: "x")])])
        var payloads: [String] = []
        attr.enumerateAttribute(.markdownMathSource, in: NSRange(location: 0, length: attr.length)) { v, _, _ in
            if let p = v as? String { payloads.append(p) }
        }
        #expect(payloads == ["0\u{1F}x"])

        let c = MathLoadCoordinator()
        await c.setRenderer(StubRenderer(outcome: {
            .rendered(.init(image: pixel(), baselineOffsetEx: 0)) }, counter: CallCounter()))
        let gen = await c.generation
        let key = MathCacheKey(latex: "x", display: false,
                               pointSize: RenderStyle.default.bodyFont.pointSize,
                               colorHex: MathMetrics.colorHex(RenderStyle.default.textColor),
                               rasterScale: 1, rendererGeneration: gen)
        _ = await c.loadIfNeeded(key: key, latex: "x", display: false,
                                 pointSize: key.pointSize, scale: 1, color: RenderStyle.default.textColor)
        await c.drain()
        renderer.mathRendererGeneration = gen
        renderer.mathCache[key] = await c.glyph(for: key)
        let attr2 = renderer.render([.paragraph([.math(latex: "x")])])
        var hasAttachment = false
        attr2.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr2.length)) { v, _, _ in
            if v is NSTextAttachment { hasAttachment = true }
        }
        #expect(hasAttachment)
    }
}

#if canImport(UIKit)
import UIKit
private func pixel() -> PlatformImage { UIGraphicsImageRenderer(size: .init(width: 2, height: 2)).image { _ in } }
#elseif canImport(AppKit)
import AppKit
private func pixel() -> PlatformImage { let i = NSImage(size: .init(width: 2, height: 2)); i.lockFocus(); i.unlockFocus(); return i }
#endif
