import Markdown

// MARK: - MarkdownDocument

/// A parsed Markdown document represented as an array of ``BlockNode``s.
///
/// Internally this uses swift-markdown (cmark-gfm) for parsing.  The result
/// is converted to MarkdownCore's own IR so that higher-level targets never
/// need to depend on swift-markdown directly.
public struct MarkdownDocument: Sendable, Equatable {
    /// Parse a Markdown source string into a document synchronously.
    /// cmark-gfm has no cancellation hook: cancelling its calling task does not
    /// stop an entered parse. UI consumers admit this work through ParseExecutor.
    public init(parsing source: String) {
        self.blockStorage = PersistentValues(Self.parsePipeline(source))
        self.workRecorder = nil
    }

    /// 数学感知解析管线：扫描 → 哨兵替换 → swift-markdown 解析 → 数学回填。
    /// `init(parsing:)` 与增量尾窗重解析共用此管线，保证两路语义完全一致。
    package static func parsePipeline(_ source: String) -> [ParsedBlockNode] {
        let mathSpans = MathScanner.scan(source)
        let sub = MathSentinel.substitute(source: source, spans: mathSpans)
        let swiftMarkdownDoc = Markdown.Document(parsing: sub.transformed)
        let raw = try! DocumentParser().parse(source: sub.transformed, document: swiftMarkdownDoc)
        // swift-markdown 在「变换串」上解析，sourceRange/fingerprint 都是变换串字节空间。
        // 但 init(parsing:) 与 parsingAppend 都按「原始源码」消费这些区间
        // （reparseStart / utf8Index / offset(byUTF8:) / hasPrefix / 尾窗切片）。
        // 哨兵替换会改变字节长度（行内 `$a$` 3 字节 → `S0S` 9 字节；用户文本里的
        // U+10FE00 也会 +4 转义），故此处把每个 sourceRange 映回原始源码字节空间，
        // 并据此从「原始源码」重算 fingerprint，保证两路与 spec §4.3 自洽。
        let mapped = Self.mapToOriginalSpace(raw, sub: sub, originalSource: source)
        return MathBackfill.resolve(mapped, table: sub.table)
    }

    package static func parsePlainTail(_ source: String, metrics: inout ParseWorkMetrics, afterCmark: () -> Void = {}) throws -> [ParsedBlockNode] {
        try Task.checkCancellation()
        metrics.cmarkInputBytes = ParseWorkMetrics.saturatingAdd(metrics.cmarkInputBytes, source.utf8.count)
        let tree = Markdown.Document(parsing: source)
        afterCmark()
        try Task.checkCancellation()
        let parser = DocumentParser(checkCancellation: { try Task.checkCancellation() })
        defer {
            metrics.mappingBytes = ParseWorkMetrics.saturatingAdd(metrics.mappingBytes, parser.mappingBytes)
            metrics.materializationBytes = ParseWorkMetrics.saturatingAdd(metrics.materializationBytes, parser.materializationBytes)
            metrics.recordMetadata(parser.metadataBytes)
        }
        return try parser.parse(source: source, document: tree)
    }

    package static func parseMathTail(
        _ source: String,
        codeRegionsNeeded: Bool,
        hasReserved: Bool,
        metrics: inout ParseWorkMetrics,
        afterCmark: () -> Void = {}
    ) throws -> ([ParsedBlockNode], MathScanner.ScanResult) {
        if let result = try source.utf8.withContiguousStorageIfAvailable({ bytes in
            try self.parseMathTail(
                source,
                bytes: bytes,
                codeRegionsNeeded: codeRegionsNeeded,
                hasReserved: hasReserved,
                metrics: &metrics,
                afterCmark: afterCmark
            )
        }) { return result }
        let bytes = Array(source.utf8)
        metrics.materializationBytes = ParseWorkMetrics.saturatingAdd(metrics.materializationBytes, bytes.count)
        return try bytes.withUnsafeBufferPointer {
            try self.parseMathTail(
                source,
                bytes: $0,
                codeRegionsNeeded: codeRegionsNeeded,
                hasReserved: hasReserved,
                metrics: &metrics,
                afterCmark: afterCmark
            )
        }
    }

