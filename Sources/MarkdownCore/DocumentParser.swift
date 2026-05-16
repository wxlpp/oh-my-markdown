import Markdown

// MARK: - MarkdownDocument

/// A parsed Markdown document represented as an array of ``BlockNode``s.
///
/// Internally this uses swift-markdown (cmark-gfm) for parsing.  The result
/// is converted to MarkdownCore's own IR so that higher-level targets never
/// need to depend on swift-markdown directly.
public struct MarkdownDocument: Sendable, Equatable {
    /// Parse a Markdown source string into a document.
    public init(parsing source: String) {
        self.parsedBlocks = Self.parsePipeline(source)
        self.blocks = self.parsedBlocks.map(\.block)
    }

    /// 数学感知解析管线：扫描 → 哨兵替换 → swift-markdown 解析 → 数学回填。
    /// `init(parsing:)` 与增量尾窗重解析共用此管线，保证两路语义完全一致。
    private static func parsePipeline(_ source: String) -> [ParsedBlockNode] {
        let mathSpans = MathScanner.scan(source)
        let sub = MathSentinel.substitute(source: source, spans: mathSpans)
        let swiftMarkdownDoc = Markdown.Document(parsing: sub.transformed)
        let raw = DocumentParser().parse(source: sub.transformed, document: swiftMarkdownDoc)
        // swift-markdown 在「变换串」上解析，sourceRange/fingerprint 都是变换串字节空间。
        // 但 init(parsing:) 与 parsingAppend 都按「原始源码」消费这些区间
        // （reparseStart / utf8Index / offset(byUTF8:) / hasPrefix / 尾窗切片）。
        // 哨兵替换会改变字节长度（行内 `$a$` 3 字节 → `S0S` 9 字节；用户文本里的
        // U+10FE00 也会 +4 转义），故此处把每个 sourceRange 映回原始源码字节空间，
        // 并据此从「原始源码」重算 fingerprint，保证两路与 spec §4.3 自洽。
        let mapped = Self.mapToOriginalSpace(raw, sub: sub, originalSource: source)
        return MathBackfill.resolve(mapped, table: sub.table)
    }

