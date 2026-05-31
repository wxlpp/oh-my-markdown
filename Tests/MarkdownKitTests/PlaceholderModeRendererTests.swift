import Foundation
import MarkdownCore
@testable import MarkdownRenderKit
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite("PlaceholderMode-aware rendering")
struct PlaceholderModeRendererTests {
    // MARK: SVG miss 分支按 mode 区分

    @Test func svgStaticMissEmitsTransparentAttachmentWithMarker() {
        let svg = #"<svg viewBox="0 0 480 320"></svg>"#
        let renderer = AttributedStringRenderer(
            style: .default, availableWidth: 600, placeholderMode: .static)
        let block = BlockNode.codeBlock(language: "svg", body: svg)
        let result = renderer.renderBlock(block)

        // 应携带 .markdownSVGBlockSource marker（与 streaming miss 一致）
        let full = NSRange(location: 0, length: result.length)
        var foundMarker = false
        result.enumerateAttribute(.markdownSVGBlockSource, in: full) { v, _, _ in
            if v is String { foundMarker = true }
        }
        #expect(foundMarker)

        // 应含 NSTextAttachment 且 image == nil（透明），bounds 按 fit-without-upscale：
        // viewBox=480×320，availableWidth=600 → target = (min(480, 600), 480 × 320/480)
        //                                              = (480, 320)
        // 与 SwiftDraw 落地后的 image.size 完全一致，避免 layout shift。
        var foundTransparentAttachment = false
        result.enumerateAttribute(.attachment, in: full) { v, _, _ in
            guard let att = v as? NSTextAttachment else { return }
            if att.image == nil {
                foundTransparentAttachment = true
                #expect(abs(att.bounds.size.width - 480) < 1)
                #expect(abs(att.bounds.size.height - 320) < 1)
            }
        }
        #expect(foundTransparentAttachment)
    }

    @Test func svgStaticMissUsesAvailableWidthWhenViewBoxExceedsIt() {
        // viewBox 比 availableWidth 大 → fit-width 收紧到 availableWidth
        let svg = #"<svg viewBox="0 0 1200 600"></svg>"#
        let renderer = AttributedStringRenderer(
            style: .default, availableWidth: 400, placeholderMode: .static)
        let block = BlockNode.codeBlock(language: "svg", body: svg)
        let result = renderer.renderBlock(block)
        let full = NSRange(location: 0, length: result.length)
        var w: CGFloat = -1
        var h: CGFloat = -1
        result.enumerateAttribute(.attachment, in: full) { v, _, _ in
            if let att = v as? NSTextAttachment, att.image == nil {
                w = att.bounds.size.width
                h = att.bounds.size.height
            }
        }
        // target = (min(1200, 400), 400 × 600/1200) = (400, 200)
        #expect(abs(w - 400) < 1)
        #expect(abs(h - 200) < 1)
    }

    @Test func svgStreamingMissEmitsHighlightedSourceWithMarker() {
        let svg = #"<svg viewBox="0 0 480 320"></svg>"#
        let renderer = AttributedStringRenderer(
            style: .default, availableWidth: 600, placeholderMode: .streaming)
        let block = BlockNode.codeBlock(language: "svg", body: svg)
        let result = renderer.renderBlock(block)

        // marker 仍打
        let full = NSRange(location: 0, length: result.length)
        var foundMarker = false
        result.enumerateAttribute(.markdownSVGBlockSource, in: full) { v, _, _ in
            if v is String { foundMarker = true }
        }
        #expect(foundMarker)

        // streaming-miss 是文本（高亮源码），不应含透明 attachment
        var foundTransparentAttachment = false
        result.enumerateAttribute(.attachment, in: full) { v, _, _ in
            if let att = v as? NSTextAttachment, att.image == nil { foundTransparentAttachment = true }
        }
        #expect(foundTransparentAttachment == false)

        // 源串字符应在结果里
        #expect(result.string.contains("viewBox"))
    }

    @Test func svgStaticMissFallsBackTo60PercentAspectWhenNoViewBox() {
        let svg = "<svg></svg>"
        let renderer = AttributedStringRenderer(
            style: .default, availableWidth: 600, placeholderMode: .static)
        let block = BlockNode.codeBlock(language: "svg", body: svg)
        let result = renderer.renderBlock(block)

        let full = NSRange(location: 0, length: result.length)
        var attachmentHeight: CGFloat = -1
        result.enumerateAttribute(.attachment, in: full) { v, _, _ in
            if let att = v as? NSTextAttachment, att.image == nil {
                attachmentHeight = att.bounds.size.height
            }
        }
        #expect(abs(attachmentHeight - 600 * 0.6) < 1)
    }

