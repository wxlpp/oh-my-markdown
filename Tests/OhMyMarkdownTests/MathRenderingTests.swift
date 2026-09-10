import Foundation
import MarkdownRenderKit
import Testing

@Suite("Math rendering types")
@MainActor
struct MathRenderingTypeTests {
    @Test("有效字号 = 文本字号 × mathScale，单点计算")
    func effectivePointSize() {
        #expect(MathMetrics.effectivePointSize(textPointSize: 16, mathScale: 1.0) == 16)
        #expect(MathMetrics.effectivePointSize(textPointSize: 16, mathScale: 1.5) == 24)
    }

    @Test("colorHex 输出 6 位 #RRGGBB（不含 alpha）")
    func colorHexSixDigit() {
        // Bug 2 fix: colorHex must return 6-digit #RRGGBB so SwiftDraw can parse it.
        // Before fix: returns "#000000FF" (8-digit) → SwiftDraw misparses → blue pixels.
        let hex = MathMetrics.colorHex(PlatformColor.black)
        #expect(hex == "#000000", "colorHex must be 6-digit #RRGGBB, got: \(hex)")
        #expect(hex.count == 7, "Expected '#' + 6 hex chars = 7 chars total, got \(hex.count)")
    }

    @Test("MathCacheKey 任一维度不同则不相等")
    func cacheKeyIdentity() {
        let base = MathCacheKey(
            latex: "x",
            display: false,
            pointSize: 16,
            colorHex: "#000",
            rasterScale: 2,
            configurationID: .semantic(namespace: "fixture", version: 1)
        )
        #expect(base == MathCacheKey(
            latex: "x",
            display: false,
            pointSize: 16,
            colorHex: "#000",
            rasterScale: 2,
            configurationID: .semantic(namespace: "fixture", version: 1)
        ))
        #expect(base != MathCacheKey(
            latex: "x",
            display: false,
            pointSize: 24,
            colorHex: "#000",
            rasterScale: 2,
            configurationID: .semantic(namespace: "fixture", version: 1)
        ))
        #expect(base != MathCacheKey(
            latex: "x",
            display: false,
            pointSize: 16,
            colorHex: "#000",
            rasterScale: 2,
            configurationID: .semantic(namespace: "fixture", version: 2)
        ))
        #expect(base != MathCacheKey(
            latex: "y",
            display: false,
            pointSize: 16,
            colorHex: "#000",
            rasterScale: 2,
            configurationID: .semantic(namespace: "fixture", version: 1)
        ))
        #expect(base != MathCacheKey(
            latex: "x",
            display: true,
            pointSize: 16,
            colorHex: "#000",
            rasterScale: 2,
            configurationID: .semantic(namespace: "fixture", version: 1)
        ))
        #expect(base != MathCacheKey(
            latex: "x",
            display: false,
            pointSize: 16,
            colorHex: "#111",
            rasterScale: 2,
            configurationID: .semantic(namespace: "fixture", version: 1)
        ))
        #expect(base != MathCacheKey(
            latex: "x",
            display: false,
            pointSize: 16,
            colorHex: "#000",
            rasterScale: 3,
            configurationID: .semantic(namespace: "fixture", version: 1)
        ))
    }
}

import MarkdownCore

