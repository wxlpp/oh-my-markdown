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

  public init(sourceGeneration: UInt64, role: AccessibilityRole, startAnchor: Int, lineage: UInt64)
  {
    self.sourceGeneration = sourceGeneration
    self.role = role
    self.startAnchor = startAnchor
    self.lineage = lineage
  }
}

public enum AccessibilityActivation: Sendable, Equatable {
  case link(URL, sessionGeneration: UInt64)
}

public struct AccessibilityTree: Sendable, Equatable {
  public let roots: [AccessibilityNode]
  public init(roots: [AccessibilityNode]) { self.roots = roots }
}

public struct AccessibilityNode: Sendable, Equatable {
  public let id: AccessibilityNodeID
  public let role: AccessibilityRole
  public let label: String?
  public let sourceRange: MarkdownSourceRange?
  public let children: [AccessibilityNode]
  public let activation: AccessibilityActivation?

  public init(
    id: AccessibilityNodeID, role: AccessibilityRole, label: String?,
    sourceRange: MarkdownSourceRange? = nil, children: [AccessibilityNode] = [],
    activation: AccessibilityActivation? = nil
  ) {
    self.id = id
    self.role = role
    self.label = label
    self.sourceRange = sourceRange
    self.children = children
    self.activation = activation
  }
}
