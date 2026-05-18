@testable import MarkdownCore
import Testing

/// PR #4 第 4 轮 Copilot review 改动 #1 守卫（backfill 派生块清 fingerprint）。
///
/// 根因：`MathBackfill.resolve` 曾把 backfill 后**所有**派生块仍用**原**
/// `ParsedBlockNode.fingerprint`（与 `sourceRange`）重包，即使 backfill 把含
/// 块级数学的 paragraph 拆成 `[paragraph, mathBlock, paragraph]`（一原块产出
/// >1 块、块类型变化），或把含行内数学的 paragraph 内容改写成含 `.math` 的
/// 新 inline 数组（单块但内容变）。`MarkdownLabelView` 的块 diff
/// （`markdownBlocksMatch`：双方 fingerprint 均非 nil 时**优先 fingerprint
/// 相等**判定，否则才比 `BlockNode` 相等）于是会复用 pre-backfill fingerprint，
/// 把**已变**块误判**未变**而跳过流式/增量重渲（与本 PR/saga 同类的增量
/// 正确性 bug）。
///
/// 修复：`resolve` 仅当对某位置「原样透传（输出恰为 `[node.block]`）」时才
/// 保留原 fingerprint/sourceRange；任何拆分/改写产出的派生块 fingerprint 与
/// sourceRange 一律置 nil，强制 diff 回退到语义正确的 `BlockNode` 相等。
@Suite("MathBackfill derived-block fingerprint (PR #4 round 4 change #1)")
struct MathBackfillDerivedBlockFingerprintTests {
    /// 忠实复刻 `MarkdownLabelView.markdownBlocksMatch` 的判定逻辑（该函数
    /// 在 MarkdownPlatformView 内为 `private`，此处按其精确语义复算，避免
    /// 守卫自造口径）：双方 fingerprint 均非 nil → 优先比 fingerprint；
    /// 否则比 `BlockNode` 相等。
    private func blocksMatch(_ prev: ParsedBlockNode, _ next: ParsedBlockNode) -> Bool {
        if let pf = prev.fingerprint, let nf = next.fingerprint {
            return pf == nf
        }
        return prev.block == next.block
    }

    /// 复刻 `firstChangedMarkdownBlockIndex`：返回首个「按上面 diff 判定不匹配」
    /// 的块下标（共享前缀长度内）。
    private func firstChanged(_ prev: [ParsedBlockNode], _ next: [ParsedBlockNode]) -> Int {
        let shared = min(prev.count, next.count)
        for i in 0 ..< shared where !blocksMatch(prev[i], next[i]) {
            return i
        }
        return shared
    }

