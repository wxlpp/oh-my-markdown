import Testing
import Foundation
@testable import MarkdownRenderKit
@testable import MarkdownPlatformView
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// SVG 块版本的「流式 + 持续宽度抖动 → 已解析字形必须熬过 renderer 重建」
/// 守卫。完全镜像 `StreamingMathCacheSurvivesRendererRecreationTests`：观测
/// 真实绘制的 `contentStorage.attributedString` 中 `.markdownSVGBlockSource`
/// 占位与 `.attachment` 数量，要求观测窗口内连续 N 个采样保持「占位=0 且
/// attachment=1」形态。守卫直接绑死真根因：view 持有 svgBlockCache/代际/scale
/// 并在 `cachedRenderer` getter 每次重建重播种；若回写只活在 transient
/// renderer 上，宽度抖动 → resetLayout 丢弃 → 重建空 renderer → 重回占位 →
/// 永振荡 → 守卫红。
///
/// 选择 `Tests/MarkdownMathTests/` 路径仅为镜像 math 同名测试位置，本测试
/// 不依赖 MarkdownMath 模块——`ChurnSVGRenderer` 在测试本地实现。
@MainActor
@Suite("Streaming SVG-block cache survives renderer recreation (mirror Bug 1 math)")
struct StreamingSVGBlockCacheSurvivesRendererRecreationTests {
    private static let expectedAttachments = 1
    private static let svgSource = "intro paragraph one two three\n\n```svg\n<svg viewBox=\"0 0 12 8\"/>\n```\n\ntail paragraph alpha beta gamma delta\n"

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let next = text.index(idx, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
            tokens.append(String(text[idx ..< next]))
            idx = next
        }
        return tokens
    }

    private func waitRendererLanded(_: MarkdownLabelView) async {
        for _ in 0 ..< 25 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func run(churnWidth: Bool) async -> (heldResolved: Bool, attachTrace: [Int]) {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 10_000))
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #elseif canImport(AppKit)
        view.layoutSubtreeIfNeeded()
        #endif

        view.svgBlockRenderer = ChurnSVGRenderer()
        await self.waitRendererLanded(view)

        let toks = Self.tokenize(Self.svgSource)
        for (ti, tok) in toks.enumerated() {
            if ti == 0 { view.setMarkdown(tok) } else { view.appendMarkdown(tok) }
            if churnWidth, ti % 4 == 0 {
                let w: CGFloat = (ti % 8 == 0) ? 322 : 318
                view.frame = CGRect(x: 0, y: 0, width: w, height: 10_000)
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        var attachTrace: [Int] = []
        var consecutiveResolved = 0
        var heldResolved = false
        var churnToggle = false
        for step in 0 ..< 320 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 18_000_000)
            if churnWidth, step % 3 == 0 {
                churnToggle.toggle()
                let w: CGFloat = churnToggle ? 322 : 318
                view.frame = CGRect(x: 0, y: 0, width: w, height: 10_000)
                #if canImport(AppKit)
                view.layoutSubtreeIfNeeded()
                #endif
            }
            let st = view._renderedSVGBlockStateForTesting()
            if attachTrace.last != st.attachmentCount {
                attachTrace.append(st.attachmentCount)
            }
            if st.markerCount == 0, st.attachmentCount == Self.expectedAttachments {
                consecutiveResolved += 1
                if consecutiveResolved >= 8 { heldResolved = true; break }
            } else {
                consecutiveResolved = 0
            }
        }
        return (heldResolved: heldResolved, attachTrace: attachTrace)
    }

    @Test("流式 + 持续宽度抖动下，已解析 svg 必须稳定熬过反复 renderer 重建")
    func churnHoldsResolved() async {
        let stable = await self.run(churnWidth: false)
        print("[SVG-GUARD] STABLE  heldResolved=\(stable.heldResolved) attachTrace=\(stable.attachTrace)")
        #expect(
            stable.heldResolved,
            "健全性对照失败：宽度稳定下已解析 svg 都无法稳定保持（attachTrace=\(stable.attachTrace)）"
        )

        let churn = await self.run(churnWidth: true)
        print("[SVG-GUARD] CHURN   heldResolved=\(churn.heldResolved) attachTrace=\(churn.attachTrace)")
        #expect(
            churn.heldResolved,
            "宽度抖动下已解析 svg 未能稳定熬过 renderer 重建：attachTrace=\(churn.attachTrace) —— resetLayout 反复丢弃 _cachedRenderer，需 view 持有 svgBlockCache/代际/scale 并在 cachedRenderer getter 重建重播种"
        )
    }
}

private final class ChurnSVGRenderer: SVGBlockRendering, @unchecked Sendable {
    func render(svg _: String, availableWidth _: CGFloat, scale _: CGFloat) async -> SVGBlockOutcome {
        #if canImport(UIKit)
        let img = UIGraphicsImageRenderer(size: .init(width: 60, height: 40)).image { _ in }
        return .rendered(SVGBlockGlyph(image: img))
        #elseif canImport(AppKit)
        let img = NSImage(size: .init(width: 60, height: 40))
        img.lockFocus(); img.unlockFocus()
        return .rendered(SVGBlockGlyph(image: img))
        #else
        return .failed
        #endif
    }
}