    private static func parseMathTail(
        _ source: String,
        bytes: UnsafeBufferPointer<UInt8>,
        codeRegionsNeeded: Bool,
        hasReserved: Bool,
        metrics: inout ParseWorkMetrics,
        afterCmark: () -> Void
    ) throws -> ([ParsedBlockNode], MathScanner.ScanResult) {
        let scan = try MathScanner.analyze(bytes: bytes, metrics: &metrics, codeRegionsNeeded: codeRegionsNeeded)
        let sub = try MathSentinel.substitute(source: source, bytes: bytes, spans: scan.spans, hasReserved: hasReserved, metrics: &metrics)
        try Task.checkCancellation()
        metrics.cmarkInputBytes = ParseWorkMetrics.saturatingAdd(metrics.cmarkInputBytes, sub.transformed.utf8.count)
        let tree = Markdown.Document(parsing: sub.transformed)
        afterCmark()
        try Task.checkCancellation()
        let parser = DocumentParser(checkCancellation: { try Task.checkCancellation() })
        let raw: [ParsedBlockNode]
        do {
            defer {
                metrics.mappingBytes = ParseWorkMetrics.saturatingAdd(metrics.mappingBytes, parser.mappingBytes)
                metrics.materializationBytes = ParseWorkMetrics.saturatingAdd(metrics.materializationBytes, parser.materializationBytes)
                metrics.recordMetadata(parser.metadataBytes)
            }
            raw = try parser.parse(source: sub.transformed, document: tree, fingerprints: false)
        }
        let mapped = try raw.map { node in
            try Task.checkCancellation()
            return ParsedBlockNode(block: node.block, sourceRange: node.sourceRange.map {
                MarkdownSourceRange(
                    lowerBound: sub.originalByteOffset(forTransformed: $0.lowerBound, atUpperBound: false),
                    upperBound: sub.originalByteOffset(forTransformed: $0.upperBound, atUpperBound: true)
                )
            })
        }
        metrics.recordMetadata(mapped.count * MemoryLayout<ParsedBlockNode>.stride)
        let work = ParseWorkAccumulator(metrics, cancellable: true)
        let resolved = sub.table.isEmpty && !hasReserved ? mapped : try MathBackfill.resolve(mapped, table: sub.table, work: work)
        metrics = work.metrics
        let mapper = SourceRangeMapper(source: source, checkCancellation: {}, buildLineStarts: false)
        let blocks = try resolved.map { node in
            try Task.checkCancellation()
            guard let range = node.sourceRange else { return node }
            let fingerprint = try mapper.fingerprint(in: range, checkCancellation: { try Task.checkCancellation() }, onProgress: { metrics.mappingBytes = ParseWorkMetrics.saturatingAdd(metrics.mappingBytes, $0) })
            return ParsedBlockNode(block: node.block, sourceRange: range, fingerprint: fingerprint)
        }
        metrics.recordMetadata(blocks.count * MemoryLayout<ParsedBlockNode>.stride)
        return (blocks, scan)
    }

    /// 把 raw 解析块的 `sourceRange`（变换串字节空间）映回原始源码字节空间，
    /// 并用原始源码切片重算 `fingerprint`（原始空间区间 ↔ 原始源码，自洽）。
    private static func mapToOriginalSpace(
        _ raw: [ParsedBlockNode],
        sub: MathSentinel.SubstituteResult,
        originalSource: String
    ) -> [ParsedBlockNode] {
        let originalMapper = SourceRangeMapper(source: originalSource, checkCancellation: {})
        return raw.map { node in
            guard let xfRange = node.sourceRange else { return node }
            let lower = sub.originalByteOffset(forTransformed: xfRange.lowerBound, atUpperBound: false)
            let upper = sub.originalByteOffset(forTransformed: xfRange.upperBound, atUpperBound: true)
            guard lower <= upper else {
                return ParsedBlockNode(block: node.block, sourceRange: nil, fingerprint: nil)
            }
            let origRange = MarkdownSourceRange(lowerBound: lower, upperBound: upper)
            return ParsedBlockNode(
                block: node.block,
                sourceRange: origRange,
                fingerprint: originalMapper.fingerprint(in: origRange, checkCancellation: {})
            )
        }
    }

    public init(parsedBlocks: [ParsedBlockNode]) {
        // Programmatic top-level nodes have no source anchor. Their ordinal is
        // local to this document, deterministic across equivalent reconstruction,
        // and in a separate identity domain from parser/backfill source anchors.
        self.blockStorage = PersistentValues(parsedBlocks.enumerated().map { ordinal, node in
            guard node.documentOrdinal != nil else { return node }
            return ParsedBlockNode(block: node.block, sourceRange: node.sourceRange, fingerprint: node.fingerprint, sourceAnchor: 0, documentOrdinal: ordinal)
        })
        self.workRecorder = nil
    }

    package init(blockStorage: PersistentValues<ParsedBlockNode>, recorder: ParseWorkRecorder? = nil) {
        self.blockStorage = blockStorage; self.workRecorder = recorder
    }

