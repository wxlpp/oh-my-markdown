import Foundation
import MarkdownCore

/// Traverses Markdown IR off-main into explicit immutable rendering instructions.
public struct RenderPreparer: Sendable {
    private let configuration: RenderConfigurationSnapshot
    public init(configuration: RenderConfigurationSnapshot) {
        self.configuration = configuration
    }

    public enum PreparationError: Error { case configurationMismatch }
    public func prepare(_ input: RenderInput) throws -> RenderDisplayModel {
        guard input.configuration == self.configuration else { throw PreparationError.configurationMismatch }
        var builder = PreparationBuilder(configuration: configuration, width: input.availableWidth, mode: input.placeholderMode)
        var pieces: [PreparedPiece] = []
        var blocks: [DisplayBlock] = []
        for (index, block) in input.document.parsedBlocks.enumerated() {
            try Task.checkCancellation()
            builder.lineage = UInt64(index)
            builder.sourceRange = block.sourceRange
            if index > 0 { pieces.append(.run(builder.separator())) }
            pieces.append(.blockStart)
            let start = builder.runs.count
            pieces += try builder.block(block.block)
            blocks.append(DisplayBlock(lineage: UInt64(index), runs: Array(builder.runs[start...]), sourceRange: block.sourceRange))
        }
        return RenderDisplayModel(runs: builder.runs, blocks: blocks, resources: builder.resources, input: input, preparedContent: pieces)
    }
}

private struct PreparationBuilder {
    let configuration: RenderConfigurationSnapshot
    var width: Double
    var mode: PlaceholderMode
    var lineage: UInt64 = 0
    var sourceRange: MarkdownSourceRange?
    var quoteColor = false
    var quoteIndent: Double?
    var resolves = true
    var resources: [UnresolvedResource] = []
    var runs: [DisplayRun] = []
    func body() -> PreparedAttributes {
        PreparedAttributes(color: self.quoteColor ? .quote : .body, paragraph: PreparedParagraph(spacing: self.configuration.spacing.paragraph))
    }

    func separator() -> PreparedRun {
        var attrs = self.body()
        attrs.color = nil
        attrs.paragraph = PreparedParagraph(lineSpacing: 0)
        return PreparedRun(text: "\n", attributes: attrs)
    }

    mutating func text(_ value: String, attributes: PreparedAttributes, kind: PreparedRunKind = .text, resource: ResourceID? = nil) -> PreparedRun {
        self.runs.append(DisplayRun(text: resource != nil && self.mode == .static ? "\u{FFFC}" : value, role: attributes.role ?? .body, sourceRange: self.sourceRange, resourceID: resource))
        return PreparedRun(text: value, attributes: attributes, kind: kind)
    }

    mutating func resource(_ make: (ResourceID) -> UnresolvedResource) -> ResourceID {
        let id = ResourceID(rawValue: "\(configuration.generation):\(self.lineage):\(self.resources.count)")
        self.resources.append(make(id))
        return id
    }

    mutating func inlines(_ nodes: [InlineNode], attributes: PreparedAttributes) throws -> [PreparedRun] {
        var result: [PreparedRun] = []
        for node in nodes {
            try Task.checkCancellation()
            var attrs = attributes
            switch node {
            case .text(let value), .html(let value): result.append(self.text(value, attributes: attrs))
            case .softBreak: result.append(self.text(" ", attributes: attrs))
            case .lineBreak: result.append(self.text("\n", attributes: attrs))
            case .inlineCode(let value):
                attrs.role = .code; attrs.traits = []; attrs.color = .inlineCode; attrs.background = .inlineBackground
                result.append(self.text(value, attributes: attrs))
            case .emphasis(let children):
                attrs.traits.append(false)
                result += try self.inlines(children, attributes: attrs)
            case .strong(let children):
                attrs.traits.append(true)
                result += try self.inlines(children, attributes: attrs)
            case .strikethrough(let children):
                attrs.strike = true
                result += try self.inlines(children, attributes: attrs)
            case .link(let destination, _, let children):
                attrs.color = .link; attrs.underline = true; attrs.destination = URL(string: destination)?.absoluteString
                result += try self.inlines(children, attributes: attrs)
            case .image(let source, let alt):
                let id = self.resource { .image(id: $0, source: source, alt: alt) }
                attrs.color = .image
                let label = alt.isEmpty ? (source.isEmpty ? "image" : source) : alt
                result.append(self.text("🖼 \(label)", attributes: attrs, kind: .image(id: id, source: source, width: self.width, resolves: self.resolves), resource: id))
            case .math(let latex):
                let id = self.resource { .math(id: $0, latex: latex, display: false) }
                attrs.role = .code; attrs.traits = []; attrs.color = .secondary
                result.append(self.text(latex, attributes: attrs, kind: .math(id: id, latex: latex, display: false, width: self.width, staticPlaceholder: false, resolves: self.resolves), resource: id))
            }
        }
        return result
    }

