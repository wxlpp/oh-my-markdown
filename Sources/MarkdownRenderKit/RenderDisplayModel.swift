import MarkdownCore

public struct RenderDisplayModel: Sendable, Equatable {
  public let runs: [DisplayRun]
  public let blocks: [DisplayBlock]
  public let resources: [UnresolvedResource]
  public let accessibility: AccessibilityTree

  public init(
    runs: [DisplayRun], blocks: [DisplayBlock], resources: [UnresolvedResource],
    accessibility: AccessibilityTree
  ) {
    self.runs = runs
    self.blocks = blocks
    self.resources = resources
    self.accessibility = accessibility
  }
}

public struct ResourceID: Hashable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
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