    package let blockStorage: PersistentValues<ParsedBlockNode>
    package let workRecorder: ParseWorkRecorder?
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.blockStorage == rhs.blockStorage
    }

    /// Top-level block nodes in document order.
    /// Explicitly materializes a flat array in O(number of blocks).
    public var blocks: [BlockNode] {
        var metrics = ParseWorkMetrics()
        let result = self.blockStorage.materializedMap(\.block, metrics: &metrics)
        self.workRecorder?.recordFacade(metrics)
        return result
    }

    /// Top-level block nodes paired with their UTF-8 source ranges when available.
    /// Explicitly materializes a flat array in O(number of blocks).
    public var parsedBlocks: [ParsedBlockNode] {
        var metrics = ParseWorkMetrics()
        let result = self.blockStorage.materializedMap({ $0 }, metrics: &metrics)
        self.workRecorder?.recordFacade(metrics)
        return result
    }

    /// Parse the complete appended source with full Markdown semantics.
    /// This compatibility entry point is O(newSource.utf8.count): it carries no
    /// scanner provenance, so appended definitions may invalidate earlier blocks.
    /// The streaming view pipeline uses the stateful, admitted tail parser.
    public func parsingAppend(to newSource: String, previousSource: String) -> MarkdownDocument {
        // This compatibility API carries no scanner provenance or reference table.
        // A source prefix alone cannot establish that earlier blocks are immutable:
        // appended definitions and cross-block math can change them retroactively.
        // Stateful streaming uses IncrementalSourceBuffer instead.
        MarkdownDocument(parsing: newSource)
    }

    /// internal（非 private）：测试守卫复用同一套 reparse 边界计算，
    /// 与 `parsingAppend` 内部口径完全一致，避免守卫自算边界产生口径漂移。
    func tailReparseStartIndex() -> Int {
        guard self.parsedBlocks.count >= 2 else {
            return max(self.parsedBlocks.count - 1, 0)
        }
        let tailIndex = self.parsedBlocks.count - 1
        let previousIndex = tailIndex - 1
        if case .table = self.parsedBlocks[previousIndex].block {
            return previousIndex
        }
        return tailIndex
    }

    /// previousSource 在 reparse 边界之后的尾窗内是否处于「数学定界符未闭合」状态。
    /// 复用 MathScanner 的代码区/转义规则：若尾窗内存在任何开界符但 scan 未把它
    /// 配成 span，说明闭合符尚未出现，追加文本可能闭合它 → 必须全量。
    ///
    /// 收窄理由（保正确性、消 O(n²)）：reparse 边界**之前**的稳定前缀块，其
    /// 数学 span 已被上次解析正确定型，且 pandoc 行内 `$…$` 不跨段落空行 /
    /// 块边界（详见 `MathScanner` 类型 doc 规则 3），append 无法回头重开它们；
    /// 只有边界**之后**（尾窗，append 真正能交互的区域）的未闭合开界符才需
    /// 强制全量。`fromReparseBoundary` = previousSource UTF-8 字节空间的 reparse
    /// 起点（由 `parsingAppend` 用既有边界逻辑安全求出后传入；无法安全求边界
    /// 时 `parsingAppend` 维持现状全量兜底，不走本谓词）。
    ///
    /// `MathScanner.scan` / `codeRegionMask` 仍按**完整 source** 计算，以保持
    /// 代码区 / 转义 / span 配对语义正确；仅把「判定 return true 的扫描区间」
    /// 限定为 `i >= fromReparseBoundary`（`isEscaped` / `isCovered` / `mask`
    /// 仍用全局索引）。
    ///
    /// 保守性：尾窗内任何裸露未配对的 `$` / `\(` / `\[`（包括 `price $5` 这类
    /// 非数学散文）都会保守地强制全量重解析——符合 spec §4.3，并非最小化。
    static func previousSourceHasOpenMathDelimiter(
        _ source: String, fromReparseBoundary: Int = 0
    ) -> Bool {
        let bytes = Array(source.utf8)
        // 廉价早退：既无 `$`(0x24) 也无 `\`(0x5C) 时不可能有任何数学开界符，
        // 直接返回，避免常见无数学流式场景为重扫描/掩码付费。
        if !bytes.contains(0x24), !bytes.contains(0x5C) { return false }
        // `MathScanner.scan` 返回的 spans 左→右**有序且不重叠**：scan 主循环
        // 命中一个 span 后把游标推进到 `close + closeLen`（越过整个 span），
        // 故下一个 span 的 `open >= 上一个 span 的 upperBound`，构造上严格
        // 有序、互不相交。下方指针游走依赖此不变量。
        let spans = MathScanner.scan(source)
        // 有序 span 指针游走替代 O(totalSpanBytes) 的 bool 覆盖掩码：扫描 `i`
        // 单调不减（仅 `i += 1`，起点 clamp 后固定），维护一个 span 下标
        // 指针，循环内推进它越过所有 `upperBound <= i` 的 span；`isCovered(i)`
        // ＝ 当前 span 存在且 `range.contains(i)`，O(1) 摊还。与原 bool-mask
        // **严格等价**（i 被覆盖 ⟺ i ∈ 某 span.range），不再每 token 付
        // O(totalSpanBytes) 建掩码。
        var spanIdx = 0
        func isCovered(_ i: Int) -> Bool {
            while spanIdx < spans.count, spans[spanIdx].range.upperBound <= i {
                spanIdx += 1
            }
            return spanIdx < spans.count && spans[spanIdx].range.contains(i)
        }
        let mask = MathScanner.codeRegionMask(source: source)
        // 扫描从尾窗起点开始（mask/escape/covered 仍按全局索引计算，仅判定
        // 区间收窄）；clamp 进合法范围以防越界。
        var i = max(0, min(fromReparseBoundary, bytes.count))
        while i < bytes.count {
            if mask[i] { i += 1; continue }
            var bs = 0, k = i - 1
            while k >= 0, bytes[k] == 0x5C {
                bs += 1; k -= 1
            }
            let escaped = bs % 2 == 1
            if !escaped, !isCovered(i) {
                if bytes[i] == 0x24 { return true }
                if bytes[i] == 0x5C, i + 1 < bytes.count,
                   bytes[i + 1] == 0x28 || bytes[i + 1] == 0x5B { return true }
            }
            i += 1
        }
        return false
    }
}

