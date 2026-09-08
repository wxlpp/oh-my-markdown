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
        var metrics = ParseWorkMetrics(recording: input.attemptRecorder)
        let bundles = try self.prepareBlocks(input, range: 0 ..< input.document.blockStorage.count, metrics: &metrics)
        return RenderDisplayModel(bundles: bundles, input: input)
    }

    package func prepareBlocks(_ input: RenderInput, range: Range<Int>, metrics: inout ParseWorkMetrics, checkCancellation: @escaping ParseCancellationCheck = { try Task.checkCancellation() }) throws -> PersistentValues<DisplayBlockBundle> {
        guard input.configuration == self.configuration else { throw PreparationError.configurationMismatch }
        var builder = PreparationBuilder(configuration: configuration, checkCancellation: checkCancellation, width: input.availableWidth, mode: input.placeholderMode, work: ParseWorkMetrics(recording: metrics.recorder))
        defer { metrics.addRecorded(builder.work) }
        var bundles: [DisplayBlockBundle] = []
        for index in range {
            try checkCancellation()
            let block = input.document.blockStorage[index]
            builder.runs = []
            builder.resources = []
            builder.lineage = block.lineage
            builder.sourceRange = block.sourceRange
            builder.accessibilityLeaf = 0
            var pieces: [PreparedPiece] = []
            pieces.append(.blockStart)
            pieces += try builder.block(block.block, overlayEligible: true)
            builder.metadataBytes = ParseWorkMetrics.saturatingAdd(builder.metadataBytes, pieces.count * MemoryLayout<PreparedPiece>.stride)
            let display = DisplayBlock(lineage: builder.lineage, runs: builder.runs, sourceRange: block.sourceRange)
            let accessibility = AccessibilityTreeBuilder.roots(
                for: block.block, lineage: block.lineage, sourceRange: block.sourceRange,
                sourceGeneration: input.documentGeneration,
                imageFallback: AccessibilityTreeBuilder.imageFallback,
                mathFallback: AccessibilityTreeBuilder.mathFallback
            )
            bundles.append(DisplayBlockBundle(
                block: display, resources: builder.resources, content: pieces, accessibilityRoots: accessibility
            ))
            builder.metadataBytes = ParseWorkMetrics.saturatingAdd(builder.metadataBytes, MemoryLayout<DisplayBlockBundle>.stride)
        }
        builder.metadataBytes = ParseWorkMetrics.saturatingAdd(builder.metadataBytes, 88)
        return PersistentValues(bundles)
    }
}

private struct PreparationBuilder {
    /// Runs that render no accessibility leaf of their own — a list bullet.
    static let markerLeaf = -1

    let configuration: RenderConfigurationSnapshot
    let checkCancellation: ParseCancellationCheck
    var width: Double
    var mode: PlaceholderMode
    var lineage: UInt64 = 0
    var sourceRange: MarkdownSourceRange?
    /// Ordinal of the accessibility leaf currently being rendered; reset per block.
    var accessibilityLeaf = 0
    /// A table cell is one stop for a reader, so inline content inside one does
    /// not start further leaves.
    var accessibilityCellDepth = 0
    var quoteColor = false
    var quoteIndent: Double?
    var resolves = true
    var resources: [UnresolvedResource] = []
    var runs: [DisplayRun] = []
    var work = ParseWorkMetrics()
    var workBytes: Int {
        get { self.work.renderPreparationBytes }
        set { self.work.renderPreparationBytes = newValue }
    }

    var metadataBytes: Int {
        get { self.work.metadataBytes }
        set { self.work.metadataBytes = newValue }
    }

    mutating func payload(_ bytes: Int) throws {
        self.workBytes = ParseWorkMetrics.saturatingAdd(self.workBytes, bytes)
    }

    func body() -> PreparedAttributes {
        PreparedAttributes(color: self.quoteColor ? .quote : .body, paragraph: PreparedParagraph(spacing: self.configuration.spacing.paragraph))
    }

