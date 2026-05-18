@testable import MarkdownCore
import Testing

/// PR #4 R3 改动 #2 复现守卫：数学定界符对**不得跨越代码区**。
///
/// 修复前：`MathScanner` 的三条闭合搜索路径
/// （`findClose` 用于 `$$…$$`、`findCloseBackslash` 用于 `\(…\)` / `\[…\]`、
/// `findInlineDollarClose` 用于行内 `$…$`）会**跳过**代码区内的配对符却
/// **继续扫过**代码区，匹配到 fenced/indented 代码块**之后**的闭合符，
/// 使数学 span 吞掉整个代码块；随后 `MathSentinel` 把该 span 从源码移除，
/// 代码块在 IR 中彻底消失——与引发整段 saga 的根因同类（定界符吞结构内容）。
///
/// 修复后：三条路径扫描途中遇 `codeMask[k] == true`（进入代码区）即硬边界
/// `return nil`，该 open 退为字面文本，代码块在 IR 中完整保留。
///
/// 每条断言两点：
///  1. `MathScanner.scan` **不产出**跨代码块的 span（该 open 为字面）；
///  2. 经 `MarkdownDocument(parsing:)` 后 fenced 代码块**完整保留**
///     （未被 `MathSentinel` 随伪 span 移除）。
@Suite("MathScanner code-region hard stop (PR #4 R3 #2)")
struct MathScannerCodeRegionHardStopTests {
    private static let codeBody = "let x = 1\nprint(x)"

    private func codeBlockBodies(_ source: String) -> [String] {
        MarkdownDocument(parsing: source).blocks.compactMap { b -> String? in
            if case .codeBlock(_, let body) = b { return body } else { return nil }
        }
    }

    /// 代码块在 IR 中完整保留（某个 codeBlock body 含完整代码体）。
    /// 用 `contains` 而非 `==`：cmark 会给 fenced code body 补尾换行
    /// （`"let x = 1\nprint(x)\n"`），这是解析器固有归一化、与本守卫
    /// 「代码块未被伪 span 移除」无关。
    private func codeBlockSurvives(_ source: String) -> Bool {
        codeBlockBodies(source).contains { $0.contains(Self.codeBody) }
    }

    /// 任何 span 覆盖到 fenced 代码块字节区间 → span 跨越了代码区（违例）。
    private func anySpanCoversCodeFence(_ source: String) -> Bool {
        let bytes = Array(source.utf8)
        let needle = Array(Self.codeBody.utf8)
        // 代码体首字节在源码中的 UTF-8 偏移（用于判定 span 是否吞进代码区）。
        guard let codeByteStart = (0 ... (bytes.count - needle.count)).first(where: { i in
            Array(bytes[i ..< i + needle.count]) == needle
        }) else {
            Issue.record("code body not found in source")
            return true
        }
        return MathScanner.scan(source).contains { $0.range.contains(codeByteStart) }
    }

    @Test("$$ … $$ 不跨 fenced 代码块（开界为字面，代码块保留）")
    func dollarDollarDoesNotSpanCodeFence() {
        let source = "$$ a\n```\n\(Self.codeBody)\n```\nb $$\n"
        #expect(!anySpanCoversCodeFence(source),
                "$$ delimiter pair must not span the fenced code block")
        #expect(codeBlockSurvives(source),
                "fenced code block must survive in IR (not removed by MathSentinel)")
    }

    @Test("\\[ … \\] 不跨 fenced 代码块（开界为字面，代码块保留）")
    func backslashBracketDoesNotSpanCodeFence() {
        let source = "\\[ a\n```\n\(Self.codeBody)\n```\nb \\]\n"
        #expect(!anySpanCoversCodeFence(source),
                "\\[ \\] delimiter pair must not span the fenced code block")
        #expect(codeBlockSurvives(source),
                "fenced code block must survive in IR (not removed by MathSentinel)")
    }

    @Test("\\( … \\) 不跨 fenced 代码块（开界为字面，代码块保留）")
    func backslashParenDoesNotSpanCodeFence() {
        let source = "\\( a\n```\n\(Self.codeBody)\n```\nb \\)\n"
        #expect(!anySpanCoversCodeFence(source),
                "\\( \\) delimiter pair must not span the fenced code block")
        #expect(codeBlockSurvives(source),
                "fenced code block must survive in IR (not removed by MathSentinel)")
    }

    @Test("行内 $ … $ 不跨 fenced 代码块（开界为字面，代码块保留）")
    func inlineDollarDoesNotSpanCodeFence() {
        // 无段落空行：唯一阻断「吞代码块」的就是 codeMask 硬停。
        let source = "x $a\n```\n\(Self.codeBody)\n```\nb$ y\n"
        #expect(!anySpanCoversCodeFence(source),
                "inline $ delimiter pair must not span the fenced code block")
        #expect(codeBlockSurvives(source),
                "fenced code block must survive in IR (not removed by MathSentinel)")
    }

    /// 合法 math：open 与 close 同在代码区外、未跨代码区 → 硬停不得误伤。
    /// （硬停语义是「跨代码区才放弃」，这里证明它单调收敛、不放宽也不误停。）
    @Test("未跨代码区的合法 math 不被硬停误伤（含 close 后另有代码块）")
    func legitimateMathOutsideCodeRegionStillScanned() {
        let source = "$$x^2$$\n\n```\n\(Self.codeBody)\n```\n"
        let spans = MathScanner.scan(source)
        #expect(spans.count == 1, "exactly one block-math span expected, got \(spans.count)")
        #expect(spans.first?.latex == "x^2")
        #expect(spans.first?.display == true)
        #expect(codeBlockSurvives(source),
                "code block after a closed math span must still survive")
    }
}