// MARK: - MarkdownSourceRange

/// A UTF-8 source range in the original Markdown source.
public struct MarkdownSourceRange: Sendable, Equatable {
    public init(lowerBound: Int, upperBound: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public let lowerBound: Int
    public let upperBound: Int

    fileprivate func offset(byUTF8 offset: Int) -> MarkdownSourceRange {
        MarkdownSourceRange(lowerBound: self.lowerBound + offset, upperBound: self.upperBound + offset)
    }
}

// MARK: - ParsedBlockNode

/// A block-level node with the source range that produced it, when swift-markdown provides one.
public struct ParsedBlockNode: Sendable, Equatable {
    public init(block: BlockNode, sourceRange: MarkdownSourceRange? = nil, fingerprint: UInt64? = nil) {
        self.block = block
        self.sourceRange = sourceRange
        self.fingerprint = fingerprint
        self.sourceAnchor = sourceRange?.lowerBound ?? 0
        self.splitOrdinal = 0
        self.documentOrdinal = sourceRange == nil ? 0 : nil
    }

    package init(block: BlockNode, sourceRange: MarkdownSourceRange?, fingerprint: UInt64?, sourceAnchor: Int, splitOrdinal: Int = 0, documentOrdinal: Int? = nil) {
        self.block = block; self.sourceRange = sourceRange; self.fingerprint = fingerprint
        self.sourceAnchor = sourceAnchor; self.splitOrdinal = splitOrdinal
        self.documentOrdinal = documentOrdinal
    }

    public let block: BlockNode
    public let sourceRange: MarkdownSourceRange?
    public let fingerprint: UInt64?
    /// Immutable original-source start survives math backfill's nil range policy.
    package let sourceAnchor: Int
    package let splitOrdinal: Int
    /// Non-nil only for public, programmatically constructed source-less nodes.
    /// Parser/backfill constructors explicitly preserve their real source anchor.
    package let documentOrdinal: Int?
    package var lineage: UInt64 {
        let role: UInt64 = switch self.block {
        case .paragraph: 1
        // Public blocks accept any Int; match the renderer's heading role clamp
        // before unsigned conversion or arithmetic, including Int.min/Int.max.
        case .heading(let level, _): 2 + UInt64(min(max(level, 1), 6))
        case .codeBlock: 10
        case .blockquote: 11
        case .bulletList: 12
        case .orderedList: 13
        case .table: 14
        case .thematicBreak: 15
        case .htmlBlock: 16
        case .mathBlock: 17
        }
        // Fixed-size identity fields only; no content/end/fingerprint is hashed.
        var hash: UInt64 = 14_695_981_039_346_656_037
        // Public source ranges are signed values. Preserve all anchor bits rather
        // than narrowing to an unsigned value (which traps for negative ranges).
        let identity = self.documentOrdinal.map(UInt64.init) ?? UInt64(bitPattern: Int64(self.sourceAnchor))
        let discriminator = self.documentOrdinal == nil ? UInt64(self.splitOrdinal) : UInt64.max
        for value in [identity, role, discriminator] {
            var bits = value
            for _ in 0 ..< 8 {
                hash = (hash ^ (bits & 255)) &* 1_099_511_628_211; bits >>= 8
            }
        }
        return hash
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block == rhs.block && lhs.sourceRange == rhs.sourceRange && lhs.fingerprint == rhs.fingerprint
    }
}

// MARK: - DocumentParser

private final class DocumentParser {
    private let checkCancellation: () throws -> Void
    private(set) var mappingBytes = 0
    private(set) var materializationBytes = 0
    private(set) var metadataBytes = 0
    init(checkCancellation: @escaping () throws -> Void = {}) {
        self.checkCancellation = checkCancellation
    }

