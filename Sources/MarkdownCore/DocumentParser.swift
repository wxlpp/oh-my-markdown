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
        let swiftMarkdownDoc = Markdown.Document(parsing: source)
        self.parsedBlocks = DocumentParser().parse(source: source, document: swiftMarkdownDoc)
        self.blocks = self.parsedBlocks.map(\.block)
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
        let reparsedTail = DocumentParser().parse(source: suffix, document: Markdown.Document(parsing: suffix))
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
