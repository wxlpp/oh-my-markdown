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

    @Test("<0.5pt 宽度抖动下 svg 解析仍命中：trigger/render 共用 cachedRenderer.availableWidth（Copilot PR #5 R5 #1）")
    func subPixelWidthJitterStillResolves() async {
        // cachedRenderer 重建阈值 |Δw|>0.5pt。triggerSVGBlockLoads 若用
        // 原始 bounds.width 构 key 而 renderSVGBlock 用 cachedRenderer 持有
        // 的旧宽，<0.5pt 抖动下 key 永不匹配，marker 永留。
        // 复现路径：起手宽度 320 渲染普通文本（让 cachedRenderer 锁定 320）
        // → 抖到 320.3（<0.5pt，cachedRenderer 不重建）→ setMarkdown 切到
        // **新文档**（含 svg）触发 full updateContent + full-range trigger
        // → buggy 下 trigger 用 320.3 构 key、renderer 用 320 lookup → 永 miss。
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
        // 1) 起手在 320pt 下渲染 svg-free 文档，强制 cachedRenderer 锁定 320。
        view.setMarkdown("intro\n\nbody")
        for _ in 0 ..< 30 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        // 2) 抖到 320.3（<0.5pt）→ cachedRenderer 不会重建，仍持 width=320。
        view.frame = CGRect(x: 0, y: 0, width: 320.3, height: 4000)
        #if canImport(AppKit)
        view.layoutSubtreeIfNeeded()
        #endif

        // 3) 切到含 svg 的新文档（不共享旧 prefix）→ 走 full updateContent
        //    → triggerSVGBlockLoads 在 bounds.width=320.3 下被调用。
        //    buggy 下 key=(svg, 320.3, ...) 被写入 cache；renderSVGBlock
        //    用 cachedRenderer.availableWidth=320 构 lookup key → miss 永留。
        view.setMarkdown("```svg\n<svg viewBox=\"0 0 10 6\"/>\n```")
        var heldResolved = false
        var consecutive = 0
        for _ in 0 ..< 300 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 25_000_000)
            let s = view._renderedSVGBlockStateForTesting()
            if s.attachmentCount >= 1, s.markerCount == 0 {
                consecutive += 1
                if consecutive >= 6 { heldResolved = true; break }
            } else {
                consecutive = 0
            }
        }
        #expect(heldResolved, "sub-pixel 抖动下 svg 应解析为 attachment（trigger 与 render 必须共用 cachedRenderer.availableWidth；buggy 下永 miss）")
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