    /// 把 raw 解析块的 `sourceRange`（变换串字节空间）映回原始源码字节空间，
    /// 并用原始源码切片重算 `fingerprint`（原始空间区间 ↔ 原始源码，自洽）。
    private static func mapToOriginalSpace(
        _ raw: [ParsedBlockNode],
        sub: MathSentinel.SubstituteResult,
        originalSource: String
    ) -> [ParsedBlockNode] {
        let originalMapper = SourceRangeMapper(source: originalSource)
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
                fingerprint: originalMapper.fingerprint(in: origRange)
            )
        }
    }

    public init(parsedBlocks: [ParsedBlockNode]) {
        self.parsedBlocks = parsedBlocks
        self.blocks = parsedBlocks.map(\.block)
    }

    /// Top-level block nodes in document order.
    public let blocks: [BlockNode]
    /// Top-level block nodes paired with their UTF-8 source ranges when available.
    public let parsedBlocks: [ParsedBlockNode]

    /// Parse an appended version of this document by preserving stable prefix blocks
    /// and reparsing the previous tail block plus the appended source.
    public func parsingAppend(to newSource: String, previousSource: String) -> MarkdownDocument {
        // 数学感知：若被保留的 prefix 可能含会被追加文本闭合的未闭合数学开界符，
        // suffix-only 扫描看不到开界符，直接全量解析以保证与全量一致（spec §4.3）。
        if Self.previousSourceHasOpenMathDelimiter(previousSource) {
            return MarkdownDocument(parsing: newSource)
        }
        guard
            newSource.hasPrefix(previousSource),
            let tail = parsedBlocks.last,
            let tailRange = tail.sourceRange else {
            return MarkdownDocument(parsing: newSource)
        }

        let reparseIndex = self.tailReparseStartIndex()
        let reparseBlock = self.parsedBlocks[reparseIndex]
        let reparseStart = reparseBlock.sourceRange?.lowerBound ?? tailRange.lowerBound
        guard
            reparseStart <= previousSource.utf8.count,
            let suffixStart = newSource.utf8Index(at: reparseStart) else {
            return MarkdownDocument(parsing: newSource)
        }

        let suffix = String(newSource[suffixStart...])
        // 与 init(parsing:) 同一管线：扫描 → 哨兵替换 → 解析 → 回填，使重解析的尾窗
        // 也能识别数学（前缀已确认无未闭合开界符，故按块边界切出的尾窗对数学自洽）。
        let reparsedTail = Self.parsePipeline(suffix)
            .map { parsed in
                ParsedBlockNode(
                    block: parsed.block,
                    sourceRange: parsed.sourceRange?.offset(byUTF8: reparseStart),
                    fingerprint: parsed.fingerprint
                )
            }

        return MarkdownDocument(parsedBlocks: Array(self.parsedBlocks.prefix(reparseIndex)) + reparsedTail)
    }

    private func tailReparseStartIndex() -> Int {
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

    /// previousSource 末尾是否处于「数学定界符未闭合」状态。
    /// 复用 MathScanner 的代码区/转义规则：若存在任何开界符但 scan 未把它配成 span，
    /// 说明闭合符尚未出现，追加文本可能闭合它 → 必须全量。
    /// 保守性：任何裸露未配对的 `$` / `\(` / `\[`（包括 `price $5` 这类非数学散文）
    /// 都会保守地强制全量重解析——符合 spec §4.3，并非最小化。
    static func previousSourceHasOpenMathDelimiter(_ source: String) -> Bool {
        let bytes = Array(source.utf8)
        // 廉价早退：既无 `$`(0x24) 也无 `\`(0x5C) 时不可能有任何数学开界符，
        // 直接返回，避免常见无数学流式场景为重扫描/掩码付费。
        if !bytes.contains(0x24), !bytes.contains(0x5C) { return false }
        let spans = MathScanner.scan(source)
        // 单次预计算覆盖掩码：把 O(spans) 的逐字节命中折成 O(1) 查表。
        var coveredMask = [Bool](repeating: false, count: bytes.count)
        for span in spans {
            for x in span.range where x >= 0 && x < coveredMask.count {
                coveredMask[x] = true
            }
        }
        func isCovered(_ i: Int) -> Bool {
            coveredMask[i]
        }
        let mask = MathScanner.codeRegionMask(source: source)
        var i = 0
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
    }

    public let block: BlockNode
    public let sourceRange: MarkdownSourceRange?
    public let fingerprint: UInt64?
}

// MARK: - DocumentParser

private struct DocumentParser {
    func parse(source: String, document: Markdown.Document) -> [ParsedBlockNode] {
        let mapper = SourceRangeMapper(source: source)
        return document.children.compactMap { markup in
            guard let block = parseBlock(markup) else {
                return nil
            }
            let sourceRange = mapper.range(from: markup.range)
            return ParsedBlockNode(
                block: block,
                sourceRange: sourceRange,
                fingerprint: sourceRange.flatMap { mapper.fingerprint(in: $0) }
            )
        }
    }

    // MARK: Block nodes

    private func parseBlock(_ markup: any Markup) -> BlockNode? {
        switch markup {
        case let node as Paragraph:
            return .paragraph(self.parseInlines(node.children))

        case let node as Heading:
            return .heading(level: node.level, content: self.parseInlines(node.children))

        case let node as CodeBlock:
            let lang = node.language.flatMap { $0.isEmpty ? nil : $0 }
            return .codeBlock(language: lang, body: node.code)

        case let node as BlockQuote:
            return .blockquote(node.children.compactMap { self.parseBlock($0) })

        case let node as UnorderedList:
            let items = node.children
                .compactMap { $0 as? Markdown.ListItem }
                .map { self.parseListItem($0) }
            return .bulletList(items: items)

        case let node as OrderedList:
            let items = node.children
                .compactMap { $0 as? Markdown.ListItem }
                .map { self.parseListItem($0) }
            return .orderedList(start: Int(node.startIndex), items: items)

        case is ThematicBreak:
            return .thematicBreak

        case let node as HTMLBlock:
            return .htmlBlock(text: node.rawHTML)

        case let node as Table:
            return self.parseTable(node)

        default:
            return nil
        }
    }

