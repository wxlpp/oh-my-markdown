import Foundation
import MarkdownCore

/// Builds the semantic tree a screen reader traverses, from the parsed IR rather
/// than from rendered runs: `DisplayBlock` flattens a table to a list of cell
/// texts and drops a link's destination, so it cannot describe either.
///
/// Only leaves carry a label. A container that also spoke would make a reader
/// hear every link twice — once in the paragraph, once on its own.
public enum AccessibilityTreeBuilder {
    /// Localized stand-ins for content with nothing readable of its own. Alt text
    /// always wins over the generic image label.
    public static let imageFallback = NSLocalizedString(
        "markdown.accessibility.image", bundle: .module, comment: "Spoken for an image with no alt text"
    )
    public static let mathFallback = NSLocalizedString(
        "markdown.accessibility.math", bundle: .module, comment: "Spoken for a formula with no readable source"
    )

    public static func roots(
        for block: BlockNode, lineage: UInt64, sourceRange: MarkdownSourceRange?, sourceGeneration: UInt64,
        imageFallback: String, mathFallback: String
    ) -> [AccessibilityNode] {
        var builder = Builder(
            lineage: lineage, sourceRange: sourceRange, sourceGeneration: sourceGeneration,
            imageFallback: imageFallback, mathFallback: mathFallback
        )
        return builder.blockNodes(block)
    }
}

private struct Builder {
    let lineage: UInt64
    let sourceRange: MarkdownSourceRange?
    let sourceGeneration: UInt64
    let imageFallback: String
    let mathFallback: String
    /// Position within the block. Every leaf takes the next one, so two links in
    /// one paragraph — which share a lineage and a source anchor — differ.
    var ordinal = 0

    mutating func identity(_ role: AccessibilityRole) -> AccessibilityNodeID {
        defer { self.ordinal += 1 }
        return AccessibilityNodeID(
            sourceGeneration: self.sourceGeneration, role: role,
            startAnchor: self.sourceRange?.lowerBound ?? 0, lineage: self.lineage, ordinal: self.ordinal
        )
    }

    mutating func leaf(
        _ role: AccessibilityRole, _ label: String,
        activation: AccessibilityActivation? = nil, detail: AccessibilityDetail? = nil
    ) -> AccessibilityNode {
        AccessibilityNode(
            id: self.identity(role), role: role, label: label, sourceRange: self.sourceRange,
            activation: activation, detail: detail
        )
    }

    mutating func container(_ role: AccessibilityRole, _ children: [AccessibilityNode], detail: AccessibilityDetail? = nil) -> AccessibilityNode {
        AccessibilityNode(
            id: self.identity(role), role: role, label: nil, sourceRange: self.sourceRange,
            children: children, detail: detail
        )
    }

    mutating func blockNodes(_ block: BlockNode) -> [AccessibilityNode] {
        switch block {
        case .paragraph(let inlines):
            return self.inlineLeaves(inlines)
        case .heading(let level, let content):
            return self.inlineLeaves(content, plainRole: .heading(level: level))
        case .codeBlock(let language, let body):
            let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines)
            return [self.leaf(
                .code, body.trimmingCharacters(in: .newlines),
                detail: .code(language: (trimmed?.isEmpty ?? true) ? nil : trimmed)
            )]
        case .blockquote(let blocks):
            return blocks.flatMap { self.blockNodes($0) }
        case .bulletList(let items):
            return self.listNodes(items)
        case .orderedList(_, let items):
            return self.listNodes(items)
        case .thematicBreak, .htmlBlock:
            return []
        case .mathBlock(let latex):
            return [self.leaf(.math, latex.isEmpty ? self.mathFallback : latex)]
        case .table(_, let head, let rows):
            return [self.tableNode(head: head, rows: rows)]
        }
    }

    mutating func listNodes(_ items: [ListItem]) -> [AccessibilityNode] {
        items.enumerated().map { position, item in
            let children = item.blocks.flatMap { self.blockNodes($0) }
            // A one-leaf item speaks as itself rather than as a container with a
            // single silent child, so the reader hears one stop, not two.
            if children.count == 1, children[0].children.isEmpty, let label = children[0].label {
                return AccessibilityNode(
                    id: children[0].id, role: .listItem, label: label, sourceRange: self.sourceRange,
                    activation: children[0].activation,
                    detail: .listItem(position: position + 1, count: items.count)
                )
            }
            return self.container(.listItem, children, detail: .listItem(position: position + 1, count: items.count))
        }
    }

    mutating func tableNode(head: [TableCell], rows: [[TableCell]]) -> AccessibilityNode {
        let headerLabels = head.map { Self.plainText($0.content) }
        var rowNodes: [AccessibilityNode] = []
        if !head.isEmpty {
            let cells = head.enumerated().map { column, cell in
                self.leaf(
                    .columnHeader, Self.plainText(cell.content),
                    detail: .cell(row: 0, column: column, columnHeader: nil)
                )
            }
            rowNodes.append(self.container(.row, cells))
        }
        for (index, row) in rows.enumerated() {
            let cells = row.enumerated().map { column, cell in
                self.leaf(
                    .cell, Self.plainText(cell.content),
                    detail: .cell(
                        row: index + 1, column: column,
                        columnHeader: column < headerLabels.count ? headerLabels[column] : nil
                    )
                )
            }
            rowNodes.append(self.container(.row, cells))
        }
        return self.container(.table, rowNodes)
    }

    /// Splits text around the things a reader can focus on their own: a link, an
    /// image and a formula each become a stop, and the prose between them stays
    /// one stop rather than one per styled fragment.
    mutating func inlineLeaves(_ inlines: [InlineNode], plainRole: AccessibilityRole = .text) -> [AccessibilityNode] {
        var result: [AccessibilityNode] = []
        var pending = ""

        func flush(_ builder: inout Builder) {
            guard !pending.isEmpty else { return }
            result.append(builder.leaf(plainRole, pending))
            pending = ""
        }

        func walk(_ nodes: [InlineNode], _ builder: inout Builder) {
            for node in nodes {
                switch node {
                case .text(let value): pending += value
                case .softBreak: pending += " "
                case .lineBreak: pending += "\n"
                case .inlineCode(let value): pending += value
                case .html: break
                case .emphasis(let children), .strong(let children), .strikethrough(let children):
                    walk(children, &builder)
                case .link(let destination, _, let children):
                    flush(&builder)
                    let label = Self.plainText(children)
                    let activation = URL(string: destination).map {
                        AccessibilityActivation.link($0, sessionGeneration: builder.sourceGeneration)
                    }
                    result.append(builder.leaf(.link, label, activation: activation))
                case .image(_, let alt):
                    flush(&builder)
                    result.append(builder.leaf(.image, alt.isEmpty ? builder.imageFallback : alt))
                case .math(let latex):
                    flush(&builder)
                    result.append(builder.leaf(.math, latex.isEmpty ? builder.mathFallback : latex))
                }
            }
        }

        walk(inlines, &self)
        flush(&self)
        return result
    }

    static func plainText(_ inlines: [InlineNode]) -> String {
        var result = ""
        for node in inlines {
            switch node {
            case .text(let value), .inlineCode(let value), .math(let value): result += value
            case .softBreak: result += " "
            case .lineBreak: result += "\n"
            case .html: break
            case .emphasis(let children), .strong(let children), .strikethrough(let children):
                result += self.plainText(children)
            case .link(_, _, let children): result += self.plainText(children)
            case .image(_, let alt): result += alt
            }
        }
        return result
    }
}
