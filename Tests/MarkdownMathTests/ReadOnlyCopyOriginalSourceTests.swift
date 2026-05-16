import Testing
import Foundation
@testable import MarkdownPlatformView
import MarkdownCore
import MarkdownRenderKit
@testable import MarkdownMath
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Bug 4 — 只读视图选中复制丢公式/图片/表格 的非 GUI 复现 / 回归钉死。
///
/// 根因（Phase 1 取证）：命中态 `AttributedStringRenderer` 把 math / image 渲染成
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
/// 该测试走 copy 的**真实路径**（iOS `copy(_:)` / AppKit `performCopy()`），
/// 读回真实剪贴板，断言拷贝串包含原始 markdown 源。改前必为红（attachment=`￼`、
/// 表格丢管道、math 占位也无法构成源）。
@MainActor
@Suite("Read-only copy yields original markdown source (Bug 4)")
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

    /// 把全文选中并走真实 copy 路径，读回系统剪贴板字符串。
    private func selectAllAndCopy(_ view: MarkdownLabelView) -> String {
        view._selectEntireDocumentForTesting()
        #if canImport(UIKit)
        view.copy(nil)
        return UIPasteboard.general.string ?? ""
        #elseif canImport(AppKit)
        view.copy(nil)
        return NSPasteboard.general.string(forType: .string) ?? ""
        #else
        return ""
        #endif
    }

    @Test("选中全部后复制，剪贴板应为覆盖块的原始 markdown 源（公式/图片/表格/标题不丢）")
    func copyYieldsOriginalMarkdownSource() async {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 360, height: 10_000))
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #elseif canImport(AppKit)
        view.layoutSubtreeIfNeeded()
        #endif

        // 注入真实 MathJaxRenderer：math 异步解析后会变成命中态裸 attachment，
        // 这是「copy 丢源」最强的复现条件（占位态也丢，但命中态彻底证明
        // 不能依赖 attributedString.string）。
        view.mathRenderer = MathJaxRenderer()
        for _ in 0 ..< 20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        view.setMarkdown(Self.markdown)

        // 等流式 parse 落地（多个块）。
        var parsed = false
        for _ in 0 ..< 60 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
            if view.blocks.count >= 5 { parsed = true; break }
        }
        #expect(parsed, "流式 parse 未在超时内完成")

        // 等异步 math 字形回写命中（math attachment 命中态），最大化复现强度。
        for _ in 0 ..< 200 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        let copied = self.selectAllAndCopy(view)
        let objectReplacementCount = copied.filter { $0 == "\u{FFFC}" }.count

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
        // 还原源后不应再有 attachment 占位符残留。
        #expect(
            objectReplacementCount == 0,
            "拷贝串仍含 \(objectReplacementCount) 个 object-replacement 占位符（应为原始源 0 个）：\(copied)"
        )
    }
}
