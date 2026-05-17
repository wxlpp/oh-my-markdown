import Testing
import Foundation
@testable import MarkdownPlatformView
import MarkdownCore
import MarkdownRenderKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Bug 1 宽表子症 — 含宽表（横向滚动）的文档里，宽表在主文本布局的「预留高」
/// 与 overlay 实际渲染高由两套互不相关算法独立得出、恒偏小，导致紧随其后的块
/// （此处 heading）被 overlay 多出的 `delta` 永久覆盖（流式结束仍重叠）。
///
/// Phase 1 取证（运行时日志确证，勿质疑）：宽表分支每次 `_syncTableOverlays`，
/// `overlayH = TableContentView(...).frame.height`（按 naturalWidth 独立渲染整表，
/// 不依赖主文本布局）恒 > `reservedH = blockFrameUnion(table).height`（占位 NBSP
/// 行数算法）。下方块按 `tableTop + reservedH` 定位，却被 overlay 占据的
/// `tableTop … tableTop + overlayH` 覆盖 → 永久重叠。
///
/// 修复后契约：宽表在主文本里的预留高必须**精确等于** overlay 实测高，故下方
/// heading 的布局起点 Y == 表块顶 + overlayH（容差 ≤ 0.5pt）。
///
/// 真守卫——观测量绑定真实驱动 TextKit2 布局的原语：
///  - `overlayH` 由 `TableContentView(...).frame.height` 得出，这正是生产 overlay
///    使用的**同一单一高度真值源**（按 naturalWidth 独立排版，与主文本无循环依赖）。
///  - heading 的 `minY` 来自 `_blockFrameUnionForTesting`（→ 私有
///    `decorations.blockFrameUnion`），是真实 TextKit2 layout fragment 的几何，
///    该几何随且仅随宽表占位 attachment 的 `bounds` 高度变化。若把「写回精确高」
///    那一步还原，占位高坍回保守值 → heading minY 偏小 → 断言必红（git-反证）。
@MainActor
@Suite("Wide table reserved height == overlay height (Bug 1 wide-table sub-symptom)")
struct WideTablePlaceholderHeightTests {
    /// 一个明显宽于视图宽（needsScroll==true）的多行表 + 紧随一个 heading。
    /// 每列塞长文本把 naturalWidth 顶到远大于 360。
    private static let markdown: String = {
        let longCell = "This particular cell carries a deliberately long sentence so the natural table width is far wider than the view."
        let header = "| Alpha column header | Beta column header | Gamma column header |"
        let sep = "| --- | --- | --- |"
        let rows = (1 ... 5).map { i in
            "| Row \(i) \(longCell) | Row \(i) \(longCell) | Row \(i) \(longCell) |"
        }.joined(separator: "\n")
        return """
        \(header)
        \(sep)
        \(rows)

        ## 表格下方的小标题
        """
    }()

