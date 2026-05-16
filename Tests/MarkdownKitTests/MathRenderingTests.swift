import MarkdownRenderKit
import Testing
import Foundation

@Suite("Math rendering types")
struct MathRenderingTypeTests {
    @Test("有效字号 = 文本字号 × mathScale，单点计算")
    func effectivePointSize() {
        #expect(MathMetrics.effectivePointSize(textPointSize: 16, mathScale: 1.0) == 16)
        #expect(MathMetrics.effectivePointSize(textPointSize: 16, mathScale: 1.5) == 24)
    }

    @Test("MathCacheKey 任一维度不同则不相等")
    func cacheKeyIdentity() {
        let base = MathCacheKey(latex: "x", display: false, pointSize: 16,
                                colorHex: "#000", rasterScale: 2, rendererGeneration: 1)
        #expect(base == MathCacheKey(latex: "x", display: false, pointSize: 16,
                                     colorHex: "#000", rasterScale: 2, rendererGeneration: 1))
        #expect(base != MathCacheKey(latex: "x", display: false, pointSize: 24,
                                     colorHex: "#000", rasterScale: 2, rendererGeneration: 1))
        #expect(base != MathCacheKey(latex: "x", display: false, pointSize: 16,
                                     colorHex: "#000", rasterScale: 2, rendererGeneration: 2))
        #expect(base != MathCacheKey(latex: "y", display: false, pointSize: 16,
                                     colorHex: "#000", rasterScale: 2, rendererGeneration: 1))
        #expect(base != MathCacheKey(latex: "x", display: true, pointSize: 16,
                                     colorHex: "#000", rasterScale: 2, rendererGeneration: 1))
        #expect(base != MathCacheKey(latex: "x", display: false, pointSize: 16,
                                     colorHex: "#111", rasterScale: 2, rendererGeneration: 1))
        #expect(base != MathCacheKey(latex: "x", display: false, pointSize: 16,
                                     colorHex: "#000", rasterScale: 3, rendererGeneration: 1))
    }
}

import MarkdownCore

@Suite("Math attributed rendering")
struct MathAttributedRenderingTests {
    @Test("未命中缓存 → 占位文本带 markdownMathSource 属性")
    func placeholderWhenMiss() {
        let r = AttributedStringRenderer(style: .default)
        let s = r.render([.paragraph([.text("a "), .math(latex: "x^2")])])
        var found = false
        s.enumerateAttribute(.markdownMathSource, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let payload = v as? String { #expect(payload == "0\u{1F}x^2"); found = true }
        }
        #expect(found)
    }

    @Test("命中缓存 → NSTextAttachment，基线按 baselineOffsetEx 下移")
    func attachmentWhenHit() {
        var r = AttributedStringRenderer(style: .default)
        let img = makePixel()
        // Derive the key's pointSize/colorHex from the actual `.default` style via the
        // same public formula the renderer uses, instead of hardcoding 16. On the macOS
        // (AppKit) host build `.default.bodyFont` is size 15, not 16, so a hardcoded-16
        // key would never match the renderer's size-15-derived key and this test would
        // fail on macOS. This keeps the assertion strict (cache hit ⇒ attachment) while
        // being host-independent. See Task 8 plan "default-font test-robustness".
        let key = MathCacheKey(
            latex: "x^2", display: false,
            pointSize: MathMetrics.effectivePointSize(
                textPointSize: RenderStyle.default.bodyFont.pointSize,
                mathScale: 1.0
            ),
            colorHex: MathMetrics.colorHex(
                RenderStyle.default.mathColorOverride ?? RenderStyle.default.textColor
            ),
            rasterScale: 1, rendererGeneration: 0)
        r.mathCache[key] = MathRenderedGlyph(image: img, baselineOffsetEx: 0.5)
        let s = r.render([.paragraph([.math(latex: "x^2")])])
        var hasAttachment = false
        var capturedAttachment: NSTextAttachment?
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let a = v as? NSTextAttachment { hasAttachment = true; capturedAttachment = a }
        }
        #expect(hasAttachment)
        // 基线公式 pin（Task 8 评审）：bounds.y == -baselineOffsetEx * effectivePointSize * 0.5
        let expectedPt = MathMetrics.effectivePointSize(
            textPointSize: RenderStyle.default.bodyFont.pointSize, mathScale: 1.0)
        if let att = capturedAttachment {
            #expect(abs(att.bounds.origin.y - (-0.5 * expectedPt * 0.5)) < 0.001)
        }
    }
}

#if canImport(UIKit)
import UIKit
private func makePixel() -> PlatformImage {
    UIGraphicsImageRenderer(size: .init(width: 4, height: 4)).image { _ in }
}
#elseif canImport(AppKit)
import AppKit
private func makePixel() -> PlatformImage {
    let i = NSImage(size: .init(width: 4, height: 4)); i.lockFocus(); i.unlockFocus(); return i
}
#endif

@Suite("RenderStyle math fields")
struct RenderStyleMathTests {
    @Test("默认值：mathScale=1，mathColorOverride=nil，mathTokenColor 非空")
    func defaults() {
        let s = RenderStyle.default
        #expect(s.mathScale == 1.0)
        #expect(s.mathColorOverride == nil)
        _ = s.mathTokenColor
    }
}