    func separator() -> PreparedRun {
        var attrs = self.body()
        attrs.color = nil
        attrs.paragraph = PreparedParagraph(lineSpacing: 0)
        // Renders no leaf, like the materializer's own block separator: it is the
        // join between two blocks, and a newline's segment sits at the end of the
        // previous line.
        return PreparedRun(
            text: "\n", attributes: attrs, accessibilityOrdinal: PreparationBuilder.markerLeaf
        )
    }

    mutating func text(_ value: String, attributes: PreparedAttributes, kind: PreparedRunKind = .text, resource: ResourceID? = nil, copyText: String? = nil, sourceText: String? = nil) -> PreparedRun {
        // String values are shared here; no source payload is inspected or copied.
        self.metadataBytes = ParseWorkMetrics.saturatingAdd(self.metadataBytes, MemoryLayout<DisplayRun>.stride + MemoryLayout<PreparedRun>.stride)
        self.runs.append(DisplayRun(text: resource != nil && self.mode == .static ? "\u{FFFC}" : value, role: attributes.role ?? .body, sourceRange: self.sourceRange, resourceID: resource))
        return PreparedRun(
            text: value, attributes: attributes, kind: kind, copyText: copyText, sourceText: sourceText,
            accessibilityOrdinal: self.accessibilityLeaf
        )
    }

    /// Advances to the next leaf. Called at the points `AccessibilityTreeBuilder`
    /// starts one, so a run carries the ordinal of the leaf it renders.
    mutating func nextAccessibilityLeaf() {
        guard self.accessibilityCellDepth == 0 else { return }
        self.accessibilityLeaf += 1
    }

    mutating func resource(_ make: (ResourceID) -> UnresolvedResource) -> ResourceID {
        let id = ResourceID(rawValue: "\(configuration.generation):\(self.lineage):\(self.resources.count)")
        self.workBytes = ParseWorkMetrics.saturatingAdd(self.workBytes, id.rawValue.utf8.count)
        self.metadataBytes = ParseWorkMetrics.saturatingAdd(self.metadataBytes, MemoryLayout<UnresolvedResource>.stride)
        self.resources.append(make(id))
        return id
    }

