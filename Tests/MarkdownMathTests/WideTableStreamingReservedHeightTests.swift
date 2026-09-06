import Foundation
import MarkdownCore
@testable import MarkdownPlatformView
import MarkdownRenderKit
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Bug 1 宽表子症（**重做**）—— 流式逐 token 重渲染下，宽表在主文本布局的
/// 「预留高」必须**从首次渲染起**就等于该表按 naturalWidth 的真实渲染高，
/// 否则紧随其后的 `## heading` 被 overlay 多出的部分永久覆盖。
///
/// 先前「保守占位 + 平台回写」架构已被运行时证伪：
///  - `DocumentParser.tailReparseStartIndex()`：尾块前一块是 table 时，重解析
///    从该 table 开始 → 流式追加表格**之后**的内容时，表格块**每个 token 都被
///    重渲染**，`overflowTablePlaceholder` 每 token 把占位高重置回保守
///    `initialHeight`，反复冲掉平台 `_writeBackOverflowTableHeight` 的回写。
///    回写要靠 `_pendingTableOverlaySyncStart` + 额外多趟 layout pass 才收敛，
///    而流式 token 比收敛快 → 用户看到的每一帧都是被重置回保守值的占位 →
///    下方 heading 落入 overlay 占据区间 → 永久重叠。
///  - `initialHeight = ceil(bodyLineHeight*(rows+1))+16` 结构性低估：忽略每行
///    段前/段后距、行距与 overlay chrome（实测 overlayH/initialHeight ≈ 1.5×，
///    rows 越多 overlap 的 delta 越大）。
///
/// 本守卫**驱动真实流式逐 token 路径**，且**只让每帧做首次渲染必经的最小
/// layout（`_blockFrameUnionForTesting` 内部的 `ensureLayout`），绝不额外驱动
/// `layoutSubviews`/`layout()` 多趟收敛**——这正是先前静态守卫的盲点：它每
/// token 跑 30 趟 `layoutIfNeeded` 让回写有充分时间收敛，掩盖了竞态。这里用
/// `setMarkdown` + `appendMarkdown` 逐 token 喂入「宽表 + 紧随 `## heading` +
/// 表后再若干段」，每 token 仅等 parse 落地（不驱动布局趟数），断言：
///  - (A) 宽表块真实预留高（`_blockFrameUnionForTesting` → 私有
///    `decorations.blockFrameUnion`，真实 TextKit2 layout fragment 几何）
///    == 该表按 naturalWidth 的真实渲染高（与生产 overlay
///    `TableContentView(...).frame.height` 同一单一真值源，构造性同源，±0.5）；
///  - (B) 紧随 heading 的 minY >= 表块底（无重叠），**每个流式检查点都成立**。
///
/// 修复后预留高从首次渲染起即正确（RenderKit 渲染时按 naturalWidth 实测真实
/// 高，与 overlay 同源），不依赖任何多趟回写收敛 → 单帧即等、无竞态。
@MainActor
@Suite("Wide table streaming reserved height == overlay height (Bug 1 redo)")
struct WideTableStreamingReservedHeightTests {
    /// 把一个明显宽于视图宽的多行表（needsScroll==true）切成若干 token，
    /// 表后紧跟 `## heading` 再加若干段 —— 这些尾段会让 tailReparseStartIndex
    /// 每次都从 table 重解析，表块每 token 被重渲染（复现竞态的关键）。
    private static func tokens() -> [String] {
        let longCell = "This particular cell carries a deliberately long sentence so the natural table width is far wider than the narrow view."
        let header = "| Alpha column header | Beta column header | Gamma column header |\n"
        let sep = "| --- | --- | --- |\n"
        let rows = (1 ... 4).map { i in
            "| Row \(i) \(longCell) | Row \(i) \(longCell) | Row \(i) \(longCell) |\n"
        }
        var toks: [String] = [header, sep]
        toks.append(contentsOf: rows)
        // 表后内容，逐 token 追加 —— 每个都触发 tailReparseStartIndex 从 table 重解析。
        toks.append("\n## 表格下方的小标题\n")
        toks.append("\n表后第一段普通文字。\n")
        toks.append("\n表后第二段普通文字，再加一点内容把流式拉长。\n")
        toks.append("\n表后第三段，继续追加以反复触发表块重渲染。\n")
        return toks
    }

