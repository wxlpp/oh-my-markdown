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
    /// Whole sentences, not words joined in English order: "row %1$d, column
    /// %2$d" has no word-for-word Chinese equivalent, and substituting the six
    /// pieces separately produced `第 2, 列 2` — a dangling measure word and no
    /// 行 at all.
    public static let cellPositionFormat = NSLocalizedString(
        "markdown.accessibility.cellPosition", bundle: .module,
        comment: "Table cell position; %1$d is the row number, %2$d the column"
    )
    public static let listPositionFormat = NSLocalizedString(
        "markdown.accessibility.listPosition", bundle: .module,
        comment: "List item position; %1$d is the item number, %2$d the count"
    )
    public static let checkedLabel = NSLocalizedString(
        "markdown.accessibility.checked", bundle: .module, comment: "Spoken for a completed task list item"
    )
    public static let uncheckedLabel = NSLocalizedString(
        "markdown.accessibility.unchecked", bundle: .module, comment: "Spoken for an open task list item"
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
    /// Position within the block, so two links in one paragraph — which share a
    /// lineage and a source anchor — differ. Advanced when a leaf *begins*, not
    /// when it is emitted, because `RenderPreparer` tags the runs on the same
    /// rule and the two numberings have to agree; ordinals may therefore skip,
    /// which costs nothing since only uniqueness and stability matter.
    var leafOrdinal = 0
    /// Containers are numbered apart so they never consume a leaf's ordinal.
    /// `AccessibilityNodeID` also carries the role, so a container and a leaf
    /// sharing a number are still distinct identities — but the *frame* key does
    /// not, so a container that reaches the platform as a leaf would take another
    /// leaf's rect. Containers must never be published as leaves.
    var containerOrdinal = 0

    mutating func advance() {
        self.leafOrdinal += 1
    }

    func identity(_ role: AccessibilityRole, ordinal: Int) -> AccessibilityNodeID {
        AccessibilityNodeID(
            sourceGeneration: self.sourceGeneration, role: role,
            startAnchor: self.sourceRange?.lowerBound ?? 0, lineage: self.lineage, ordinal: ordinal
        )
    }

    mutating func leaf(
        _ role: AccessibilityRole, _ label: String,
        activation: AccessibilityActivation? = nil, detail: AccessibilityDetail? = nil
    ) -> AccessibilityNode {
        AccessibilityNode(
            id: self.identity(role, ordinal: self.leafOrdinal), role: role, label: label,
            sourceRange: self.sourceRange, activation: activation, detail: detail
        )
    }

    mutating func nextContainerOrdinal() -> Int {
        defer { self.containerOrdinal += 1 }
        return self.containerOrdinal
    }

    mutating func container(_ role: AccessibilityRole, _ children: [AccessibilityNode], detail: AccessibilityDetail? = nil) -> AccessibilityNode {
        defer { self.containerOrdinal += 1 }
        return AccessibilityNode(
            id: self.identity(role, ordinal: self.containerOrdinal), role: role, label: nil,
            sourceRange: self.sourceRange, children: children, detail: detail
        )
    }

    mutating func blockNodes(_ block: BlockNode) -> [AccessibilityNode] {
        switch block {
        case .paragraph(let inlines):
            // Every block-level leaf sequence starts a new ordinal, or two
            // sibling paragraphs in one blockquote or list item collide: they
            // share a lineage and a source anchor, and a collision drops one of
            // them from the element list and speaks the other twice.
            self.advance()
            return self.inlineLeaves(inlines)
        case .heading(let level, let content):
            self.advance()
            let leaves = self.inlineLeaves(content, plainRole: .heading(level: level))
            // A heading whose whole content is one link would otherwise expose
            // only a link and vanish from heading navigation.
            guard leaves.count == 1, leaves[0].role != .heading(level: level) else { return leaves }
            return [AccessibilityNode(
                id: leaves[0].id, role: .heading(level: level), label: leaves[0].label,
                sourceRange: leaves[0].sourceRange, activation: leaves[0].activation,
                detail: leaves[0].detail
            )]
        case .codeBlock(let language, let body):
            let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.advance()
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
        case .htmlBlock(let text):
            // Rendered as visible text, so a reader has to get it as well.
            self.advance()
            return [self.leaf(.text, text.trimmingCharacters(in: .whitespacesAndNewlines))]
        case .thematicBreak:
            // Renders a rule and no text; there is nothing to speak. The
            // preparer emits no tagged run for it either.
            return []
        case .mathBlock(let latex):
            self.advance()
            return [self.leaf(.math, latex.isEmpty ? self.mathFallback : latex)]
        case .table(_, let head, let rows):
            return [self.tableNode(head: head, rows: rows)]
        }
    }

    mutating func listNodes(_ items: [ListItem]) -> [AccessibilityNode] {
        items.enumerated().compactMap { position, item -> AccessibilityNode? in
            let checkbox: Bool? = switch item.checkbox {
            case .checked: true
            case .unchecked: false
            case nil: nil
            }
            let detail = AccessibilityDetail.listItem(
                position: position + 1, count: items.count, checkbox: checkbox
            )
            let children = item.blocks.flatMap { self.blockNodes($0) }
            // An item with nothing readable in it is not a stop. It is also the
            // steady state of a streamed list — the next marker has arrived, its
            // text has not — and exposing it published an empty element whose
            // frame key, which carries no role, collided with a real leaf's.
            guard !children.isEmpty else { return nil }
            // A one-leaf item speaks as itself rather than as a container with a
            // single silent child, so the reader hears one stop, not two — but it
            // keeps the child's role, or an item holding only an image or a code
            // block would lose what it is.
            if children.count == 1, children[0].children.isEmpty, let label = children[0].label {
                return AccessibilityNode(
                    id: children[0].id, role: children[0].role == .text ? .listItem : children[0].role,
                    label: label, sourceRange: self.sourceRange,
                    activation: children[0].activation,
                    detail: children[0].detail ?? detail
                )
            }
            // I6: an item with nested content is still a list item, so it keeps
            // its role and position rather than becoming an anonymous container.
            return AccessibilityNode(
                id: self.identity(.listItem, ordinal: self.nextContainerOrdinal()), role: .listItem,
                label: nil, sourceRange: self.sourceRange, children: children, detail: detail
            )
        }
    }

    mutating func tableNode(head: [TableCell], rows: [[TableCell]]) -> AccessibilityNode {
        let headerLabels = head.map { Self.plainText($0.content) }
        var rowNodes: [AccessibilityNode] = []
        if !head.isEmpty {
            let cells = head.enumerated().map { column, cell in
                self.advance()
                return self.leaf(
                    .columnHeader, Self.plainText(cell.content),
                    detail: .cell(row: 0, column: column, columnHeader: nil)
                )
            }
            rowNodes.append(self.container(.row, cells))
        }
        for (index, row) in rows.enumerated() {
            let cells = row.enumerated().map { column, cell in
                self.advance()
                return self.leaf(
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
                case .html(let value): pending += value
                case .emphasis(let children), .strong(let children), .strikethrough(let children):
                    walk(children, &builder)
                case .link(let destination, _, let children):
                    flush(&builder)
                    builder.advance()
                    let label = Self.plainText(children)
                    let activation = URL(string: destination).map {
                        AccessibilityActivation.link($0, sessionGeneration: builder.sourceGeneration)
                    }
                    result.append(builder.leaf(.link, label, activation: activation))
                    builder.advance()
                case .image(_, let alt):
                    flush(&builder)
                    builder.advance()
                    result.append(builder.leaf(.image, alt.isEmpty ? builder.imageFallback : alt))
                    builder.advance()
                case .math(let latex):
                    flush(&builder)
                    builder.advance()
                    result.append(builder.leaf(.math, latex.isEmpty ? builder.mathFallback : latex))
                    builder.advance()
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
            case .html(let value): result += value
            case .emphasis(let children), .strong(let children), .strikethrough(let children):
                result += self.plainText(children)
            case .link(_, _, let children): result += self.plainText(children)
            case .image(_, let alt): result += alt
            }
        }
        return result
    }
}
