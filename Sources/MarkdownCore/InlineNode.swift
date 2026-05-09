/// An inline-level node in the MarkdownCore IR.
///
/// Inline nodes appear inside block-level containers such as paragraphs and
/// headings.  They are deliberately kept separate from ``BlockNode`` so that
/// renderers can handle each layer independently.
public enum InlineNode: Sendable, Equatable {
    /// Plain text content.
    case text(String)

    /// A soft line break (space + newline in source — rendered as a space).
    case softBreak

    /// A hard line break (`\` or two trailing spaces before newline).
    case lineBreak

    /// An inline code span.
    case inlineCode(String)

    /// Emphasized (italic) text.
    case emphasis([InlineNode])

    /// Strongly emphasized (bold) text.
    case strong([InlineNode])

    /// Strikethrough text (GFM extension).
    case strikethrough([InlineNode])

    /// A hyperlink.
    case link(destination: String, title: String?, children: [InlineNode])

    /// An embedded image.
    case image(source: String, alt: String)

    /// Raw inline HTML (passed through unchanged).
    case html(String)
}