    func parse(source: String, document: Markdown.Document, fingerprints: Bool = true) throws -> [ParsedBlockNode] {
        let mapper = try SourceRangeMapper(source: source, checkCancellation: self.checkCancellation, onProgress: { bytes, metadata in
            self.mappingBytes = ParseWorkMetrics.saturatingAdd(self.mappingBytes, bytes)
            self.metadataBytes = ParseWorkMetrics.saturatingAdd(self.metadataBytes, metadata)
        })
        var result: [ParsedBlockNode] = []
        result.reserveCapacity(document.childCount)
        for markup in document.children {
            try self.checkCancellation()
            guard let block = try self.parseBlock(markup) else { continue }
            let range = mapper.range(from: markup.range)
            let fingerprint = fingerprints ? try range.flatMap { try mapper.fingerprint(in: $0, checkCancellation: self.checkCancellation, onProgress: { self.mappingBytes = ParseWorkMetrics.saturatingAdd(self.mappingBytes, $0) }) } : nil
            self.metadataBytes = ParseWorkMetrics.saturatingAdd(self.metadataBytes, MemoryLayout<ParsedBlockNode>.stride)
            result.append(ParsedBlockNode(block: block, sourceRange: range, fingerprint: fingerprint))
        }
        return result
    }

    private func parseBlock(_ markup: any Markup) throws -> BlockNode? {
        try self.checkCancellation()
        self.metadataBytes = ParseWorkMetrics.saturatingAdd(self.metadataBytes, MemoryLayout<BlockNode>.stride)
        switch markup {
        case let node as Paragraph:
            return try .paragraph(self.parseInlines(node.children))
        case let node as Heading:
            return try .heading(level: node.level, content: self.parseInlines(node.children))
        case let node as CodeBlock:
            return .codeBlock(language: node.language.flatMap { $0.isEmpty ? nil : $0 }, body: node.code)
        case let node as BlockQuote:
            return try .blockquote(node.children.compactMap { try self.parseBlock($0) })
        case let node as UnorderedList:
            return try .bulletList(items: node.children.compactMap { node in
                guard let item = node as? Markdown.ListItem else { return nil }
                return try self.parseListItem(item)
            })
        case let node as OrderedList:
            return try .orderedList(start: Int(node.startIndex), items: node.children.compactMap { node in
                guard let item = node as? Markdown.ListItem else { return nil }
                return try self.parseListItem(item)
            })
        case is ThematicBreak: return .thematicBreak
        case let node as HTMLBlock: return .htmlBlock(text: node.rawHTML)
        case let node as Table: return try self.parseTable(node)
        default: return nil
        }
    }

    private func parseTable(_ node: Table) throws -> BlockNode {
        let columns: [ColumnAlignment] = try node.columnAlignments.map { column in
            try self.checkCancellation()
            switch column {
            case .left: return .left
            case .right: return .right
            case .center: return .center
            case nil: return .none
            }
        }
        let head = try node.head.children.compactMap { cell -> TableCell? in
            try self.checkCancellation()
            guard let cell = cell as? Table.Cell else { return nil }
            return try TableCell(content: self.parseInlines(cell.children))
        }
        let rows = try node.body.children.compactMap { row -> [TableCell]? in
            try self.checkCancellation()
            guard let row = row as? Table.Row else { return nil }
            return try row.children.compactMap { cell in
                try self.checkCancellation()
                guard let cell = cell as? Table.Cell else { return nil }
                return try TableCell(content: self.parseInlines(cell.children))
            }
        }
        return .table(columns: columns, head: head, rows: rows)
    }

    private func parseListItem(_ item: Markdown.ListItem) throws -> MarkdownCore.ListItem {
        try self.checkCancellation()
        let blocks = try item.children.compactMap { try self.parseBlock($0) }
        let checkbox: MarkdownCore.ListItem.Checkbox? = switch item.checkbox {
        case .checked: .checked
        case .unchecked: .unchecked
        case nil: nil
        }
        return MarkdownCore.ListItem(blocks: blocks, checkbox: checkbox)
    }

    private func parseInlines(_ children: MarkupChildren) throws -> [InlineNode] {
        try children.compactMap { try self.parseInline($0) }
    }

