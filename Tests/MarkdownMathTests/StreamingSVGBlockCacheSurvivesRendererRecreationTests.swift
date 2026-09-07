import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing
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

    private func run(churnWidth: Bool) async -> (heldResolved: Bool, attachTrace: [Int]) {
        let gate = ViewSnapshotGate()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 10000))
        view.svgBlockRenderer = SVGRendererConfiguration(renderer: ChurnSVGRenderer())
        var source = ""
        for (index, token) in Self.tokenize(Self.svgSource).enumerated() {
            source += token
            if index == 0 { view.setMarkdown(token) } else { view.appendMarkdown(token) }
            if churnWidth, index % 4 == 0 {
                view.frame.size.width = index % 8 == 0 ? 322 : 318
            }
            await gate.wait(for: view) { view.currentSnapshot?.displayModel.source == source }
        }
        await gate.wait(for: view) {
            let state = view._renderedSVGBlockStateForTesting()
            return state.markerCount == 0 && state.attachmentCount == Self.expectedAttachments
        }
        var trace: [Int] = []
        for step in 0 ..< 8 {
            let width: CGFloat = churnWidth ? (step % 2 == 0 ? 322 : 318) : 320
            view.frame.size.width = width
            #if canImport(UIKit)
            view.layoutIfNeeded()
            #else
            view.layoutSubtreeIfNeeded()
            #endif
            await gate.wait(for: view) {
                guard view.currentSnapshot?.displayModel.availableWidth == width else { return false }
                let state = view._renderedSVGBlockStateForTesting()
                return state.markerCount == 0 && state.attachmentCount == Self.expectedAttachments
            }
            trace.append(view._renderedSVGBlockStateForTesting().attachmentCount)
        }
        view.dismantleRenderSession()
        return (trace == Array(repeating: Self.expectedAttachments, count: 8), trace)
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
        return .rendered(RenderedSVG(image: encodedTestImage(size: img.size)))
        #elseif canImport(AppKit)
        let img = NSImage(size: .init(width: 60, height: 40))
        img.lockFocus(); img.unlockFocus()
        return .rendered(RenderedSVG(image: encodedTestImage(size: img.size)))
        #else
        return .failed
        #endif
    }
}
