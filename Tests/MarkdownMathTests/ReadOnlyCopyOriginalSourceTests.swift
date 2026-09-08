import Foundation
import MarkdownCore
@testable import MarkdownMath
@testable import MarkdownPlatformView
import MarkdownRenderKit
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Bug 4 — 只读视图选中复制丢公式/图片/表格 的非 GUI 复现 / 回归钉死。
///
/// 根因（Phase 1 取证）：命中态 `MaterializationFixture` 把 math / image 渲染成
/// 裸 `NSTextAttachment`（latex / url / alt 全丢），表格走纯文本 `\t`；而
/// `MarkdownLabelView` 的 copy 是自定义实现，只把 `attributedString.string`
/// 按选区做 `substring` 写进剪贴板 —— attachment 处是 `\u{FFFC}`，
/// 表格的管道全丢 ⇒ 粘贴出来公式/图片彻底消失、表格结构丢失。
///
/// 用户已定语义：选中内容复制出**原始 markdown 源**（`$x^2$` / `![alt](url)` /
/// `| a | b |` / `# 标题` 等原文）。修复在视图侧建「渲染块 → 原始源子串」映射
/// （基于 `parsedBlocks[i].sourceRange` 的 UTF-8 字节区间 + `lastParsedSource`），
/// copy 时把选区覆盖到的块的原始源连续子串写进剪贴板，iOS / AppKit 对称。
///
/// Task 9 起，这个语义归**显式的源码复制命令**（`copyMarkdownSource(_:)`）；
/// 原生 Copy / Cmd-C 改为精确复制选区的渲染文本，不再把选区扩张成整块源码。
/// 本测试因此走源码复制路径，仍钉死「公式/图片/表格不丢原文」这条核心保证。
@MainActor
@Suite("Read-only copy yields original markdown source (Bug 4)", .timeLimit(.minutes(1)))
struct ReadOnlyCopyOriginalSourceTests {
    private static let markdown = """
    # 标题

    普通段落一行。

    行内公式 $x^2$ 收尾。

    $$\\sum_{i=1}^n i$$

    ![alt](https://e.com/p.png)

    | a | b |
    |---|---|
    | 1 | 2 |
    """

    /// 把全文选中并取出生产 copy 路径会写入剪贴板的原始源串。
    ///
    /// 经 `markdownSourceSelectionResult()` 取串：生产的
    /// `copyMarkdownSource(_:)` 只是把它写进剪贴板，两条路径共用同一实现，
    /// 覆盖面等价，但不读写系统剪贴板——消除全局副作用与 headless CI flaky。
    private func selectAllAndCopy(_ view: MarkdownLabelView) -> String {
        view._selectEntireDocumentForTesting()
        return view.markdownSourceSelectionResult()?.text ?? ""
    }

    @Test("选中全部后复制，剪贴板应为覆盖块的原始 markdown 源（公式/图片/表格/标题不丢）")
    func copyYieldsOriginalMarkdownSource() async {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 360, height: 10000))
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #elseif canImport(AppKit)
        view.layoutSubtreeIfNeeded()
        #endif

        // 注入真实 MathJaxRenderer：math 异步解析后会变成命中态裸 attachment，
        // 这是「copy 丢源」最强的复现条件（占位态也丢，但命中态彻底证明
        // 不能依赖 attributedString.string）。
        view.mathRenderer = MathRendererConfiguration(renderer: MathJaxRenderer())
        let gate = ViewSnapshotGate()
        view.setMarkdown(Self.markdown)
        await gate.wait(for: view) {
            view.currentSnapshot?.displayModel.source == Self.markdown
                && view._renderedMathStateForTesting().mathSourceCount == 0
        }
        #expect(view.blocks.count >= 5)
        #expect(view._renderedMathStateForTesting().attachmentCount >= 2)

        let copied = self.selectAllAndCopy(view)
        let objectReplacementCount = copied.count(where: { $0 == "\u{FFFC}" })

        // 诊断输出（改前红时人工核对实测内容）。
        print("=== Bug4 copied string ===\n\(copied)\n=== object-replacement count: \(objectReplacementCount) ===")

        // 核心断言：拷贝串必须包含原始 markdown 源。
        #expect(copied.contains("# 标题"), "拷贝串丢失标题原文 '# 标题'：\(copied)")
        #expect(copied.contains("$x^2$"), "拷贝串丢失行内公式原文 '$x^2$'：\(copied)")
        #expect(
            copied.contains("$$\\sum_{i=1}^n i$$"),
            "拷贝串丢失块级公式原文 '$$\\sum_{i=1}^n i$$'：\(copied)"
        )
        #expect(
            copied.contains("![alt](https://e.com/p.png)"),
            "拷贝串丢失图片原文 '![alt](https://e.com/p.png)'：\(copied)"
        )
        #expect(copied.contains("| a | b |"), "拷贝串丢失表格原文 '| a | b |'：\(copied)")
        #expect(copied.contains("普通段落一行。"), "拷贝串丢失普通段落原文：\(copied)")
        // 全选覆盖了每一个块，源码复制必须自报 exact，不能声称扩张。
        view._selectEntireDocumentForTesting()
        #expect(view.markdownSourceSelectionResult()?.granularity == .exact)
        // 原生 Copy 不再吐原始源码：它给的是读者看到的文本。
        let rendered = view.renderedSelectionResult()
        #expect(rendered?.text.contains("# 标题") == false, "原生 Copy 不应包含 markdown 语法")
        #expect(rendered?.text.contains("标题") == true)
        // 这是唯一真正命中 attachment 的套件（上面已断言 attachmentCount >= 2），
        // 所以「渲染复制不留占位符」这条只有在这里才是非平凡的。
        #expect(
            rendered?.text.contains("\u{FFFC}") == false,
            "渲染复制仍含 object-replacement：\(rendered?.text ?? "")"
        )
        // 还原源后不应再有 attachment 占位符残留。
        #expect(
            objectReplacementCount == 0,
            "拷贝串仍含 \(objectReplacementCount) 个 object-replacement 占位符（应为原始源 0 个）：\(copied)"
        )
    }
}