    private func parseInline(_ markup: any Markup) throws -> InlineNode? {
        try self.checkCancellation()
        self.metadataBytes = ParseWorkMetrics.saturatingAdd(self.metadataBytes, MemoryLayout<InlineNode>.stride)
        switch markup {
        case let node as Markdown.Text: return .text(node.string)
        case is SoftBreak: return .softBreak
        case is LineBreak: return .lineBreak
        case let node as InlineCode: return .inlineCode(node.code)
        case let node as Emphasis: return try .emphasis(self.parseInlines(node.children))
        case let node as Strong: return try .strong(self.parseInlines(node.children))
        case let node as Strikethrough: return try .strikethrough(self.parseInlines(node.children))
        case let node as Link:
            return try .link(destination: node.destination ?? "", title: node.title, children: self.parseInlines(node.children))
        case let node as Image: return try .image(source: node.source ?? "", alt: self.imagePlainText(node))
        case let node as InlineHTML: return .html(node.rawHTML)
        case let node as SymbolLink: return .text(node.destination ?? "")
        default: return nil
        }
    }

    /// Upstream plainText spelling, but collect leaves first so deeply nested
    /// alt markup never joins/copies the same source prefix at every container.
    private func imagePlainText(_ image: Image) throws -> String {
        var fragments: [String] = []
        var count = 0
        func append(_ text: String) {
            count = ParseWorkMetrics.saturatingAdd(count, text.utf8.count)
            if fragments.count == fragments.capacity {
                self.metadataBytes = ParseWorkMetrics.saturatingAdd(self.metadataBytes, fragments.count * MemoryLayout<String>.stride)
            }
            fragments.append(text)
            self.metadataBytes = ParseWorkMetrics.saturatingAdd(self.metadataBytes, MemoryLayout<String>.stride)
        }
        func visit(_ node: any Markup) throws {
            try self.checkCancellation()
            switch node {
            case let text as Markdown.Text: append(text.string)
            case let code as InlineCode: append("`"); append(code.code); append("`")
            case let html as InlineHTML: append(html.rawHTML)
            case let symbol as SymbolLink: append("``"); append(symbol.destination ?? ""); append("``")
            case is SoftBreak: append(" ")
            case is LineBreak: append("\n")
            case is Strikethrough:
                append("~")
                for child in node.children {
                    try visit(child)
                }
                append("~")
            default:
                for child in node.children {
                    try visit(child)
                }
            }
        }
        try visit(image)
        var result = ""
        result.reserveCapacity(count)
        for fragment in fragments {
            try self.checkCancellation()
            result.append(fragment)
            self.materializationBytes = ParseWorkMetrics.saturatingAdd(self.materializationBytes, fragment.utf8.count)
        }
        return result
    }
}

// MARK: - SourceRangeMapper

private struct SourceRangeMapper {
    init(source: String, checkCancellation: () throws -> Void = {}, buildLineStarts: Bool = true, onProgress: (Int, Int) -> Void = { _, _ in }) rethrows {
        self.source = source
        guard buildLineStarts else { self.lineStarts = []; self.metadataBytes = 0; return }
        var starts = [0]
        var metadata = MemoryLayout<Int>.stride
        var offset = 0
        defer { onProgress(offset, metadata) }
        var previousWasCR = false
        for byte in source.utf8 {
            if offset & 1023 == 0 { try checkCancellation() }
            offset += 1
            if byte == 13 {
                if starts.count == starts.capacity { metadata = ParseWorkMetrics.saturatingAdd(metadata, starts.count * MemoryLayout<Int>.stride) }
                starts.append(offset)
                metadata = ParseWorkMetrics.saturatingAdd(metadata, MemoryLayout<Int>.stride)
            } else if byte == 10 {
                if previousWasCR { starts[starts.count - 1] = offset }
                else {
                    if starts.count == starts.capacity { metadata = ParseWorkMetrics.saturatingAdd(metadata, starts.count * MemoryLayout<Int>.stride) }
                    starts.append(offset)
                }
                metadata = ParseWorkMetrics.saturatingAdd(metadata, MemoryLayout<Int>.stride)
            }
            previousWasCR = byte == 13
        }
        self.lineStarts = starts
        self.metadataBytes = metadata
    }

    func range(from sourceRange: SourceRange?) -> MarkdownSourceRange? {
        guard
            let sourceRange,
            let lower = offset(for: sourceRange.lowerBound),
            let upper = offset(for: sourceRange.upperBound),
            lower <= upper else {
            return nil
        }
        return MarkdownSourceRange(lowerBound: lower, upperBound: upper)
    }