    @Test("宽表预留高精确等于 overlay 实测高，下方 heading 无重叠")
    func wideTableReservedHeightEqualsOverlayHeight() async {
        let viewWidth: CGFloat = 360
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: viewWidth, height: 20_000))
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #elseif canImport(AppKit)
        view.layoutSubtreeIfNeeded()
        #endif

        view.setMarkdown(Self.markdown)

        // 等流式 parse 落地：table block + heading block（共 2 个顶层块）。
        var parsed = false
        for _ in 0 ..< 60 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
            if view.blocks.count >= 2 { parsed = true; break }
        }
        #expect(parsed, "流式 parse 未在超时内完成（blocks=\(view.blocks.count)）")

        // 定位 table / heading 的块下标。
        var tableIndex: Int?
        var headingIndex: Int?
        for (idx, block) in view.blocks.enumerated() {
            switch block {
            case .table: tableIndex = idx
            case .heading: headingIndex = idx
            default: break
            }
        }
        let tIdx = try! #require(tableIndex, "未找到 table 块")
        let hIdx = try! #require(headingIndex, "未找到 heading 块")

        // 反复跑布局 + overlay 同步直至稳定（流式 + 异步回写收敛）。
        var lastTableMinY: CGFloat = .nan
        var lastTableHeight: CGFloat = .nan
        var lastHeadingMinY: CGFloat = .nan
        for _ in 0 ..< 60 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
            #if canImport(UIKit)
            view.setNeedsLayout()
            view.layoutIfNeeded()
            #elseif canImport(AppKit)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            #endif
            guard
                let tf = view._blockFrameUnionForTesting(at: tIdx),
                let hf = view._blockFrameUnionForTesting(at: hIdx) else {
                continue
            }
            if
                abs(tf.minY - lastTableMinY) < 0.5,
                abs(tf.height - lastTableHeight) < 0.5,
                abs(hf.minY - lastHeadingMinY) < 0.5 {
                lastTableMinY = tf.minY
                lastTableHeight = tf.height
                lastHeadingMinY = hf.minY
                break
            }
            lastTableMinY = tf.minY
            lastTableHeight = tf.height
            lastHeadingMinY = hf.minY
        }
        #expect(
            !lastTableMinY.isNaN && !lastTableHeight.isNaN && !lastHeadingMinY.isNaN,
            "块几何未稳定"
        )

        // 独立计算 overlay 的真实渲染高 —— 与生产 overlay 完全同一单一真值源：
        // `TableContentView(tableString:style:naturalWidth:).frame.height`，
        // 按 naturalWidth 独立排版整表，不依赖主文本布局（无循环依赖）。
        let probeRenderer = AttributedStringRenderer(style: view.renderStyle, availableWidth: viewWidth)
        let probeRendered = probeRenderer.render(view.blocks)
        // 找到表块在渲染串里的起点偏移以读 naturalWidth（块顺序与 blocks 一致；
        // 直接在整串里搜 .markdownTableNaturalWidth 第一处即可，文档仅一个宽表）。
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
        #expect(naturalWidth > viewWidth + 0.5, "构造的表不够宽（naturalWidth=\(naturalWidth)，需 > \(viewWidth)）—— 非 needsScroll，复现条件不成立")

        let tableRenderer = AttributedStringRenderer(style: view.renderStyle, availableWidth: naturalWidth)
        let tableOnly = tableRenderer.renderBlock(view.blocks[tIdx])
        let overlayContent = TableContentView(
            tableString: tableOnly,
            style: view.renderStyle,
            naturalWidth: naturalWidth
        )
        let overlayH = overlayContent.frame.height
        #expect(overlayH > 0, "overlay 高未算出")

        // 核心断言 A（根因精确契约 / 真守卫）：宽表在主文本里**真实预留高**必须
        // 精确等于 overlay 实测高。`lastTableHeight` 来自 `_blockFrameUnionForTesting`
        // → 私有 `decorations.blockFrameUnion`，是真实 TextKit2 layout fragment
        // 几何，随且仅随宽表占位 attachment 的 `bounds` 高度变化（无解耦计数器）。
        // 修复前两套无关算法得出的高恒不等（实测差 16；占位坍缩后差 152）→ 红。
        // 还原「写回精确高」那一步（git-反证）→ 占位回保守初值 → 该差变大 → 红。
        let reservedVsOverlay = lastTableHeight - overlayH
        #expect(
            abs(reservedVsOverlay) <= 0.5,
            """
            宽表预留高 != overlay 实测高（Bug 1 宽表子症根因）：
              reservedH (主文本真实预留) = \(lastTableHeight)
              overlayH  (TableContentView 单一真值源) = \(overlayH)
              reservedH - overlayH = \(reservedVsOverlay)  (须 |·| ≤ 0.5)
            两套互不相关算法得出的高必须由「overlay 实测高回写占位 attachment」收敛为同一值。
            """
        )

        // 核心断言 B（无重叠）：heading 的布局起点 Y 不得落在 overlay 占据的
        // [tableTop, tableTop+overlayH) 区间内 —— 即 heading 必须起始于 overlay
        // 底边或其下方（块间分隔/标题段前距属正常常量布局，故用 >= 而非 ==）。
        // 修复前 reservedH < overlayH 时 heading.minY < tableTop+overlayH → 重叠 → 红。
        let overlayBottom = lastTableMinY + overlayH
        #expect(
            lastHeadingMinY >= overlayBottom - 0.5,
            """
            宽表下方 heading 仍与 overlay 重叠：
              tableTop       = \(lastTableMinY)
              overlayH       = \(overlayH)
              overlayBottom  = \(overlayBottom)  (tableTop + overlayH)
              heading minY   = \(lastHeadingMinY)  (须 >= overlayBottom)
            heading 起点落在 overlay 占据区间内 → 被永久覆盖（Bug 1 宽表子症）。
            """
        )
    }
}
