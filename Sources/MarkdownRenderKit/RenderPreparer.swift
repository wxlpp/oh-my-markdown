import Foundation
import MarkdownCore

/// Pure preparation; no attributed strings, fonts, colors, or platform images.
public struct RenderPreparer: Sendable {
  private let configuration: RenderConfigurationSnapshot

  public init(configuration: RenderConfigurationSnapshot) { self.configuration = configuration }

  public enum PreparationError: Error { case configurationMismatch }

  public func prepare(_ input: RenderInput) throws -> RenderDisplayModel {
    guard input.configuration == configuration else { throw PreparationError.configurationMismatch }
    var builder = DisplayBuilder(
      generation: configuration.generation, placeholderMode: input.placeholderMode)
    var blocks: [DisplayBlock] = []
    for (index, parsed) in input.document.parsedBlocks.enumerated() {
      try Task.checkCancellation()
      builder.lineage = UInt64(index)
      builder.sourceRange = parsed.sourceRange
      let runs = builder.block(parsed.block)
      blocks.append(
        DisplayBlock(lineage: UInt64(index), runs: runs, sourceRange: parsed.sourceRange))
    }
    return RenderDisplayModel(
      runs: blocks.flatMap(\.runs), blocks: blocks, resources: builder.resources,
      accessibility: AccessibilityTree(roots: []))
  }
}

/// Accessibility structure is populated by Task 10; this checkpoint establishes
/// the Sendable representation and preserves the source block ranges.
private struct DisplayBuilder {
  let generation: UInt64
  let placeholderMode: PlaceholderMode
  var lineage: UInt64 = 0
  var sourceRange: MarkdownSourceRange?
  var resources: [UnresolvedResource] = []

  func run(_ text: String, role: MarkdownTextRole = .body, resourceID: ResourceID? = nil)
    -> DisplayRun
  {
    DisplayRun(text: text, role: role, sourceRange: sourceRange, resourceID: resourceID)
  }

  mutating func resource(
    _ make: (ResourceID) -> UnresolvedResource, fallback: String, role: MarkdownTextRole
  ) -> DisplayRun {
    let id = ResourceID(rawValue: "\(generation):\(lineage):\(resources.count)")
    resources.append(make(id))
    return run(placeholderMode == .static ? "\u{FFFC}" : fallback, role: role, resourceID: id)
  }

  mutating func inline(_ nodes: [InlineNode], role: MarkdownTextRole = .body) -> [DisplayRun] {
    var result: [DisplayRun] = []
    for node in nodes {
      switch node {
      case .text(let text), .html(let text): result.append(run(text, role: role))
      case .softBreak: result.append(run(" ", role: role))
      case .lineBreak: result.append(run("\n", role: role))
      case .inlineCode(let text): result.append(run(text, role: .code))
      case .emphasis(let children), .strong(let children), .strikethrough(let children):
        result += inline(children, role: role)
      case .link(_, _, let children): result += inline(children, role: role)
      case .image(let source, let alt):
        result.append(
          resource({ .image(id: $0, source: source, alt: alt) }, fallback: alt, role: role))
      case .math(let latex):
        result.append(
          resource({ .math(id: $0, latex: latex, display: false) }, fallback: latex, role: role))
      }
    }
    return result
  }

  mutating func block(_ node: BlockNode) -> [DisplayRun] {
    switch node {
    case .paragraph(let content): return inline(content) + [run("\n")]
    case .heading(let level, let content):
      return inline(content, role: .heading(level: level)) + [
        run("\n", role: .heading(level: level))
      ]
    case .codeBlock(let language, let body):
      if language?.lowercased() == "svg" {
        return [resource({ .svg(id: $0, source: body) }, fallback: body, role: .code), run("\n")]
      }
      return [run(body, role: .code), run("\n")]
    case .blockquote(let children): return children.flatMap { block($0) }
    case .bulletList(let items): return list(items, start: nil)
    case .orderedList(let start, let items): return list(items, start: start)
    case .thematicBreak: return [run("———\n")]
    case .htmlBlock(let text): return [run(text), run("\n")]
    case .mathBlock(let latex):
      return [
        resource({ .math(id: $0, latex: latex, display: true) }, fallback: latex, role: .body),
        run("\n"),
      ]
    case .table(_, let head, let rows):
      var result: [DisplayRun] = []
      for row in [head] + rows {
        for (index, cell) in row.enumerated() {
          if index > 0 { result.append(run("\t", role: .table)) }
          result += inline(cell.content, role: .table)
        }
        result.append(run("\n", role: .table))
      }
      return result
    }
  }

  mutating func list(_ items: [ListItem], start: Int?) -> [DisplayRun] {
    var result: [DisplayRun] = []
    for (index, item) in items.enumerated() {
      let marker: String
      switch item.checkbox {
      case .checked: marker = "☑ "
      case .unchecked: marker = "☐ "
      case nil: marker = start.map { "\($0 + index). " } ?? "• "
      }
      result.append(run(marker, role: .listMarker))
      for child in item.blocks { result += block(child) }
    }
    return result
  }
}
