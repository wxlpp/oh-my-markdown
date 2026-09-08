import Foundation

/// How faithfully a copy reproduced what the user selected.
public enum MarkdownCopyGranularity: Sendable, Equatable {
    /// The returned text covers the selection and nothing more.
    case exact
    /// The selection cut into a block, and the whole block's source is returned
    /// because inline source offsets do not exist. Callers that must not paste
    /// more than was selected should check for this.
    case blockExpanded
    /// No source mapping was available, so the rendered text is returned instead.
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