    mutating func inlines(_ nodes: [InlineNode], attributes: PreparedAttributes) throws -> [PreparedRun] {
        var result: [PreparedRun] = []
        for node in nodes {
            try self.checkCancellation()
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
                try self.payload(destination.utf8.count)
                attrs.color = .link; attrs.underline = true; attrs.destination = URL(string: destination)?.absoluteString
                try self.payload(attrs.destination?.utf8.count ?? 0)
                self.nextAccessibilityLeaf()
                result += try self.inlines(children, attributes: attrs)
                self.nextAccessibilityLeaf()
            case .image(let source, let alt):
                let id = self.resource { .image(id: $0, source: source, alt: alt) }
                self.nextAccessibilityLeaf()
                defer { self.nextAccessibilityLeaf() }
                attrs.color = .image
                let label = alt.isEmpty ? (source.isEmpty ? "image" : source) : alt
                try self.payload(label.utf8.count + 5)
                result.append(self.text("🖼 \(label)", attributes: attrs, kind: .image(id: id, source: source, width: self.width, resolves: self.resolves), resource: id, copyText: label, sourceText: "![\(alt)](\(source))"))
            case .math(let latex):
                let id = self.resource { .math(id: $0, latex: latex, display: false) }
                self.nextAccessibilityLeaf()
                defer { self.nextAccessibilityLeaf() }
                attrs.role = .code; attrs.traits = []; attrs.color = .secondary
                result.append(self.text(latex, attributes: attrs, kind: .math(id: id, latex: latex, display: false, width: self.width, staticPlaceholder: false, resolves: self.resolves), resource: id, sourceText: "$\(latex)$"))
            }
        }
        return result
    }

    mutating func block(_ node: BlockNode, overlayEligible: Bool = false) throws -> [PreparedPiece] {
        let result = try self.buildBlock(node, overlayEligible: overlayEligible)
        self.metadataBytes = ParseWorkMetrics.saturatingAdd(self.metadataBytes, result.count * MemoryLayout<PreparedPiece>.stride)
        return result
    }

    mutating func buildBlock(_ node: BlockNode, overlayEligible: Bool = false) throws -> [PreparedPiece] {
        try self.checkCancellation()
        var attrs = self.body()
        switch node {
        case .paragraph(let nodes):
            // Mirrors the tree: every block-level leaf sequence starts a new
            // ordinal, so two sibling paragraphs in a blockquote or list item
            // cannot collide.
            self.nextAccessibilityLeaf()
            return try self.inlines(nodes, attributes: attrs).map(PreparedPiece.run)
        case .heading(let level, let nodes):
            self.nextAccessibilityLeaf()
            attrs.role = .heading(level: min(max(level, 1), 6))
            attrs.paragraph = PreparedParagraph(lineSpacing: 2, spacing: level <= 2 ? 8 : 6, before: level <= 2 ? 24 : 20)
            return try self.inlines(nodes, attributes: attrs).map(PreparedPiece.run)
        case .codeBlock(let language, let body):
            self.nextAccessibilityLeaf()
            attrs.role = .code; attrs.color = .code
            attrs.paragraph = PreparedParagraph(lineSpacing: 4, head: 16, first: 16, tail: -16)
            let trimsNewline = body.hasSuffix("\n")
            try self.payload(min(body.utf8.count, 1))
            let trimmed = trimsNewline ? String(body.dropLast()) : body
            if trimsNewline { try self.payload(trimmed.utf8.count) }
            try self.payload(language?.utf8.count ?? 0)
            let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
            try self.payload(2 * (trimmedLanguage?.utf8.count ?? 0)) // trim output and lowercase input
            let normalizedLanguage = trimmedLanguage?.lowercased()
            try self.payload(normalizedLanguage?.utf8.count ?? 0)
            if normalizedLanguage == "svg" {
                let id = self.resource { .svg(id: $0, source: body) }
                let placeholderWidth: Double
                let placeholderHeight: Double
                var svgMetrics = ParseWorkMetrics(recording: self.work.recorder)
                let nativeSize: CGSize?
                do {
                    defer { self.work.addRecorded(svgMetrics) }
                    nativeSize = try SVGViewBoxParser.parseSize(from: body, metrics: &svgMetrics)
                }
                if let native = nativeSize {
                    placeholderWidth = self.width.isFinite && self.width > 0 ? min(native.width, self.width) : native.width
                    placeholderHeight = placeholderWidth * native.height / native.width
                } else {
                    placeholderWidth = self.width.isFinite && self.width > 0 ? self.width : 480
                    placeholderHeight = placeholderWidth * 0.6
                }
                return [.run(self.text(trimmed, attributes: attrs, kind: .svg(id: id, source: body, placeholderWidth: placeholderWidth, placeholderHeight: max(1, placeholderHeight), staticPlaceholder: self.mode == .static, resolves: self.resolves), resource: id, sourceText: "```svg\n\(body)\n```"))]
            }
            return [.run(self.text(trimmed, attributes: attrs, kind: .code(language: language)))]
        case .blockquote(let children):
            let old = (width, mode, quoteColor, resolves, quoteIndent)
            let indent = self.quoteIndent ?? self.configuration.spacing.quoteIndent
            self.width = .greatestFiniteMagnitude; self.mode = .streaming; self.quoteColor = true; self.resolves = false; self.quoteIndent = indent + 16
            var result: [PreparedPiece] = []
            for (index, child) in children.enumerated() {
                try self.checkCancellation()
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
            let restore = self.accessibilityLeaf
            self.accessibilityLeaf = PreparationBuilder.markerLeaf
            defer { self.accessibilityLeaf = restore }
            attrs.tinyFont = true; attrs.color = .clear
            attrs.paragraph = PreparedParagraph(lineSpacing: 0, spacing: 12, before: 12, height: 8)
            return [.run(self.text("\u{00A0}", attributes: attrs))]
        case .htmlBlock(let value):
            self.nextAccessibilityLeaf()
            return [.run(self.text(value, attributes: attrs))]
        case .mathBlock(let latex):
            self.nextAccessibilityLeaf()
            let id = self.resource { .math(id: $0, latex: latex, display: true) }
            attrs.role = .code; attrs.color = .secondary
            attrs.paragraph = PreparedParagraph(lineSpacing: 0, spacing: self.configuration.spacing.paragraph, centered: true)
            return [.run(self.text(latex, attributes: attrs, kind: .math(id: id, latex: latex, display: true, width: self.width, staticPlaceholder: self.mode == .static, resolves: self.resolves), resource: id, sourceText: "$$\(latex)$$"))]
        case .table(let columns, let head, let rows):
            var header = attrs; header.traits = [true]
            var preparedHead: [[PreparedRun]] = []
            var preparedRows: [[[PreparedRun]]] = []
            var headOrdinals: [Int] = []
            var rowOrdinals: [[Int]] = []
            for cell in head {
                self.nextAccessibilityLeaf()
                headOrdinals.append(self.accessibilityLeaf)
                self.accessibilityCellDepth += 1
                try preparedHead.append(self.inlines(cell.content, attributes: header))
                self.accessibilityCellDepth -= 1
            }
            for row in rows {
                try self.checkCancellation()
                var prepared: [[PreparedRun]] = []
                var ordinals: [Int] = []
                for cell in row {
                    self.nextAccessibilityLeaf()
                    ordinals.append(self.accessibilityLeaf)
                    self.accessibilityCellDepth += 1
                    try prepared.append(self.inlines(cell.content, attributes: attrs))
                    self.accessibilityCellDepth -= 1
                }
                preparedRows.append(prepared)
                rowOrdinals.append(ordinals)
            }
            return [.table(PreparedTable(
                overlayEligible: overlayEligible, columns: columns, head: preparedHead, rows: preparedRows,
                width: self.width, headOrdinals: headOrdinals, rowOrdinals: rowOrdinals
            ))]
        }
    }

    mutating func list(_ items: [ListItem], start: Int?, depth: Int = 0) throws -> [PreparedPiece] {
        var result: [PreparedPiece] = []
        for (index, item) in items.enumerated() {
            try self.checkCancellation()
            let bare = PreparedAttributes(role: nil, color: nil)
            if index > 0 { result.append(.run(self.text("\n", attributes: bare))) }
            let marker = start.map { "\($0 + index).\t" } ?? "•\t"
            let checkbox = switch item.checkbox { case .checked: "☑ "; case .unchecked: "☐ "; case nil: "" }
            var attrs = self.body()
            attrs.paragraph = PreparedParagraph(lineSpacing: 3, spacing: depth == 0 ? 4 : 2, head: Double(24 * (depth + 1)), first: Double(24 * depth), tab: Double(24 * (depth + 1)))
            let itemLeaf = self.accessibilityLeaf
            self.accessibilityLeaf = PreparationBuilder.markerLeaf
            result.append(.run(self.text(marker + checkbox, attributes: attrs)))
            self.accessibilityLeaf = itemLeaf
            var remaining = item.blocks[...]
            if let first = item.blocks.first, case .paragraph(let inlines) = first {
                // Inlined rather than routed through `block`, so the paragraph's
                // own leaf has to start here.
                self.nextAccessibilityLeaf()
                result += try self.inlines(inlines, attributes: attrs).map(PreparedPiece.run)
                remaining = item.blocks.dropFirst()
            }
            for child in remaining {
                let joinLeaf = self.accessibilityLeaf
                self.accessibilityLeaf = PreparationBuilder.markerLeaf
                result.append(.run(self.text("\n", attributes: bare)))
                self.accessibilityLeaf = joinLeaf
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
