import Foundation

public struct ColorToken: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct ColorTokens: Sendable, Equatable {
    public let body: ColorToken
    public let secondary: ColorToken
    public let code: ColorToken
    public let link: ColorToken
    /// Additional legacy style colors, copied to RGBA during snapshot conversion.
    public let additional: [String: ColorToken]

    public init(
        body: ColorToken, secondary: ColorToken, code: ColorToken, link: ColorToken,
        additional: [String: ColorToken] = [:]
    ) {
        self.body = body
        self.secondary = secondary
        self.code = code
        self.link = link
        self.additional = additional
    }
}

public enum MarkdownTextRole: Hashable, Sendable {
    case body, code
    case heading(level: Int)
    case listMarker, table, caption

    package var identity: String {
        switch self {
        case .body: "body"
        case .code: "code"
        case .heading(let level): "heading:\(level)"
        case .listMarker: "listMarker"
        case .table: "table"
        case .caption: "caption"
        }
    }
}

public struct TypographyTokens: Sendable, Equatable {
    public let pointSizes: [MarkdownTextRole: Double]
    public let usesPreferredMetrics: Bool
    public let fontNames: [MarkdownTextRole: String]
    /// Securely archived descriptors retain custom variations, matrices, and traits.
    /// Only MainActor materialization decodes these inert bytes into platform objects.
    public let fontDescriptors: [MarkdownTextRole: Data]

    public init(
        pointSizes: [MarkdownTextRole: Double], usesPreferredMetrics: Bool,
        fontNames: [MarkdownTextRole: String] = [:], fontDescriptors: [MarkdownTextRole: Data] = [:]
    ) {
        self.pointSizes = pointSizes
        self.usesPreferredMetrics = usesPreferredMetrics
        self.fontNames = fontNames
        self.fontDescriptors = fontDescriptors
    }
}

public struct SpacingTokens: Sendable, Equatable {
    public let paragraph: Double
    public let block: Double
    public let codeInsets: Double
    public let quoteIndent: Double
    /// Where a list item's text starts, per nesting level, and the item
    /// paragraph's tab interval: a marker wider than one level lands on the next
    /// one rather than passing the paragraph's last tab stop.
    public let listIndent: Double
    /// What the reader's text size multiplies a chrome constant by. Exposed so
    /// the incidental gaps that have no token of their own — list item spacing,
    /// the nested-quote step — follow the text instead of staying at their
    /// default-size value.
    public let chromeScale: Double

    public init(
        paragraph: Double, block: Double, codeInsets: Double, quoteIndent: Double = 0,
        listIndent: Double = 24, chromeScale: Double = 1
    ) {
        self.paragraph = paragraph
        self.block = block
        self.codeInsets = codeInsets
        self.quoteIndent = quoteIndent
        self.listIndent = listIndent
        self.chromeScale = chromeScale
    }
}

public struct MarkdownConfigurationID: Hashable, Sendable {
    public let rawValue: String
    private init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func uniqueInstance() -> Self {
        Self(rawValue: "instance:\(UUID().uuidString)")
    }

    public static func semantic(namespace: String, version: UInt) -> Self {
        Self(rawValue: "semantic:\(namespace):\(version)")
    }
}

public struct RenderConfigurationSnapshot: Sendable, Equatable {
    public let id: MarkdownConfigurationID
    public let typography: TypographyTokens
    public let colors: ColorTokens
    public let spacing: SpacingTokens
    public let generation: UInt64
    public let mathScale: Double

    public init(
        id: MarkdownConfigurationID, typography: TypographyTokens, colors: ColorTokens,
        spacing: SpacingTokens, generation: UInt64, mathScale: Double = 1
    ) {
        self.id = id
        self.typography = typography
        self.colors = colors
        self.spacing = spacing
        self.generation = generation
        self.mathScale = mathScale
    }
}

@MainActor
public struct MarkdownRenderConfiguration {
    package let style: RenderStyle
    public let configurationID: MarkdownConfigurationID
    private let usesPreferredMetrics: Bool
    private let resolvedDefault: RenderConfigurationSnapshot?
    private var contentSizeCategory: MarkdownContentSizeCategory = .large

    /// Custom fonts retain fixed metrics until explicitly opted into a scaling policy.
    public init(style: RenderStyle, configurationID: MarkdownConfigurationID = .uniqueInstance()) {
        self.init(style: style, configurationID: configurationID, contentSizeCategory: .large)
    }

    /// A host style resolved at the reader's text size. Only the roles the style
    /// registered as scalable move; the rest stay exactly as the host set them.
    public init(
        style: RenderStyle, configurationID: MarkdownConfigurationID = .uniqueInstance(),
        contentSizeCategory: MarkdownContentSizeCategory
    ) {
        self.style = style
        self.configurationID = configurationID
        self.usesPreferredMetrics = false
        self.resolvedDefault = nil
        self.contentSizeCategory = contentSizeCategory
    }

    private init(defaultStyle: RenderStyle, contentSizeCategory: MarkdownContentSizeCategory) {
        self.style = defaultStyle
        self.usesPreferredMetrics = true
        let resolved = defaultStyle.snapshot(
            generation: 0, usesPreferredMetrics: true, contentSizeCategory: contentSizeCategory
        )
        self.configurationID = resolved.id
        self.resolvedDefault = resolved
    }

    /// Captures the current appearance together with its semantic identity.
    /// Create a new default configuration when the environment changes.
    public static var `default`: Self {
        Self.default(contentSizeCategory: .large)
    }

    /// The default appearance resolved at the reader's text size. The category is
    /// part of the semantic identity, so a size change is a different
    /// configuration rather than a cache hit at the wrong size.
    public static func `default`(contentSizeCategory: MarkdownContentSizeCategory) -> Self {
        Self(defaultStyle: .default, contentSizeCategory: contentSizeCategory)
    }

    public func snapshot(generation: UInt64) -> RenderConfigurationSnapshot {
        if let resolvedDefault {
            return RenderConfigurationSnapshot(
                id: self.configurationID, typography: resolvedDefault.typography, colors: resolvedDefault.colors,
                spacing: resolvedDefault.spacing, generation: generation,
                mathScale: resolvedDefault.mathScale
            )
        }
        return self.style.snapshot(
            generation: generation, configurationID: self.configurationID,
            usesPreferredMetrics: self.usesPreferredMetrics, contentSizeCategory: self.contentSizeCategory
        )
    }
}
