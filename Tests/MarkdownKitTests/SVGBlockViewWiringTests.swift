@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private final class ImgSVGRenderer: SVGBlockRendering, @unchecked Sendable {
    func render(svg _: String, availableWidth _: CGFloat, scale _: CGFloat) async -> SVGBlockOutcome {
        #if canImport(UIKit)
        let img = UIGraphicsImageRenderer(size: .init(width: 50, height: 30)).image { _ in }
        return .rendered(SVGBlockGlyph(image: img))
        #elseif canImport(AppKit)
        let img = NSImage(size: .init(width: 50, height: 30))
        img.lockFocus(); img.unlockFocus()
        return .rendered(SVGBlockGlyph(image: img))
        #else
        return .failed
        #endif
    }
}

@Suite("SVG block view wiring")
@MainActor
struct SVGBlockViewWiringTests {
    @Test("```svg 文档：占位标记可枚举，异步回写后产生 attachment")
    func placeholderThenAttachment() async {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 4000))
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #elseif canImport(AppKit)
        view.layoutSubtreeIfNeeded()
        #endif
        view.svgBlockRenderer = ImgSVGRenderer()
        for _ in 0 ..< 20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        view.setMarkdown("```svg\n<svg viewBox=\"0 0 10 6\"/>\n```\n\ntail")
        var hasAttachment = false
        for _ in 0 ..< 200 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 30_000_000)
            let s = view._renderedSVGBlockStateForTesting()
            if s.attachmentCount >= 1 { hasAttachment = true; break }
        }
        #expect(hasAttachment, "miss → 标记 → coordinator → 回写 → attachment 链路应完整")
    }
}
