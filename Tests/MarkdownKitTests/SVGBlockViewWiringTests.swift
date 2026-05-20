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

    @Test("svgBlockRenderer = nil 真正降级已渲染 svg → 回到 marker 形态（Copilot PR #5 R4 #1）")
    func nilRendererDegradesResolved() async {
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
        // 等异步光栅化落地为 attachment
        var resolved = false
        for _ in 0 ..< 200 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 30_000_000)
            let s = view._renderedSVGBlockStateForTesting()
            if s.attachmentCount >= 1, s.markerCount == 0 { resolved = true; break }
        }
        #expect(resolved, "前置：renderer 注入后应有 attachment")

        // 切 nil → 应清 view-held cache + updateContent → 已渲染 svg 回到 miss
        // 形态（markerCount >=1 占位 + attachmentCount == 0）
        view.svgBlockRenderer = nil
        var degraded = false
        for _ in 0 ..< 100 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
            let s = view._renderedSVGBlockStateForTesting()
            if s.attachmentCount == 0, s.markerCount >= 1 { degraded = true; break }
        }
        #expect(degraded, "svgBlockRenderer = nil 应清 view-held svg cache 并通过 updateContent 把已渲染 svg 降级回高亮源码 + .markdownSVGBlockSource 占位")
    }
}