    // MARK: Math miss 分支

    @Test func mathStaticMissEmitsTransparentAttachmentSizedByPointSize() {
        // mathBlock 在 BlockNode IR 里语义恒为 display（块级），所以高度 ≈ pointSize × 2
        var style = RenderStyle.default
        #if canImport(UIKit)
        style.bodyFont = .systemFont(ofSize: 17, weight: .regular)
        #elseif canImport(AppKit)
        style.bodyFont = .systemFont(ofSize: 17)
        #endif
        let renderer = AttributedStringRenderer(
            style: style, availableWidth: 600, placeholderMode: .static)
        let block = BlockNode.mathBlock(latex: "x = \\frac{a}{b}")
        let result = renderer.renderBlock(block)

        let full = NSRange(location: 0, length: result.length)
        var height: CGFloat = -1
        result.enumerateAttribute(.attachment, in: full) { v, _, _ in
            if let att = v as? NSTextAttachment, att.image == nil { height = att.bounds.size.height }
        }
        #expect(abs(height - 17 * 2.0) < 1)

        // marker 仍打，平台层据此异步触发
        var foundMarker = false
        result.enumerateAttribute(.markdownMathSource, in: full) { v, _, _ in
            if v is String { foundMarker = true }
        }
        #expect(foundMarker)
    }

    // MARK: cache hit 两 mode 一致