    func fingerprint(in range: MarkdownSourceRange, checkCancellation: () throws -> Void = {}, onProgress: (Int) -> Void = { _ in }) rethrows -> UInt64? {
        guard
            range.lowerBound >= 0,
            range.lowerBound <= range.upperBound,
            range.upperBound <= self.source.utf8.count else {
            return nil
        }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        let lower = self.source.utf8.index(self.source.utf8.startIndex, offsetBy: range.lowerBound)
        let upper = self.source.utf8.index(lower, offsetBy: range.upperBound - range.lowerBound)
        var count = 0
        defer { onProgress(count) }
        for byte in self.source.utf8[lower ..< upper] {
            if count & 1023 == 0 { try checkCancellation() }
            count += 1
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01B3
        }
        return hash
    }

    private let source: String
    private let lineStarts: [Int]
    let metadataBytes: Int

    private func offset(for location: SourceLocation) -> Int? {
        guard location.line > 0, location.line <= self.lineStarts.count else {
            return nil
        }
        return self.lineStarts[location.line - 1] + max(0, location.column - 1)
    }
}

extension String {
    private func utf8Index(at offset: Int) -> String.Index? {
        guard offset >= 0, offset <= utf8.count else {
            return nil
        }
        return String.Index(utf8.index(utf8.startIndex, offsetBy: offset), within: self)
    }
}

// MARK: - MathBackfill

/// 把哨兵锚就地换回 math 节点，严格保留容器结构（spec §4.2、§11.6）。
/// 注：行内专属容器（emphasis/strong/strikethrough/link）与表格单元格内的块定界符会降级为行内 `.math`，
/// 不产生块级占位符，以保证不残留哨兵到公开 IR（与 §4.2 表格单元格降级规则一致）。
enum MathBackfill {
    static func resolve(_ blocks: [ParsedBlockNode], table: [MathSentinel.Entry]) -> [ParsedBlockNode] {
        try! self.resolve(blocks, table: table, work: ParseWorkAccumulator(cancellable: false))
    }

    static func resolve(_ blocks: [ParsedBlockNode], table: [MathSentinel.Entry], work: ParseWorkAccumulator) throws -> [ParsedBlockNode] {
        try blocks.flatMap { node -> [ParsedBlockNode] in
            try work.check()
            let before = work.decodedEventCount
            let resolved = try self.resolveBlock(node.block, table: table, work: work)
            // pre-backfill 的 `fingerprint` / `sourceRange` 是对**原始**
            // `node.block` 在原始源码字节空间算出的；仅当 backfill 对该位置
            // 「原样透传、未拆未改 block」时它们才与 emitted 块 1:1 自洽。
            // 一旦 backfill 拆分（paragraph → [paragraph, mathBlock, …]）或
            // 改写块内容（行内文本被替换为含 `.math` 的新 inline 数组、
            // `unescapeReservedScalar` 改了文本），复用旧 fingerprint 会让
            // `MarkdownLabelView` 的块 diff（双方 fingerprint 非 nil 时优先
            // fingerprint 相等）把**已变**块误判**未变**而跳过流式增量更新
            // （与本 PR/saga 同类的增量正确性 bug）。
            //
            // 判定准则（精确，非一刀切）：`resolveBlock` 输出恰为 `[node.block]`
            // （单块且 `BlockNode` 相等）⟺ 真·透传 → 保留原 fingerprint/
            // sourceRange（fast-path 不退化）；否则（拆成多块、或单块但内容
            // 被改写）→ 该位置所有 emitted 块 `fingerprint`/`sourceRange`
            // 置 nil，强制 diff 回退到 `BlockNode` 相等（语义正确，仅失去
            // fast-path）。`sourceRange` 同理：拆分/改写后派生块不再 1:1
            // 精确对应原始 markdown 源切片，置 nil（与 Bug-4 既定语义一致；
            // nil sourceRange 的整选区纯文本回退是既有已知限制，本轮不扩大
            // 不收缩）。
            // Reuse the original fingerprint/sourceRange only on a true
            // passthrough; clear them whenever backfill split or rewrote
            // this position so the block diff falls back to BlockNode
            // equality (semantically correct, just no fast-path).
            let isPassthrough = resolved.count == 1 && work.decodedEventCount == before
            try work.metadata(resolved.count * MemoryLayout<ParsedBlockNode>.stride)
            if isPassthrough {
                return [node]
            }
            return resolved.enumerated().map {
                ParsedBlockNode(
                    block: $0.element,
                    sourceRange: nil,
                    fingerprint: nil,
                    sourceAnchor: node.sourceAnchor,
                    splitOrdinal: $0.offset
                )
            }
        }
    }

