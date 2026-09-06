import MarkdownCore

public struct RenderDisplayModel: Sendable, Equatable {
    /// Structured, value-only input preserves block nesting and semantics needed
    /// for width-dependent TextKit materialization. No platform object crosses here.
    package let preparedBlocks: [ParsedBlockNode]?
    package let source: String?
    package let availableWidth: Double
    package let placeholderMode: PlaceholderMode
    package let preparedContent: [PreparedPiece]?
    public let runs: [DisplayRun]
    public let blocks: [DisplayBlock]
    public let resources: [UnresolvedResource]
    public let accessibility: AccessibilityTree

    public init(
        runs: [DisplayRun], blocks: [DisplayBlock], resources: [UnresolvedResource],
        accessibility: AccessibilityTree
    ) {
        self.preparedBlocks = nil
        self.source = nil
        self.availableWidth = 320
        self.placeholderMode = .streaming
        self.preparedContent = nil
        self.runs = runs
        self.blocks = blocks
        self.resources = resources
        self.accessibility = accessibility
    }

    package init(runs: [DisplayRun], blocks: [DisplayBlock], resources: [UnresolvedResource], input: RenderInput, preparedContent: [PreparedPiece]) {
        self.runs = runs
        self.blocks = blocks
        self.resources = resources
        self.accessibility = AccessibilityTree(roots: [])
        self.preparedBlocks = input.document.parsedBlocks
        self.source = input.source
        self.availableWidth = input.availableWidth
        self.placeholderMode = input.placeholderMode
        self.preparedContent = preparedContent
    }
}

package enum PreparedColor: Equatable {
    case body, secondary, code, inlineCode, inlineBackground, link, image, quote, clear
}

package struct PreparedParagraph: Equatable {
    package var lineSpacing: Double = 4
    package var spacing: Double = 0
    package var before: Double = 0
    package var head: Double = 0
    package var first: Double = 0
    package var tail: Double = 0
    package var height: Double = 0
    package var centered = false
    package var tab: Double?
}

package struct PreparedAttributes: Equatable {
    package var role: MarkdownTextRole? = .body
    /// Trait order preserves nested legacy bold/italic operations.
    package var traits: [Bool] = []
    package var color: PreparedColor? = .body
    package var background: PreparedColor?
    package var paragraph: PreparedParagraph?
    package var strike = false
    package var underline = false
    package var destination: String?
    package var tinyFont = false
}

package enum PreparedRunKind: Equatable {
    case text
    case code(language: String?)
    case image(id: ResourceID, source: String, width: Double, resolves: Bool)
    case math(id: ResourceID, latex: String, display: Bool, width: Double, staticPlaceholder: Bool, resolves: Bool)
    case svg(id: ResourceID, source: String, placeholderWidth: Double, placeholderHeight: Double, staticPlaceholder: Bool, resolves: Bool)
}

package struct PreparedRun: Equatable {
    package var text: String
    package var attributes: PreparedAttributes
    package var kind: PreparedRunKind = .text
}

package struct PreparedTable: Equatable {
    package let columns: [ColumnAlignment]
    package let head: [[PreparedRun]]
    package let rows: [[[PreparedRun]]]
    package let width: Double
    package var quoteIndent: Double = 0
}

package enum PreparedPiece: Equatable {
    case blockStart
    case run(PreparedRun)
    case table(PreparedTable)
}

public struct ResourceID: Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum UnresolvedResource: Sendable, Equatable {
    case image(id: ResourceID, source: String, alt: String?)
    case math(id: ResourceID, latex: String, display: Bool)
    case svg(id: ResourceID, source: String)
}

public struct DisplayRun: Sendable, Equatable {
    public let text: String
    public let role: MarkdownTextRole
    public let sourceRange: MarkdownSourceRange?
    public let resourceID: ResourceID?

    public init(
        text: String, role: MarkdownTextRole, sourceRange: MarkdownSourceRange? = nil,
        resourceID: ResourceID? = nil
    ) {
        self.text = text
        self.role = role
        self.sourceRange = sourceRange
        self.resourceID = resourceID
    }
}

public struct DisplayBlock: Sendable, Equatable {
    public let lineage: UInt64
    public let runs: [DisplayRun]
    public let sourceRange: MarkdownSourceRange?

    public init(lineage: UInt64, runs: [DisplayRun], sourceRange: MarkdownSourceRange? = nil) {
        self.lineage = lineage
        self.runs = runs
        self.sourceRange = sourceRange
    }
}
