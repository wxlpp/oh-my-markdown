import Markdown

/// Rules that affect the parsed document, rather than its presentation.
public struct MarkdownParseOptions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// Opt in to CJK-friendly emphasis while retaining the original source.
    public static let cjkFriendlyEmphasis = Self(rawValue: 1 << 0)

    var swiftMarkdown: Markdown.ParseOptions {
        self.contains(.cjkFriendlyEmphasis) ? [.cjkFriendlyEmphasis] : []
    }
}
