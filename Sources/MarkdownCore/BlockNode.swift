// MARK: - BlockNode

/// A block-level node in the MarkdownCore IR.
///
/// Block nodes form the top-level structure of a parsed document.
/// They are produced by ``MarkdownDocument`` and consumed by ``MarkdownRenderKit``.
///
/// The type is a plain value type with no dependency on swift-markdown, so higher
/// layers never need to import the parsing back-end directly.
public enum BlockNode: Sendable, Equatable {
    /// One or more inline elements forming a paragraph.
    case paragraph([InlineNode])

    /// A heading with an ATX/setext level (1–6) and inline content.
    case heading(level: Int, content: [InlineNode])

    /// A fenced or indented code block.
    case codeBlock(language: String?, body: String)

    /// A block-level quotation containing nested blocks.
    case blockquote([BlockNode])

    /// An unordered (bullet) list.
    case bulletList(items: [ListItem])

    /// An ordered (numbered) list.
    case orderedList(start: Int, items: [ListItem])

    /// A thematic break (`---`, `***`, `___`).
    case thematicBreak

    /// A raw HTML block (passed through unchanged).
    case htmlBlock(text: String)

    /// A GFM table.
    case table(columns: [ColumnAlignment], head: [TableCell], rows: [[TableCell]])
}

// MARK: - TableCell

/// Content of a single GFM table cell (inline nodes).
public struct TableCell: Sendable, Equatable {
    public init(content: [InlineNode] = []) {
        self.content = content
    }

    public let content: [InlineNode]
}

// MARK: - ColumnAlignment

/// Per-column text alignment in a GFM table.
public enum ColumnAlignment: Sendable, Equatable {
    case left
    case right
    case center
    case none
}
