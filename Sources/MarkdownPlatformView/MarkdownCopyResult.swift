import Foundation

/// How faithfully a copy reproduced what the user selected.
public enum MarkdownCopyGranularity: Sendable, Equatable {
    /// The text is the contiguous source region between the selection's
    /// endpoints. It adds nothing beyond them — but a *contiguous* region can
    /// include source that belongs to no block, such as a link reference
    /// definition sitting between two selected paragraphs. That is deliberate:
    /// dropping it would leave `[text][ref]` links in the copy unresolvable.
    case exact
    /// The selection cut into a block, and the whole block's source is returned
    /// because inline source offsets do not exist. Callers that must not paste
    /// more than was selected should check for this.
    case blockExpanded
    /// No source mapping was available. The text is *approximate syntax*
    /// reconstructed from what is rendered — delimiters the renderer consumed,
    /// such as emphasis and links, are already gone — clamped to the selection
    /// but not guaranteed to reparse as the same document.
    case renderedFallback
}

public struct MarkdownCopyResult: Sendable, Equatable {
    public let text: String
    public let granularity: MarkdownCopyGranularity

    public init(text: String, granularity: MarkdownCopyGranularity) {
        self.text = text
        self.granularity = granularity
    }
}

/// Titles of the copy commands. Hosts override them when their menu uses
/// different wording; the defaults are localized by the package.
///
/// Process-global rather than per view: two hosts in one process cannot differ.
@MainActor public enum MarkdownCopyCommandTitle {
    public static var copy: String = NSLocalizedString(
        "markdown.copy.rendered", bundle: .module, comment: "Menu command copying the selected rendered text"
    )
    public static var markdownSource: String = NSLocalizedString(
        "markdown.copy.source", bundle: .module, comment: "Menu command copying the selected Markdown source"
    )
}
