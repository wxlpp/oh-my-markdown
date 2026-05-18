import MarkdownCore
@testable import MarkdownRenderKit
import Testing

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// PR #4 R3 改动 #1 精确相等守卫：消除 `TableContentView` 双重布局后，
/// 两个高度入口必须对同一表内容产出**逐字节相等**的高（构造性相等＝
/// wide-table 根因不变量，绝不能重引两套高度算法）。
///
/// - 入口 A（建栈）：`TableMeasurement.height(of:naturalWidth:)`——
///   `overflowTablePlaceholder`（无既有 layoutManager）走的路径。
/// - 入口 B（复用已 laid-out）：自建一套与 `TableContentView` **完全相同
///   配置**的 TextKit 2 栈（`lineFragmentPadding = 0`、container 宽 =
///   naturalWidth、full `ensureLayout`），随后 `height(usingLaidOut:)`——
///   `TableContentView` init/update 走的路径。
///
/// 两入口最终都汇入私有 `heightCore`，故对同一内容必 `==`（零容差）。
/// 若有人让任一入口偏离 `heightCore` / 改 TextKit 配置使两路不再逐字节
/// 相等，本守卫立即 RED。
@Suite("TableMeasurement laid-out vs built-stack height equivalence (PR #4 R3 #1)")
struct TableMeasurementLaidOutEquivalenceTests {
    /// 复刻 `TableContentView` init 的 TextKit 2 栈配置，laid out 后回传
    /// 其 layoutManager 给 `height(usingLaidOut:)`（入口 B）。
    @MainActor
    private func heightViaSelfLaidOutStack(
        _ tableString: NSAttributedString, naturalWidth: CGFloat
    ) -> CGFloat {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        textContainer.lineFragmentPadding = 0
        layoutManager.textContainer = textContainer
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.attributedString = tableString
        textContainer.size = CGSize(width: naturalWidth, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return TableMeasurement.height(usingLaidOut: layoutManager)
    }

    private func renderedTable(_ source: String) throws -> (NSAttributedString, CGFloat) {
        let document = MarkdownDocument(parsing: source)
        let tableBlock = try #require(document.blocks.first)
        let probe = AttributedStringRenderer(style: .default, availableWidth: 180)
        let rendered = probe.render(document.blocks)
        let naturalWidth = try #require(
            rendered.attribute(.markdownTableNaturalWidth, at: 0, effectiveRange: nil) as? CGFloat
        )
        // Overlay-side full (non-overflow) table string at natural width —
        // exactly what `TableContentView` lays out.
        let overlayRenderer = AttributedStringRenderer(style: .default, availableWidth: naturalWidth)
        return (overlayRenderer.renderBlock(tableBlock), naturalWidth)
    }

    @MainActor
    @Test("窄 3 列表：建栈入口 == 复用已 laid-out 入口（零容差）")
    func narrowTableHeightsExactlyEqual() throws {
        let (table, naturalWidth) = try renderedTable("""
        | 阶段 | 耗时 | 说明 |
        |------|-----:|------|
        | 解析 | ~0.3 ms | cmark 原生解析 |
        | 渲染 | ~0.5 ms | AttributedString 生成 |
        | 排版 | ~0.8 ms | TextKit 2 行片段 |
        """)
        let built = TableMeasurement.height(of: table, naturalWidth: naturalWidth)
        let laidOut = heightViaSelfLaidOutStack(table, naturalWidth: naturalWidth)
        #expect(built > 0)
        #expect(built == laidOut,
                "built-stack \(built) must byte-for-byte equal laid-out \(laidOut) (constructive equality)")
    }

    @MainActor
    @Test("宽 9 列表：建栈入口 == 复用已 laid-out 入口（零容差，wide-table 根因不变量）")
    func wideTableHeightsExactlyEqual() throws {
        let (table, naturalWidth) = try renderedTable("""
        | 模型 | 提供商 | 上下文窗口 | 输出速度 | 多模态 | 函数调用 | 流式 | 延迟 | 价格/1M tokens |
        |------|--------|:----------:|:--------:|:------:|:--------:|:----:|:----:|---------------:|
        | GPT-4o | OpenAI | 128 k | 快 | ✅ | ✅ | ✅ | 低 | $5.00 |
        | Claude 4 Sonnet | Anthropic | 200 k | 快 | ✅ | ✅ | ✅ | 低 | $3.00 |
        | Gemini 2.5 Pro | Google | 1 M | 中 | ✅ | ✅ | ✅ | 中 | $3.50 |
        """)
        let built = TableMeasurement.height(of: table, naturalWidth: naturalWidth)
        let laidOut = heightViaSelfLaidOutStack(table, naturalWidth: naturalWidth)
        #expect(built > 0)
        #expect(built == laidOut,
                "wide-table built-stack \(built) must byte-for-byte equal laid-out \(laidOut)")
    }
}