    @Test func svgCacheHitIdenticalAcrossModes() {
        let svg = #"<svg viewBox="0 0 480 320"></svg>"#
        let key = SVGBlockCacheKey(svg: svg, availableWidth: 600, rasterScale: 2, rendererGeneration: 0)
        // 造一个 dummy glyph
        #if canImport(UIKit)
        let dummyImage = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 50)).image { _ in }
        #elseif canImport(AppKit)
        let dummyImage = NSImage(size: CGSize(width: 100, height: 50))
        #endif
        let glyph = SVGBlockGlyph(image: dummyImage)

        for mode in [PlaceholderMode.static, .streaming] {
            var renderer = AttributedStringRenderer(
                style: .default, availableWidth: 600, placeholderMode: mode)
            renderer.svgRasterScale = 2
            renderer.svgRendererGeneration = 0
            renderer.svgBlockCache[key] = glyph
            let block = BlockNode.codeBlock(language: "svg", body: svg)
            let result = renderer.renderBlock(block)

            let full = NSRange(location: 0, length: result.length)
            var hitAttachmentWithImage = false
            result.enumerateAttribute(.attachment, in: full) { v, _, _ in
                if let att = v as? NSTextAttachment, att.image != nil { hitAttachmentWithImage = true }
            }
            #expect(hitAttachmentWithImage, "cache hit branch should emit attachment with image regardless of mode (\(mode))")
        }
    }

    // MARK: 关键 — static-miss attachment.bounds 必须 == hit 落地后 attachment.bounds
    //
    // 这是「文字 reflow / 位置跳动」体感的根因守门：miss → hit 切换瞬间，TextKit 用
    // attachment.bounds 排版；只要两路 bounds 完全相同，layout 就不会动。SwiftDraw 的
    // image.size 用 fit-without-upscale 算法（targetW = min(native, availableWidth)），
    // static-miss 必须同构造一份对应 size 的透明 attachment。

    @Test func svgStaticMissBoundsMatchSwiftDrawFitWithoutUpscale() {
        // 场景：viewBox 比 availableWidth 小（很常见，oh-my-exam 的题目柱状图都是
        // viewBox=0 0 480 320，view 宽 600+）。SwiftDraw 不放大，image.size = native。
        let svg = #"<svg viewBox="0 0 480 320"></svg>"#
        let availableWidth: CGFloat = 600

        // 1) Static-miss 路径
        let missRenderer = AttributedStringRenderer(
            style: .default, availableWidth: availableWidth, placeholderMode: .static)
        let missResult = missRenderer.renderBlock(BlockNode.codeBlock(language: "svg", body: svg))
        var missBounds = CGRect.zero
        missResult.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: missResult.length)
        ) { v, _, _ in
            if let att = v as? NSTextAttachment, att.image == nil { missBounds = att.bounds }
        }

        // 2) Hit 路径——seed cache with image at SwiftDraw 算出的 target = (480, 320)
        //    （fit-without-upscale: min(480, 600) = 480；高 480 × 320/480 = 320）
        let nativeTargetSize = CGSize(width: 480, height: 320)
        #if canImport(UIKit)
        let stub = UIGraphicsImageRenderer(size: nativeTargetSize).image { _ in }
        #elseif canImport(AppKit)
        let stub = NSImage(size: nativeTargetSize)
        #endif
        let key = SVGBlockCacheKey(
            svg: svg, availableWidth: availableWidth, rasterScale: 1, rendererGeneration: 0)
        var hitRenderer = AttributedStringRenderer(
            style: .default, availableWidth: availableWidth, placeholderMode: .static)
        hitRenderer.svgRasterScale = 1
        hitRenderer.svgRendererGeneration = 0
        hitRenderer.svgBlockCache[key] = SVGBlockGlyph(image: stub)
        let hitResult = hitRenderer.renderBlock(BlockNode.codeBlock(language: "svg", body: svg))
        var hitBounds = CGRect.zero
        hitResult.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: hitResult.length)
        ) { v, _, _ in
            if let att = v as? NSTextAttachment, att.image != nil { hitBounds = att.bounds }
        }

        // 关键不变量：miss.bounds == hit.bounds，保证 swap 瞬间 layout 不动
        #expect(abs(missBounds.size.width - hitBounds.size.width) < 0.001,
                "miss width \(missBounds.size.width) ≠ hit width \(hitBounds.size.width)")
        #expect(abs(missBounds.size.height - hitBounds.size.height) < 0.001,
                "miss height \(missBounds.size.height) ≠ hit height \(hitBounds.size.height)")
    }

    // MARK: math cache hit 两 mode 一致（钉住 static-mode "命中走 renderMath fall-through" 的安全论证）

    @Test func mathCacheHitIdenticalAcrossModes() {
        let latex = #"x = \frac{a}{b}"#
        var style = RenderStyle.default
        #if canImport(UIKit)
        style.bodyFont = .systemFont(ofSize: 17, weight: .regular)
        #elseif canImport(AppKit)
        style.bodyFont = .systemFont(ofSize: 17)
        #endif
        // 同 renderer 内部 mathProbe / renderMath 的 key 构造（display=true 因 mathBlock 恒块级）
        let key = MathCacheKey(
            latex: latex, display: true,
            pointSize: MathMetrics.effectivePointSize(textPointSize: 17, mathScale: style.mathScale),
            colorHex: MathMetrics.colorHex(style.mathColorOverride ?? style.textColor),
            rasterScale: 1,
            rendererGeneration: 0
        )
        #if canImport(UIKit)
        let dummyImage = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 32)).image { _ in }
        #elseif canImport(AppKit)
        let dummyImage = NSImage(size: CGSize(width: 80, height: 32))
        #endif
        let glyph = MathRenderedGlyph(image: dummyImage, baselineOffsetEx: 0)

        for mode in [PlaceholderMode.static, .streaming] {
            var renderer = AttributedStringRenderer(
                style: style, availableWidth: 600, placeholderMode: mode)
            renderer.mathRasterScale = 1
            renderer.mathRendererGeneration = 0
            renderer.mathCache[key] = glyph
            let block = BlockNode.mathBlock(latex: latex)
            let result = renderer.renderBlock(block)

            let full = NSRange(location: 0, length: result.length)
            var hitAttachmentWithImage = false
            result.enumerateAttribute(.attachment, in: full) { v, _, _ in
                if let att = v as? NSTextAttachment, att.image != nil { hitAttachmentWithImage = true }
            }
            #expect(
                hitAttachmentWithImage,
                "math cache hit 应在两 mode 下都通过 renderMath fall-through 走 hit 分支，产出携带 image 的 attachment（mode=\(mode)）")
        }
    }

    // MARK: 默认 mode 保留旧行为

    @Test func defaultModeIsStreaming() {
        let svg = #"<svg viewBox="0 0 480 320"></svg>"#
        // 不传 placeholderMode → 默认应 .streaming（向后兼容）
        let renderer = AttributedStringRenderer(style: .default, availableWidth: 600)
        let block = BlockNode.codeBlock(language: "svg", body: svg)
        let result = renderer.renderBlock(block)

        // streaming-miss 含源串文本
        #expect(result.string.contains("viewBox"))
    }
}
