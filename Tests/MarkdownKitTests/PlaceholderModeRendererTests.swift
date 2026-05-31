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

        // 应含 NSTextAttachment 且 image == nil（透明），bounds 按 viewBox aspect
        var foundTransparentAttachment = false
        result.enumerateAttribute(.attachment, in: full) { v, _, _ in
            guard let att = v as? NSTextAttachment else { return }
            if att.image == nil {
                foundTransparentAttachment = true
                let expectedH: CGFloat = 600 * (320.0 / 480.0)
                #expect(abs(att.bounds.size.height - expectedH) < 1)
                #expect(abs(att.bounds.size.width - 600) < 1)
            }
        }
        #expect(foundTransparentAttachment)
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