    /// 守卫 A（diff 层，最决定性）：一个含块级 `$$…$$` 的 paragraph 被
    /// backfill 拆成 `[paragraph, mathBlock, paragraph]`；对该区做一处会
    /// 改变其某 emitted `BlockNode` 的修改后，块 diff 必须把已变块判为
    /// 「changed」。bug 下拆分派生块全部复用同一 pre-backfill fingerprint →
    /// 已变位置与「同 fingerprint 的兄弟」比对 → 误判「未变」跳过更新。
    @Test("含块级数学的 paragraph 拆分后，改其内容块 diff 必须检出 changed（不复用 stale fingerprint）")
    func splitParagraphDerivedBlocksDiffDetectsChange() {
        // prev：段落内嵌块级 `$$…$$` → 拆成 [paragraph, mathBlock, paragraph]。
        let prevSource = "lead text $$E=mc^2$$ trailing text"
        // new：改掉首尾散文（仍含同一块级数学，仍拆 3 块），派生块
        // BlockNode 与 prev 不同（paragraph 文本变了）。
        let newSource = "LEAD TEXT $$E=mc^2$$ TRAILING TEXT"

        let prev = MarkdownDocument(parsing: prevSource).parsedBlocks
        let next = MarkdownDocument(parsing: newSource).parsedBlocks

        // 前置：该 paragraph 确实被 backfill 拆成 >1 块（构成回归场景）。
        #expect(prev.count >= 2, "prev should split into >=2 derived blocks, got \(prev.count)")
        #expect(next.count >= 2, "next should split into >=2 derived blocks, got \(next.count)")

        // 拆分派生块 fingerprint/sourceRange 必须为 nil（修复后），否则即 bug。
        let prevNonNilFP = prev.filter { $0.fingerprint != nil }.count
        #expect(
            prevNonNilFP == 0,
            "split-derived blocks must carry nil fingerprint; non-nil count = \(prevNonNilFP)/\(prev.count)"
        )
        let prevNonNilSR = prev.filter { $0.sourceRange != nil }.count
        #expect(
            prevNonNilSR == 0,
            "split-derived blocks must carry nil sourceRange; non-nil count = \(prevNonNilSR)/\(prev.count)"
        )

        // 至少一个对齐位置的 BlockNode 真的变了（test setup 有效性）。
        let shared = min(prev.count, next.count)
        let firstBlockDiffIndex = (0 ..< shared).first { prev[$0].block != next[$0].block }
        #expect(firstBlockDiffIndex != nil, "test setup invalid: no BlockNode actually changed")

        // 关键断言：diff 必须把首个「BlockNode 变了」的位置检出为 changed。
        // bug（复用 stale fingerprint）下拆分兄弟块共享同一 fingerprint，
        // diff 在 BlockNode 已变处仍返回「match」→ firstChanged 越过它。
        if let firstDiff = firstBlockDiffIndex {
            let fc = firstChanged(prev, next)
            #expect(
                fc <= firstDiff,
                "block diff must detect changed derived block at \(firstDiff); firstChanged=\(fc) (stale fp masked it)"
            )
        }
    }

    /// 守卫 B（端到端流式）：流式逐 token 喂出含块级数学的段落（产出 backfill
    /// 拆分），稳定后再追加一个新块；`parsingAppend` 增量结果须与
    /// `MarkdownDocument(parsing:)` 全量**逐块一致**（diff 未因复用
    /// pre-backfill fingerprint 把已变/新增块漏掉）。
    @Test("流式喂入含块级数学段落 + 追加新块，增量与全量逐块一致")
    func streamingMathParagraphThenAppendMatchesFullParse() {
        let base = """
        # Heading

        intro $$a+b$$ tail
        """
        let appended = base + "\n\nBrand new appended paragraph with $c$ inside."

        // 逐 2-char token 流式喂到 base 稳定。
        var src = ""
        var prev = ""
        var doc = MarkdownDocument(parsedBlocks: [])
        var idx = base.startIndex
        while idx < base.endIndex {
            let nx = base.index(idx, offsetBy: 2, limitedBy: base.endIndex) ?? base.endIndex
            src += base[idx ..< nx]
            doc = MarkdownDocument(parsedBlocks: doc.parsedBlocks)
                .parsingAppend(to: src, previousSource: prev)
            prev = src
            idx = nx
        }
        // 对该区追加一个会改变文档块结构的新块。
        doc = doc.parsingAppend(to: appended, previousSource: src)

        let full = MarkdownDocument(parsing: appended)
        #expect(
            doc.blocks == full.blocks,
            "incremental must equal full parse; incremental=\(doc.blocks.count) full=\(full.blocks.count)"
        )
    }

    /// 守卫 C（行内数学单块改写也清 fingerprint）：行内 `$x$` 不拆块但段落
    /// 内容被改写（text → text+.math+text），输出单块但 != 原 block →
    /// 仍须清 fingerprint/sourceRange，否则复用旧 paragraph fingerprint。
    @Test("含行内数学的单 paragraph 内容改写也清 fingerprint/sourceRange")
    func inlineMathRewrittenParagraphClearsFingerprint() {
        let blocks = MarkdownDocument(parsing: "alpha $x$ omega").parsedBlocks
        #expect(blocks.count == 1, "inline math stays a single paragraph, got \(blocks.count)")
        #expect(blocks[0].fingerprint == nil, "rewritten inline-math paragraph must have nil fingerprint")
        #expect(blocks[0].sourceRange == nil, "rewritten inline-math paragraph must have nil sourceRange")
    }

    /// 守卫 D（透传不退化）：纯文本/标题/代码块等未被 backfill 改写的块仍
    /// 保留原 fingerprint（fast-path 不因本次修复无谓退化）。
    @Test("未被 backfill 改写的纯文本/标题/代码块仍保留 fingerprint（fast-path 不退化）")
    func untouchedBlocksRetainFingerprint() {
        let source = """
        # Plain heading no math

        Just a normal paragraph with no math at all.

        ```swift
        let x = 1
        ```
        """
        let blocks = MarkdownDocument(parsing: source).parsedBlocks
        let nilFP = blocks.filter { $0.fingerprint == nil }.count
        #expect(nilFP == 0, "passthrough blocks must keep fingerprint; nil count = \(nilFP)/\(blocks.count)")
        let nilSR = blocks.filter { $0.sourceRange == nil }.count
        #expect(nilSR == 0, "passthrough blocks must keep sourceRange; nil count = \(nilSR)/\(blocks.count)")
    }
}
