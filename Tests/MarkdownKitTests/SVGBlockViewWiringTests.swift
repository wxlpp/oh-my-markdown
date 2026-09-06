import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private final class ImgSVGRenderer: SVGBlockRendering, @unchecked Sendable {
    let imageSize: CGSize
    init(_ size: CGSize = CGSize(width: 50, height: 30)) {
        self.imageSize = size
    }

    func render(svg _: String, availableWidth _: CGFloat, scale _: CGFloat) async -> SVGBlockOutcome {
        #if canImport(UIKit)
        let img = UIGraphicsImageRenderer(size: self.imageSize).image { _ in }
        return .rendered(SVGBlockGlyph(image: img))
        #elseif canImport(AppKit)
        let img = NSImage(size: self.imageSize)
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

    @Test("非nil→非nil renderer swap 真正生效：attachment 尺寸切换到新 renderer 输出（Copilot PR #5 R8 #1 + suppressed）")
    func nonNilToNonNilRendererSwapTakesEffect() async throws {
        // R1→R2 swap：若 didSet 不清 view-held cache，已解析的 attachment
        // 命中旧 cache 输出 R1 图，trigger 枚举不到 marker → R2 永不派发 →
        // swap 不生效。检验：R1 给 50×30 图、R2 给 120×80 图，swap 后
        // attachment 尺寸必须切换。
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 4000))
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #elseif canImport(AppKit)
        view.layoutSubtreeIfNeeded()
        #endif

        let r1 = ImgSVGRenderer(CGSize(width: 50, height: 30))
        view.svgBlockRenderer = r1
        for _ in 0 ..< 20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        view.setMarkdown("```svg\n<svg viewBox=\"0 0 10 6\"/>\n```")
        var r1Size: CGSize?
        for _ in 0 ..< 200 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 25_000_000)
            if let sz = view._firstSVGAttachmentImageSizeForTesting() {
                r1Size = sz; break
            }
        }
        let r1Got = try #require(r1Size)
        #expect(abs(r1Got.width - 50) <= 0.5)
        #expect(abs(r1Got.height - 30) <= 0.5)

        // swap 到 R2 —— 不同尺寸输出
        let r2 = ImgSVGRenderer(CGSize(width: 120, height: 80))
        view.svgBlockRenderer = r2

        // 等 attachment 尺寸切到 R2 的输出。若 didSet 不清 view-cache，
        // attachment 会一直停在 r1Size（50×30），永远拿不到 r2 的 120×80。
        var r2Size: CGSize?
        for _ in 0 ..< 300 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 25_000_000)
            if let sz = view._firstSVGAttachmentImageSizeForTesting(),
               abs(sz.width - 120) <= 0.5, abs(sz.height - 80) <= 0.5 {
                r2Size = sz; break
            }
        }
        let r2Got = try #require(r2Size, "R1→R2 swap 后 attachment 应换成 R2 输出（120×80），buggy 路径下永停 R1 的 50×30")
        #expect(abs(r2Got.width - 120) <= 0.5)
        #expect(abs(r2Got.height - 80) <= 0.5)
    }

    @Test("nil→非nil 切换源串不变时也能触发解析（Copilot PR #5 R7 #1 + suppressed）")
    func nilToNonNilTriggersResolutionWithoutSourceChange() async {
        // 复现 R7 死锁路径：先 setMarkdown 把 svg 块加入文档（renderer=nil
        // 状态下走 miss 路径，停在 marker），再注入 renderer。SwiftUI
        // representable 早 return（old==source）不调 setMarkdown，didSet
        // 必须主动 triggerSVGBlockLoads/updateContent 才能让 svg 解析。
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 4000))
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #elseif canImport(AppKit)
        view.layoutSubtreeIfNeeded()
        #endif
        // 注：先 setMarkdown，**不**注入 renderer
        // Task 4 之后 setMarkdown → renderMode = .static，miss 路径产出「透明 attachment
        // + .markdownSVGBlockSource marker」（不再是纯源码代码块），因此 "stuck in miss"
        // 信号从 `markerCount >= 1 AND attachmentCount == 0` 升级为
        // `markerCount >= 1 AND _firstSVGAttachmentImageSizeForTesting() == nil`
        // ——marker 在 + 无已解析图像 = 仍处 miss。
        view.setMarkdown("```svg\n<svg viewBox=\"0 0 10 6\"/>\n```\n\ntail")
        var markerPresent = false
        for _ in 0 ..< 100 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
            let s = view._renderedSVGBlockStateForTesting()
            if s.markerCount >= 1, view._firstSVGAttachmentImageSizeForTesting() == nil {
                markerPresent = true; break
            }
        }
        #expect(markerPresent, "前置：renderer 注入前应停在 miss marker 状态（static-miss 含透明 attachment 但无 image）")

        // 后注入 renderer，源串不变。didSet 必须触发解析。
        // 解析完成信号：hit 路径产出 attachment with image（无 marker）。
        view.svgBlockRenderer = ImgSVGRenderer()
        var resolved = false
        for _ in 0 ..< 300 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 25_000_000)
            let s = view._renderedSVGBlockStateForTesting()
            if s.markerCount == 0, view._firstSVGAttachmentImageSizeForTesting() != nil {
                resolved = true; break
            }
        }
        #expect(resolved, "nil→非nil 切换且源串不变时，svgBlockRenderer 的 didSet 必须主动触发 updateContent → triggerSVGBlockLoads → 解析")
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
        // 等异步光栅化落地为 attachment（hit 路径：有 image 的 attachment、无 marker）。
        var resolved = false
        for _ in 0 ..< 200 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 30_000_000)
            let s = view._renderedSVGBlockStateForTesting()
            if s.markerCount == 0, view._firstSVGAttachmentImageSizeForTesting() != nil {
                resolved = true; break
            }
        }
        #expect(resolved, "前置：renderer 注入后应有 attachment with image")

        // 切 nil → 应清 view-held cache + updateContent → 已渲染 svg 回到 miss
        // 形态。Task 4 之后 setMarkdown 路径下的 miss = 透明 attachment + marker，
        // 因此 degraded 信号是 `markerCount >= 1 AND attachment.image == nil`
        // （marker 回来 + image 没了 = 真的降回 miss）。
        view.svgBlockRenderer = nil
        var degraded = false
        for _ in 0 ..< 100 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
            let s = view._renderedSVGBlockStateForTesting()
            if s.markerCount >= 1, view._firstSVGAttachmentImageSizeForTesting() == nil {
                degraded = true; break
            }
        }
        #expect(degraded, "svgBlockRenderer = nil 应清 view-held svg cache 并通过 updateContent 把已渲染 svg 降级回 miss 形态（marker 在 + 无 image attachment）")
    }
}
