import Foundation
import MarkdownCore

public enum AccessibilityRole: Hashable, Sendable {
    case text
    case heading(level: Int)
    case listItem, link, image, math, code
    case table, row, columnHeader, rowHeader, cell
}

public struct AccessibilityNodeID: Hashable, Sendable {
    public let sourceGeneration: UInt64
    public let role: AccessibilityRole
    public let startAnchor: Int
    public let lineage: UInt64
    /// Position of the leaf inside its block. Two links in one paragraph share a
    /// lineage and a source anchor — block ranges are the only ones the parser
    /// records — so nothing else tells them apart. Not an end offset: it is
    /// stable for every leaf before a growing tail, which is what keeps focus
    /// from jumping on each streamed chunk.
    public let ordinal: Int

    public init(
        sourceGeneration: UInt64, role: AccessibilityRole, startAnchor: Int, lineage: UInt64, ordinal: Int = 0
    ) {
        self.sourceGeneration = sourceGeneration
        self.role = role
        self.startAnchor = startAnchor
        self.lineage = lineage
        self.ordinal = ordinal
    }
}

/// Role-specific metadata a screen reader needs beyond the label.
public enum AccessibilityDetail: Sendable, Equatable {
    case code(language: String?)
    case cell(row: Int, column: Int, columnHeader: String?)
    case listItem(position: Int, count: Int, checkbox: Bool?)
}

public enum AccessibilityActivation: Sendable, Equatable {
    case link(URL, sessionGeneration: UInt64)
}

public struct AccessibilityTree: Sendable, Equatable {
    public let roots: [AccessibilityNode]
    public init(roots: [AccessibilityNode]) {
        self.roots = roots
    }
}

public struct AccessibilityNode: Sendable, Equatable {
    public let id: AccessibilityNodeID
    public let role: AccessibilityRole
    public let label: String?
    public let sourceRange: MarkdownSourceRange?
    public let children: [AccessibilityNode]
    public let activation: AccessibilityActivation?
    public let detail: AccessibilityDetail?

    public init(
        id: AccessibilityNodeID, role: AccessibilityRole, label: String?,
        sourceRange: MarkdownSourceRange? = nil, children: [AccessibilityNode] = [],
        activation: AccessibilityActivation? = nil, detail: AccessibilityDetail? = nil
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.sourceRange = sourceRange
        self.children = children
        self.activation = activation
        self.detail = detail
    }
}

/// Identifies one accessibility leaf within a rendered snapshot. Carried on the
/// attributed string so a leaf's on-screen extent can be recovered from layout.
public struct AccessibilityLeafKey: Hashable, Sendable {
    public let block: Int
    public let ordinal: Int
    public init(block: Int, ordinal: Int) {
        self.block = block
        self.ordinal = ordinal
    }
}