    mutating func block(_ node: BlockNode) throws -> [PreparedPiece] {
        try Task.checkCancellation()
        var attrs = self.body()
        switch node {
        case .paragraph(let nodes): return try self.inlines(nodes, attributes: attrs).map(PreparedPiece.run)
        case .heading(let level, let nodes):
            attrs.role = .heading(level: min(max(level, 1), 6))
            attrs.paragraph = PreparedParagraph(lineSpacing: 2, spacing: level <= 2 ? 8 : 6, before: level <= 2 ? 24 : 20)
            return try self.inlines(nodes, attributes: attrs).map(PreparedPiece.run)
        case .codeBlock(let language, let body):
            attrs.role = .code; attrs.color = .code
            attrs.paragraph = PreparedParagraph(lineSpacing: 4, head: 16, first: 16, tail: -16)
            let trimmed = body.hasSuffix("\n") ? String(body.dropLast()) : body
            if language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "svg" {
                let id = self.resource { .svg(id: $0, source: body) }
                let placeholderWidth: Double
                let placeholderHeight: Double
                if let native = SVGViewBoxParser.parseSize(from: body) {
                    placeholderWidth = self.width.isFinite && self.width > 0 ? min(native.width, self.width) : native.width
                    placeholderHeight = placeholderWidth * native.height / native.width
                } else {
                    placeholderWidth = self.width.isFinite && self.width > 0 ? self.width : 480
                    placeholderHeight = placeholderWidth * 0.6
                }
                return [.run(self.text(trimmed, attributes: attrs, kind: .svg(id: id, source: body, placeholderWidth: placeholderWidth, placeholderHeight: max(1, placeholderHeight), staticPlaceholder: self.mode == .static, resolves: self.resolves), resource: id))]
            }
            return [.run(self.text(trimmed, attributes: attrs, kind: .code(language: language)))]
        case .blockquote(let children):
            let old = (width, mode, quoteColor, resolves, quoteIndent)
            let indent = self.quoteIndent ?? self.configuration.spacing.quoteIndent
            self.width = .greatestFiniteMagnitude; self.mode = .streaming; self.quoteColor = true; self.resolves = false; self.quoteIndent = indent + 16
            var result: [PreparedPiece] = []
            for (index, child) in children.enumerated() {
                try Task.checkCancellation()
                if index > 0 { result.append(.run(self.separator())) }
                result += try self.block(child)
            }
            (self.width, self.mode, self.quoteColor, self.resolves, self.quoteIndent) = old
            return result.map { piece in
                switch piece {
                case .run(var run):
                    var paragraph = run.attributes.paragraph ?? PreparedParagraph(lineSpacing: 0)
                    paragraph.head += indent; paragraph.first += indent
                    run.attributes.paragraph = paragraph
                    return .run(run)
                case .table(var table): table.quoteIndent += indent; return .table(table)
                case .blockStart: return piece
                }
            }
        case .bulletList(let items): return try self.list(items, start: nil)
        case .orderedList(let start, let items): return try self.list(items, start: start)
        case .thematicBreak:
            attrs.tinyFont = true; attrs.color = .clear
            attrs.paragraph = PreparedParagraph(lineSpacing: 0, spacing: 12, before: 12, height: 8)
            return [.run(self.text("\u{00A0}", attributes: attrs))]
        case .htmlBlock(let value): return [.run(self.text(value, attributes: attrs))]
        case .mathBlock(let latex):
            let id = self.resource { .math(id: $0, latex: latex, display: true) }
            attrs.role = .code; attrs.color = .secondary
            attrs.paragraph = PreparedParagraph(lineSpacing: 0, spacing: self.configuration.spacing.paragraph, centered: true)
            return [.run(self.text(latex, attributes: attrs, kind: .math(id: id, latex: latex, display: true, width: self.width, staticPlaceholder: self.mode == .static, resolves: self.resolves), resource: id))]
        case .table(let columns, let head, let rows):
            var header = attrs; header.traits = [true]
            var preparedHead: [[PreparedRun]] = []
            var preparedRows: [[[PreparedRun]]] = []
            for cell in head {
                try preparedHead.append(self.inlines(cell.content, attributes: header))
            }
            for row in rows {
                try Task.checkCancellation()
                var prepared: [[PreparedRun]] = []
                for cell in row {
                    try prepared.append(self.inlines(cell.content, attributes: attrs))
                }
                preparedRows.append(prepared)
            }
            return [.table(PreparedTable(columns: columns, head: preparedHead, rows: preparedRows, width: self.width))]
        }
    }

    mutating func list(_ items: [ListItem], start: Int?, depth: Int = 0) throws -> [PreparedPiece] {
        var result: [PreparedPiece] = []
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let bare = PreparedAttributes(role: nil, color: nil)
            if index > 0 { result.append(.run(self.text("\n", attributes: bare))) }
            let marker = start.map { "\($0 + index).\t" } ?? "•\t"
            let checkbox = switch item.checkbox { case .checked: "☑ "; case .unchecked: "☐ "; case nil: "" }
            var attrs = self.body()
            attrs.paragraph = PreparedParagraph(lineSpacing: 3, spacing: depth == 0 ? 4 : 2, head: Double(24 * (depth + 1)), first: Double(24 * depth), tab: Double(24 * (depth + 1)))
            result.append(.run(self.text(marker + checkbox, attributes: attrs)))
            var remaining = item.blocks[...]
            if let first = item.blocks.first, case .paragraph(let inlines) = first {
                result += try self.inlines(inlines, attributes: attrs).map(PreparedPiece.run)
                remaining = item.blocks.dropFirst()
            }
            for child in remaining {
                result.append(.run(self.text("\n", attributes: bare)))
                switch child {
                case .bulletList(let items): result += try self.list(items, start: nil, depth: depth + 1)
                case .orderedList(let start, let items): result += try self.list(items, start: start, depth: depth + 1)
                default: result += try self.block(child)
                }
            }
        }
        return result
    }
}
