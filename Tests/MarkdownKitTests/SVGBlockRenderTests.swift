import Testing
import Foundation
@testable import MarkdownRenderKit
@testable import MarkdownCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite("SVG code-block rendering branch")
struct SVGBlockRenderTests {
    private func render(_ block: BlockNode, cache: [SVGBlockCacheKey: SVGBlockGlyph] = [:],
                        width: CGFloat = 320) -> NSAttributedString {
        var r = AttributedStringRenderer(style: .default, availableWidth: width)
        r.svgBlockCache = cache
        return r.renderBlock(block)
    }
    @Test("language svg (case/space-insensitive), cache miss → highlighted code block + marker attr")
    func missKeepsHighlightedCodeWithMarker() {
        let out = render(.codeBlock(language: " SVG ", body: "<svg/>"))
        var found = false
        out.enumerateAttribute(.markdownSVGBlockSource, in: NSRange(location: 0, length: out.length)) { v, _, _ in
            if (v as? String) == "<svg/>" { found = true }
        }
        #expect(found)
        #expect(out.length > 0)
        #expect(!out.string.contains("\u{FFFC}"))
    }
    @Test("cache hit → single centered attachment sized to image, origin.y == 0")
    func hitProducesCenteredAttachment() {
        let sized = SVGBlockGlyph(image: makeImage(width: 200, height: 90))
        let key = SVGBlockCacheKey(svg: "<svg/>", availableWidth: 320, rasterScale: 1, rendererGeneration: 0)
        let out = render(.codeBlock(language: "svg", body: "<svg/>"), cache: [key: sized])
        var att: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { v, _, _ in
            att = v as? NSTextAttachment
        }
        let a = try! #require(att)
        #expect(a.bounds.size.width == 200)
        #expect(a.bounds.size.height == 90)
        #expect(a.bounds.origin.y == 0)
        let para = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(para?.alignment == .center)
    }
    @Test("non-svg code block unchanged (regression)")
    func nonSvgUnchanged() {
        let a = render(.codeBlock(language: "swift", body: "let x = 1"))
        let b: NSAttributedString = {
            let r = AttributedStringRenderer(style: .default, availableWidth: 320)
            return r.renderBlock(.codeBlock(language: "swift", body: "let x = 1"))
        }()
        #expect(a.isEqual(to: b))
    }
}

private func makeImage(width: CGFloat, height: CGFloat) -> PlatformImage {
    #if canImport(UIKit)
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in }
    #elseif canImport(AppKit)
    return NSImage(size: NSSize(width: width, height: height))
    #else
    return PlatformImage()
    #endif
}