    private func parseTable(_ node: Table) -> BlockNode {
        let alignments: [ColumnAlignment] = node.columnAlignments.map { col in
            switch col {
            case .left: .left
            case .right: .right
            case .center: .center
            case nil: .none
            }
        }
        // Head: Table.Head directly contains Table.Cell (not Table.Row)
        let headCells: [TableCell] = node.head.children
            .compactMap { $0 as? Table.Cell }
            .map { TableCell(content: self.parseInlines($0.children)) }
        // Body: Table.Body contains multiple Table.Row
        let bodyRows: [[TableCell]] = node.body.children
            .compactMap { $0 as? Table.Row }
            .map { row in
                row.children
                    .compactMap { $0 as? Table.Cell }
                    .map { TableCell(content: self.parseInlines($0.children)) }
            }
        return .table(columns: alignments, head: headCells, rows: bodyRows)
    }

    private func parseListItem(_ item: Markdown.ListItem) -> MarkdownCore.ListItem {
        let blocks = item.children.compactMap { self.parseBlock($0) }
        // Markdown.Checkbox is a top-level enum (not nested in ListItem)
        let checkbox: MarkdownCore.ListItem.Checkbox? = switch item.checkbox {
        case .checked: .checked
        case .unchecked: .unchecked
        case nil: nil
        }
        return MarkdownCore.ListItem(blocks: blocks, checkbox: checkbox)
    }

    // MARK: Inline nodes

    private func parseInlines(_ children: MarkupChildren) -> [InlineNode] {
        children.compactMap { self.parseInline($0) }
    }

    private func parseInline(_ markup: any Markup) -> InlineNode? {
        switch markup {
        case let node as Markdown.Text:
            return .text(node.string)

        case is SoftBreak:
            return .softBreak

        case is LineBreak:
            return .lineBreak

        case let node as InlineCode:
            return .inlineCode(node.code)

        case let node as Emphasis:
            return .emphasis(self.parseInlines(node.children))

        case let node as Strong:
            return .strong(self.parseInlines(node.children))

        case let node as Strikethrough:
            return .strikethrough(self.parseInlines(node.children))

        case let node as Link:
            return .link(
                destination: node.destination ?? "",
                title: node.title,
                children: self.parseInlines(node.children)
            )

        case let node as Image:
            let alt = node.plainText
            return .image(source: node.source ?? "", alt: alt)

        case let node as InlineHTML:
            return .html(node.rawHTML)

        case let node as SymbolLink:
            // Render DocC symbol links as plain text.
            return .text(node.destination ?? "")

        default:
            return nil
        }
    }
}

// MARK: - SourceRangeMapper

private struct SourceRangeMapper {
    init(source: String) {
        self.source = source
        var starts = [0]
        var offset = 0
        for byte in source.utf8 {
            offset += 1
            if byte == 10 {
                starts.append(offset)
            }
        }
        self.lineStarts = starts
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

    func fingerprint(in range: MarkdownSourceRange) -> UInt64? {
        guard
            range.lowerBound >= 0,
            range.lowerBound <= range.upperBound,
            range.upperBound <= self.source.utf8.count,
            let lower = source.utf8Index(at: range.lowerBound),
            let upper = source.utf8Index(at: range.upperBound) else {
            return nil
        }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in self.source[lower ..< upper].utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01B3
        }
        return hash
    }

    private let source: String
    private let lineStarts: [Int]

    private func offset(for location: SourceLocation) -> Int? {
        guard location.line > 0, location.line <= self.lineStarts.count else {
            return nil
        }
        return self.lineStarts[location.line - 1] + max(0, location.column - 1)
    }
}

extension String {
    fileprivate func utf8Index(at offset: Int) -> String.Index? {
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
        blocks.flatMap { node -> [ParsedBlockNode] in
            self.resolveBlock(node.block, table: table).map {
                ParsedBlockNode(block: $0, sourceRange: node.sourceRange, fingerprint: node.fingerprint)
            }
        }
    }