@Suite("Math attributed rendering")
@MainActor
struct MathAttributedRenderingTests {
    @Test("未命中缓存 → 占位文本带 markdownMathSource 属性")
    func placeholderWhenMiss() {
        let r = MaterializationFixture(style: .default)
        let s = r.render([.paragraph([.text("a "), .math(latex: "x^2")])])
        var found = false
        s.enumerateAttribute(.markdownMathSource, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let payload = v as? String { #expect(payload == "0\u{1F}x^2"); found = true }
        }
        #expect(found)
    }

    /// Bug 3: baselineOffsetEx is always negative in practice (MathJax convention).
    /// A negative baselineOffsetEx means the glyph sits below the text baseline,
    /// so bounds.origin.y must also be negative (NSTextAttachment: negative y = sink down).
    /// The fix is to pass-through the sign directly: y = baselineOffsetEx * exToPoints.
    @Test("负 baselineOffsetEx → bounds.origin.y 为负（公式下沉，符号不反置）")
    func baselineSignPassthrough() {
        var r = MaterializationFixture(style: .default)
        let img = makePixel()
        let effectivePt = MathMetrics.effectivePointSize(
            textPointSize: RenderStyle.default.bodyFont.pointSize,
            mathScale: 1.0
        )
        let key = MathCacheKey(
            latex: "x", display: false,
            pointSize: effectivePt,
            colorHex: MathMetrics.colorHex(
                RenderStyle.default.mathColorOverride ?? RenderStyle.default.textColor
            ),
            rasterScale: 1, configurationID: .semantic(namespace: "fixture", version: 0)
        )
        // Negative baselineOffsetEx mirrors real MathJax output (e.g. "x" → -0.025 ex)
        r.math[key.latex] = (img, -0.5 * key.pointSize * 0.5)
        let s = r.render([.paragraph([.math(latex: "x")])])
        var capturedAttachment: NSTextAttachment?
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let a = v as? NSTextAttachment { capturedAttachment = a }
        }
        guard let att = capturedAttachment else {
            Issue.record("No NSTextAttachment found — cache miss")
            return
        }
        // With correct sign pass-through: y = -0.5 * (effectivePt * 0.5) < 0 (glyph sinks)
        // Buggy code negates again: y = -(-0.5) * exToPoints = +positive → fails < 0
        #expect(att.bounds.origin.y < 0, "bounds.origin.y must be negative (glyph sinks below baseline)")
        let exToPoints = effectivePt * 0.5
        let expectedY = -0.5 * exToPoints // baselineOffsetEx * exToPoints
        #expect(
            abs(att.bounds.origin.y - expectedY) < 0.001,
            "y should equal baselineOffsetEx * exToPoints = \(expectedY), got \(att.bounds.origin.y)"
        )
    }

    @Test("命中缓存 → NSTextAttachment，基线按 baselineOffsetEx 下移")
    func attachmentWhenHit() {
        var r = MaterializationFixture(style: .default)
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
            rasterScale: 1, configurationID: .semantic(namespace: "fixture", version: 0)
        )
        r.math[key.latex] = (img, 0.5 * key.pointSize * 0.5)
        let s = r.render([.paragraph([.math(latex: "x^2")])])
        var hasAttachment = false
        var capturedAttachment: NSTextAttachment?
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let a = v as? NSTextAttachment { hasAttachment = true; capturedAttachment = a }
        }
        #expect(hasAttachment)
        // 基线公式 pin（Bug 3 修复后）：bounds.y == baselineOffsetEx * effectivePointSize * 0.5（同号透传）
        let expectedPt = MathMetrics.effectivePointSize(
            textPointSize: RenderStyle.default.bodyFont.pointSize, mathScale: 1.0
        )
        if let att = capturedAttachment {
            // After Bug 3 fix: y = baselineOffsetEx * exToPoints (sign pass-through, no negation).
            // baselineOffsetEx=0.5 (positive = glyph sits above baseline) → y = +0.5 * exToPoints > 0.
            #expect(abs(att.bounds.origin.y - (0.5 * expectedPt * 0.5)) < 0.001)
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
@MainActor
struct RenderStyleMathTests {
    @Test("默认值：mathScale=1，mathColorOverride=nil，mathTokenColor 非空")
    func defaults() {
        let s = RenderStyle.default
        #expect(s.mathScale == 1.0)
        #expect(s.mathColorOverride == nil)
        #expect(s.mathTokenColor != s.textColor)
    }
}

import OhMyMarkdown
import SwiftUI

@Suite("SwiftUI math renderer env")
@MainActor
struct MathRendererEnvTests {
    @Test("环境值默认 nil，设置后可取回")
    func envValue() {
        var env = EnvironmentValues()
        #expect(env.markdownMathRenderer == nil)
        // MathRendering 现已约束 AnyObject，测试替身改为 final class。
        final class Dummy: MathRendering, @unchecked Sendable {
            func render(
                latex: String,
                display: Bool,
                pointSize: CGFloat,
                scale: CGFloat,
                colorHex: String
            ) async -> MathRenderOutcome {
                .failed
            }
        }
        env.markdownMathRenderer = MathRendererConfiguration(renderer: Dummy())
        #expect(env.markdownMathRenderer != nil)
    }
}