    private static func resolveBlock(_ block: BlockNode, table: [MathSentinel.Entry], work: ParseWorkAccumulator) throws -> [BlockNode] {
        try work.metadata(MemoryLayout<BlockNode>.stride)
        return switch block {
        case .paragraph(let inlines):
            try self.splitParagraph(inlines, table: table, work: work)
        case .heading(let level, let content):
            try [.heading(level: level, content: self.resolveInlines(content, table: table, allowBlock: false, work: work))]
        case .blockquote(let inner):
            try [.blockquote(inner.flatMap { try self.resolveBlock($0, table: table, work: work) })]
        case .bulletList(let items):
            try [.bulletList(items: items.map { try self.resolveListItem($0, table: table, work: work) })]
        case .orderedList(let start, let items):
            try [.orderedList(start: start, items: items.map { try self.resolveListItem($0, table: table, work: work) })]
        case .table(let cols, let head, let rows):
            try [.table(
                columns: cols,
                head: head.map { try TableCell(content: self.resolveInlines($0.content, table: table, allowBlock: false, work: work)) },
                rows: rows.map { try $0.map { try TableCell(content: self.resolveInlines($0.content, table: table, allowBlock: false, work: work)) } }
            )]
        case .codeBlock, .thematicBreak, .htmlBlock:
            [block]
        case .mathBlock:
            [block]
        }
    }

    private static func resolveListItem(_ item: ListItem, table: [MathSentinel.Entry], work: ParseWorkAccumulator) throws -> ListItem {
        try work.metadata(MemoryLayout<ListItem>.stride)
        return try ListItem(blocks: item.blocks.flatMap { try self.resolveBlock($0, table: table, work: work) }, checkbox: item.checkbox)
    }

    private static func splitParagraph(
        _ inlines: [InlineNode], table: [MathSentinel.Entry], work: ParseWorkAccumulator
    ) throws -> [BlockNode] {
        let expanded = try self.resolveInlines(inlines, table: table, allowBlock: true, work: work)
        var result: [BlockNode] = []
        var buffer: [InlineNode] = []
        func flush() {
            if !buffer.isEmpty { result.append(.paragraph(buffer)); buffer = [] }
        }
        for node in expanded {
            try work.metadata(MemoryLayout<InlineNode>.stride)
            if node.isBlockMathPlaceholder, case .html(let s) = node {
                work.decodedEventCount = ParseWorkMetrics.saturatingAdd(work.decodedEventCount, 1)
                flush()
                let latex = String(s.dropFirst().dropLast()) // 去掉首尾 U+10FE02
                try work.copy(latex.utf8.count)
                result.append(.mathBlock(latex: latex))
            } else {
                buffer.append(node)
            }
        }
        flush()
        if result.isEmpty { result = [.paragraph(expanded.filter { !$0.isBlockMathPlaceholder })] }
        return result
    }

    private static func resolveInlines(
        _ inlines: [InlineNode], table: [MathSentinel.Entry], allowBlock: Bool, work: ParseWorkAccumulator
    ) throws -> [InlineNode] {
        try inlines.flatMap { node -> [InlineNode] in
            try work.metadata(MemoryLayout<InlineNode>.stride)
            switch node {
            case .text(let raw):
                return try self.splitText(raw, table: table, allowBlock: allowBlock, work: work)
            case .emphasis(let c): return try [.emphasis(self.resolveInlines(c, table: table, allowBlock: false, work: work))]
            case .strong(let c): return try [.strong(self.resolveInlines(c, table: table, allowBlock: false, work: work))]
            case .strikethrough(let c): return try [.strikethrough(self.resolveInlines(c, table: table, allowBlock: false, work: work))]
            case .link(let d, let t, let c):
                return try [.link(destination: d, title: t, children: self.resolveInlines(c, table: table, allowBlock: false, work: work))]
            default:
                return [node]
            }
        }
    }

    private static func splitText(
        _ raw: String, table: [MathSentinel.Entry], allowBlock: Bool, work: ParseWorkAccumulator
    ) throws -> [InlineNode] {
        try MathSentinel.decodeText(raw, tableCount: table.count, work: work).map { piece in
            try work.metadata(MemoryLayout<InlineNode>.stride)
            switch piece {
            case .literal(let text): return .text(text)
            case .entry(let index):
                let entry = table[index]
                if entry.display, allowBlock {
                    try work.copy(entry.latex.utf8.count + 8)
                    return .blockMathPlaceholder(latex: entry.latex)
                }
                return .math(latex: entry.latex)
            }
        }
    }
}

/// 内部用：标记一个待提升为 BlockNode.mathBlock 的占位 inline（不对外暴露）。
extension InlineNode {
    static func blockMathPlaceholder(latex: String) -> InlineNode {
        .html("\u{10FE02}\(latex)\u{10FE02}")
    }

    var isBlockMathPlaceholder: Bool {
        if case .html(let s) = self { return s.hasPrefix("\u{10FE02}") && s.hasSuffix("\u{10FE02}") }
        return false
    }
}