    /// 仅等待流式 parse 把本 token 落地（blocks 数稳定一拍），**不**驱动任何
    /// `layoutSubviews`/`layout()` 收敛——模拟快速流式中 token 比多趟 layout
    /// 收敛更快的真实节奏。读取几何只走 `_blockFrameUnionForTesting` 内部的
    /// `ensureLayout`（首帧必经的最小布局），故被测的就是「未收敛」状态。
    private func waitForParse(_ view: MarkdownLabelView) async {
        var lastCount = -1
        var stable = 0
        for _ in 0 ..< 40 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
            let c = view.blocks.count
            if c == lastCount, c > 0 {
                stable += 1
                if stable >= 2 { return }
            } else {
                stable = 0
            }
            lastCount = c
        }
    }

    private func blockIndices(_ view: MarkdownLabelView) -> (table: Int?, heading: Int?) {
        var t: Int?
        var h: Int?
        for (idx, block) in view.blocks.enumerated() {
            switch block {
            case .table where t == nil: t = idx
            case .heading where h == nil && t != nil: h = idx
            default: break
            }
        }
        return (t, h)
    }

    /// 与生产 overlay 完全同一单一真值源算出该宽表的真实渲染高：
    /// `TableContentView(tableString:style:naturalWidth:).frame.height`，按
    /// naturalWidth 独立排版整表，与主文本布局无循环依赖。
    private func overlayTrueHeight(_ view: MarkdownLabelView, tableIndex: Int) -> CGFloat? {
        let viewWidth = view.bounds.width
        let probeRenderer = AttributedStringRenderer(style: view.renderStyle, availableWidth: viewWidth)
        let probeRendered = probeRenderer.render(view.blocks)
        var naturalWidth: CGFloat = 0
        probeRendered.enumerateAttribute(
            .markdownTableNaturalWidth,
            in: NSRange(location: 0, length: probeRendered.length)
        ) { value, _, stop in
            if let w = value as? CGFloat, w > 0 {
                naturalWidth = w
                stop.pointee = true
            }
        }
        guard naturalWidth > viewWidth + 0.5 else {
            return nil
        }
        let tableRenderer = AttributedStringRenderer(style: view.renderStyle, availableWidth: naturalWidth)
        let tableOnly = tableRenderer.renderBlock(view.blocks[tableIndex])
        let overlayContent = TableContentView(
            tableString: tableOnly,
            style: view.renderStyle,
            naturalWidth: naturalWidth
        )
        return overlayContent.frame.height
    }

    @Test("流式逐 token、仅首帧最小布局，宽表预留高恒等于 overlay 实测高（每个检查点无重叠）")
    func streamingPerTokenReservedHeightStaysEqualToOverlayHeight() async {
        let viewWidth: CGFloat = 360
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: viewWidth, height: 40000))
        // 初始一帧让 textContainer 宽度落定；此后不再驱动任何收敛布局趟数。
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #elseif canImport(AppKit)
        view.layoutSubtreeIfNeeded()
        #endif

        let toks = Self.tokens()
        var checkpointFailures: [String] = []
        var checkpointsVerified = 0

        for (tokenIdx, tok) in toks.enumerated() {
            if tokenIdx == 0 {
                view.setMarkdown(tok)
            } else {
                view.appendMarkdown(tok)
            }
            await self.waitForParse(view)
            // 故意不调用 layoutIfNeeded()/layoutSubtreeIfNeeded()：那会给
            // _writeBackOverflowTableHeight 的延迟再同步多趟收敛机会，掩盖竞态。
            // 几何只经 _blockFrameUnionForTesting 内部 ensureLayout 读取——这就
            // 是快速流式中用户真实看到的「回写尚未收敛」的那一帧。

            let (tIdxOpt, hIdxOpt) = self.blockIndices(view)
            guard let tIdx = tIdxOpt else {
                continue // 表块尚未 parse 出来
            }
            guard
                let overlayH = self.overlayTrueHeight(view, tableIndex: tIdx),
                let tf = view._blockFrameUnionForTesting(at: tIdx) else {
                continue // 表尚未宽到 needsScroll，或几何未就绪
            }

            let reservedH = tf.height
            let reservedVsOverlay = reservedH - overlayH
            if abs(reservedVsOverlay) > 0.5 {
                checkpointFailures.append(
                    "  [token \(tokenIdx)/\(toks.count - 1)] reservedH=\(reservedH) overlayH=\(overlayH) "
                        + "diff=\(reservedVsOverlay) (须 |·|≤0.5)"
                )
            }
            checkpointsVerified += 1

            // (B) 若 heading 已 parse 出来，断言无重叠。
            if let hIdx = hIdxOpt, let hf = view._blockFrameUnionForTesting(at: hIdx) {
                let overlayBottom = tf.minY + overlayH
                if hf.minY < overlayBottom - 0.5 {
                    checkpointFailures.append(
                        "  [token \(tokenIdx)/\(toks.count - 1)] heading minY=\(hf.minY) < "
                            + "overlayBottom=\(overlayBottom) (tableTop=\(tf.minY)+overlayH=\(overlayH)) → 重叠"
                    )
                }
            }
        }

        #expect(
            checkpointsVerified >= 3,
            "未在足够多的流式检查点验证到宽表（verified=\(checkpointsVerified)）—— 复现条件不成立"
        )
        #expect(
            checkpointFailures.isEmpty,
            """
            流式逐 token、仅首帧最小布局下宽表预留高 != overlay 实测高（Bug 1 宽表子症根因，竞态）：
            \(checkpointFailures.joined(separator: "\n"))
            每个流式检查点（含追加表后内容触发表块每 token 重渲染时）reservedH 都必须
            与 overlay 单一真值源构造性相等；heading 不得落入 overlay 占据区间。
            修复后预留高从首次渲染起即正确，不依赖多趟回写收敛 → 首帧即等、无竞态。
            """
        )
    }
}