    private static func resolveBlock(_ block: BlockNode, table: [MathSentinel.Entry]) -> [BlockNode] {
        switch block {
        case .paragraph(let inlines):
            self.splitParagraph(inlines, table: table)
        case .heading(let level, let content):
            [.heading(level: level, content: self.resolveInlines(content, table: table, allowBlock: false))]
        case .blockquote(let inner):
            [.blockquote(inner.flatMap { self.resolveBlock($0, table: table) })]
        case .bulletList(let items):
            [.bulletList(items: items.map { self.resolveListItem($0, table: table) })]
        case .orderedList(let start, let items):
            [.orderedList(start: start, items: items.map { self.resolveListItem($0, table: table) })]
        case .table(let cols, let head, let rows):
            [.table(
                columns: cols,
                head: head.map { TableCell(content: self.resolveInlines($0.content, table: table, allowBlock: false)) },
                rows: rows.map { $0.map { TableCell(content: self.resolveInlines($0.content, table: table, allowBlock: false)) } }
            )]
        case .codeBlock, .thematicBreak, .htmlBlock:
            [block]
        case .mathBlock:
            [block]
        }
    }

    private static func resolveListItem(_ item: ListItem, table: [MathSentinel.Entry]) -> ListItem {
        ListItem(blocks: item.blocks.flatMap { self.resolveBlock($0, table: table) }, checkbox: item.checkbox)
    }

    private static func splitParagraph(
        _ inlines: [InlineNode], table: [MathSentinel.Entry]
    ) -> [BlockNode] {
        let expanded = self.resolveInlines(inlines, table: table, allowBlock: true)
        var result: [BlockNode] = []
        var buffer: [InlineNode] = []
        func flush() {
            if !buffer.isEmpty { result.append(.paragraph(buffer)); buffer = [] }
        }
        for node in expanded {
            if node.isBlockMathPlaceholder, case .html(let s) = node {
                flush()
                let latex = String(s.dropFirst().dropLast()) // 去掉首尾 U+10FE02
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
        _ inlines: [InlineNode], table: [MathSentinel.Entry], allowBlock: Bool
    ) -> [InlineNode] {
        inlines.flatMap { node -> [InlineNode] in
            switch node {
            case .text(let raw):
                return self.splitText(raw, table: table, allowBlock: allowBlock)
            case .emphasis(let c): return [.emphasis(self.resolveInlines(c, table: table, allowBlock: false))]
            case .strong(let c): return [.strong(self.resolveInlines(c, table: table, allowBlock: false))]
            case .strikethrough(let c): return [.strikethrough(self.resolveInlines(c, table: table, allowBlock: false))]
            case .link(let d, let t, let c):
                return [.link(destination: d, title: t, children: self.resolveInlines(c, table: table, allowBlock: false))]
            default:
                return [node]
            }
        }
    }

    private static func splitText(
        _ raw: String, table: [MathSentinel.Entry], allowBlock: Bool
    ) -> [InlineNode] {
        let anchors = MathSentinel.anchorRanges(in: raw).filter { table.indices.contains($0.index) }
        guard !anchors.isEmpty else {
            return [.text(MathSentinel.unescapeReservedScalar(raw))]
        }
        var out: [InlineNode] = []
        var cursor = raw.startIndex
        for anchor in anchors {
            if cursor < anchor.range.lowerBound {
                out.append(.text(MathSentinel.unescapeReservedScalar(String(raw[cursor ..< anchor.range.lowerBound]))))
            }
            let entry = table[anchor.index]
            if entry.display, allowBlock {
                out.append(.blockMathPlaceholder(latex: entry.latex))
            } else {
                out.append(.math(latex: entry.latex))
            }
            cursor = anchor.range.upperBound
        }
        if cursor < raw.endIndex {
            out.append(.text(MathSentinel.unescapeReservedScalar(String(raw[cursor ..< raw.endIndex]))))
        }
        return out
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
