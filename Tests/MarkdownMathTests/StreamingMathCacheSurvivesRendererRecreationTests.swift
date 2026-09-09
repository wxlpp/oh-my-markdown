import Foundation
@testable import MarkdownCore
@testable import MarkdownMath
@testable import MarkdownPlatformView
import MarkdownRenderKit
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Bug 1 — math 子症 真守卫：流式 + **持续宽度抖动**下，已解析的 math 字形
/// 必须熬过 `resetLayout()` 反复执行的 `_cachedRenderer = nil` renderer 重建，
/// 让生产渲染串**稳定保持**在「全部公式已解析」的形态（残留 latex 占位 = 0
/// 且 attachment 数 = 公式数），而非在「占位 ↔ attachment」间永振荡。
///
/// 根因（Phase 1 主机复现自证）：math 异步写回把字形/代际/scale 填进
/// transient `_cachedRenderer` 实例；流式期间 SwiftUI 在 ScrollView 内反复
/// `sizeThatFits` 致 `bounds.width` 抖动，反复命中 `resetLayout()` 的
/// `if abs(w - _cachedRendererWidth) > 0.5 { _cachedRenderer = nil }` 丢弃分支
/// → 刚填好的 renderer 被丢 → getter 见 nil 即 new 全新 renderer（mathCache
/// 空、gen=0、scale=1）→ `renderMath` 构出的 `MathCacheKey` 与已解析字形键
/// 永不匹配 → cache miss → 重渲 latex 文本 + `.markdownMathSource` →
/// `triggerMathLoads` 再派发 → 写回又被下次 resetLayout 丢弃 →
/// resolve→discard 死循环、公式渲染形态在「占位 ↔ 解析」间永振荡。
///
/// 与既有 `AsyncMathWritebackRelayoutTests` 的本质区别（后者漏掉本 bug 的
/// 盲点）：那个测试用**固定宽度**，`resetLayout` 的丢弃分支从不命中，math
/// 状态一直活在 `_cachedRenderer` 上，故能收敛。本守卫**在整个观测窗口持续
/// 抖动 view 宽度**，反复触发 renderer 重建竞态；并同时保留一个「宽度稳定
/// 同样收敛并保持」的健全性对照，证明守卫复现的是「宽度抖动竞态」本身而
/// 非静态场景。
///
/// 为什么观测量绑死真根因、无解耦旁路：观测的是 view 真正绘制的
/// `contentStorage.attributedString`（`_renderedMathStateForTesting`）。每个
/// 采样前都主动改 frame 宽度，逼迫下一次渲染走 `cachedRenderer` 重建路径。
/// 若已解析字形未被 view 持有 / getter 不重播种（buggy），重建出的空
/// renderer 必让 `renderMath` 回退占位 → 该采样必含残留 `.markdownMathSource`
/// → 守卫所要求的「连续 N 个采样都保持解析形态」必然达不到 → 红。修复让
/// math 字形/代际/scale 由 view 持有、getter 每次重建重播种、写回写 view
/// store —— 状态不再只活在被丢弃的 transient 实例上，故重建后仍命中、形态
/// 稳定保持 → 绿。
@MainActor
@Suite("Streaming math cache survives renderer recreation (Bug 1 math)")
struct StreamingMathCacheSurvivesRendererRecreationTests {
    /// 与 `AsyncMathWritebackRelayoutTests` 同款「缩高敏感」源：8 个会换行的
    /// inline `$...$`。后接若干普通段落，让流式追加把 firstChanged 推过 math
    /// 段、反复触发尾窗重渲。8 个 inline math span ⟺ 解析后应有 8 个 attachment。
    private static let expectedMathSpans = 8
    private static let shrinkSensitiveSource: String = {
        let spans = (0 ..< 8).map { "$x_{\($0)}$" }.joined(separator: " 填充文字 ")
        return """
        前置一段普通文字。

        \(spans)

        后置段一，继续追加内容把流式拉长以反复触发尾窗重解析。

        后置段二，再加一点内容继续推进 firstChanged。

        后置段三，最后一段普通文字收尾。
        """
    }()

    /// 与 ContentView.streamTokens 同款 ~2 char 切分。
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
        view.mathRenderer = MathRendererConfiguration(renderer: MathJaxRenderer())
        var source = ""
        for (index, token) in Self.tokenize(Self.shrinkSensitiveSource).enumerated() {
            source += token
            if index == 0 { view.setMarkdown(token) } else { view.appendMarkdown(token) }
            if churnWidth, index % 4 == 0 {
                view.frame.size.width = index % 8 == 0 ? 322 : 318
            }
            await gate.wait(for: view) { view.currentSnapshot?.displayModel.source == source }
        }
        await gate.wait(for: view) {
            let state = view._renderedMathStateForTesting()
            return state.mathSourceCount == 0 && state.attachmentCount == Self.expectedMathSpans
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
                let state = view._renderedMathStateForTesting()
                return state.mathSourceCount == 0 && state.attachmentCount == Self.expectedMathSpans
            }
            trace.append(view._renderedMathStateForTesting().attachmentCount)
        }
        view.dismantleRenderSession()
        return (trace == Array(repeating: Self.expectedMathSpans, count: 8), trace)
    }

    @Test("流式 + 持续宽度抖动下，已解析 math 必须稳定熬过反复 renderer 重建")
    func streamingMathSurvivesRepeatedRendererRecreationUnderWidthChurn() async {
        // 健全性对照：宽度稳定 → 已解析 math 必能稳定保持（无残留占位、
        // attachment 满）。若这都做不到，说明搭法/渲染器本身有问题，不是本 bug。
        let stable = await self.run(churnWidth: false)
        #expect(
            stable.heldResolved,
            "健全性对照失败：宽度稳定下已解析 math 都无法稳定保持（attachTrace=\(stable.attachTrace)），搭法/渲染器本身有问题，不是本 bug"
        )

        // 关键断言：持续宽度抖动下，已解析 math 仍必须稳定熬过反复的
        // resetLayout `_cachedRenderer=nil` 重建。buggy 下写回只活在被丢弃的
        // transient renderer → 每次重建空 renderer → renderMath 回退占位 →
        // 解析形态在占位↔attachment 间永振荡 → 永远凑不齐连续保持。
        let churn = await self.run(churnWidth: true)
        #expect(
            churn.heldResolved,
            "宽度抖动下已解析 math 未能稳定熬过 renderer 重建：attachment 形态在抖动窗口内振荡（attachTrace=\(churn.attachTrace)）—— resetLayout 的 _cachedRenderer=nil 反复丢弃刚写回的 mathCache/gen/scale，新 renderer 键永不匹配 → resolve→discard 死循环、公式渲染形态永振荡（Bug 1 math 子症根因）"
        )
    }
}
