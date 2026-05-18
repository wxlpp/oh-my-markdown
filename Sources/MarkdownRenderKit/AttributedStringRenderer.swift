import Foundation
import MarkdownCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Custom attribute keys

extension NSAttributedString.Key {
    /// Image source URL string; marks inline placeholder text pending async load.
    public static let markdownImageSource = NSAttributedString.Key("MarkdownKit.imageSource")
    /// Table row section: 0 = header, 1+ = body row index (used by decoration drawing).
    public static let markdownTableSection = NSAttributedString.Key("MarkdownKit.tableSection")
    /// Number of columns in the table (used to compute tab stops and draw column separators).
    public static let markdownTableColumns = NSAttributedString.Key("MarkdownKit.tableColumns")
    /// Natural (uncompressed) table width when the table overflows the available width.
    /// Presence of this attribute signals the view to show a horizontal-scroll overlay.
    public static let markdownTableNaturalWidth = NSAttributedString.Key("MarkdownKit.tableNaturalWidth")
    /// Natural widths for each rendered table column, used by platform views to draw separators.
    public static let markdownTableColumnWidths = NSAttributedString.Key("MarkdownKit.tableColumnWidths")
    /// Marks the single transparent placeholder line that reserves vertical
    /// space for an overflowing (horizontally-scrolling) table. The real table is
    /// drawn by the platform scroll overlay; the reserved height is computed *at
    /// render time* by `TableMeasurement.height` (the same algorithm the overlay's
    /// `TableContentView` uses), so the main-stack reservation and the overlay
    /// height are constructively equal — no platform write-back needed.
    public static let markdownOverflowTablePlaceholder
        = NSAttributedString.Key("MarkdownKit.overflowTablePlaceholder")
}

// MARK: - TableMeasurement

/// Single source of truth for an overflowing table's rendered height.
///
/// Both the main-stack reservation (`AttributedStringRenderer.overflowTablePlaceholder`)
/// and the platform scroll overlay (`TableContentView`) call this *exact* function
/// with the *exact* same inputs (the full non-overflow table attributed string and
/// the table's natural width), so the height they use is constructively equal — it
/// is the same arithmetic on the same TextKit 2 layout, not two algorithms that
/// happen to agree within a tolerance.
public enum TableMeasurement {
    /// The single height arithmetic core: `ceil(usageBoundsForTextContainer
    /// .height) + 16` (the +16 chrome inset). Both entry points
    /// (`height(of:naturalWidth:)` building its own stack, and
    /// `height(usingLaidOut:)` reusing an already-laid-out manager) funnel
    /// through *this* function, so for the same table content they produce a
    /// byte-for-byte identical height — the wide-table root-cause invariant
    /// (constructive equality, one arithmetic, never two algorithms).
    @inline(__always)
    private static func heightCore(usingLaidOut layoutManager: NSTextLayoutManager) -> CGFloat {
        ceil(layoutManager.usageBoundsForTextContainer.height) + 16
    }

    /// Reuse a TextKit 2 layout manager the caller has **already laid out**
    /// (e.g. `TableContentView`'s own stack after its `ensureLayout`) and
    /// return the table height via the shared `heightCore`. The caller is
    /// responsible for configuring the stack identically to
    /// `height(of:naturalWidth:)` (`lineFragmentPadding = 0`, container width
    /// = natural width, full `ensureLayout`) so the inputs to `heightCore` are
    /// the same — avoiding a second TextKit 2 stack + second full layout per
    /// init / streaming table update while keeping the height constructively
    /// equal to the main-stack reservation.
    public static func height(usingLaidOut layoutManager: NSTextLayoutManager) -> CGFloat {
        self.heightCore(usingLaidOut: layoutManager)
    }

    /// Lays `tableString` out in an independent TextKit 2 stack constrained to
    /// `naturalWidth`, then returns the height via the shared `heightCore`
    /// (`lineFragmentPadding = 0`, container width = natural width, full
    /// `ensureLayout`, +16 chrome inset). Used by the main-stack reservation
    /// (`overflowTablePlaceholder`) which has no pre-existing layout manager.
    /// Pure, MainActor-free, platform-neutral.
    public static func height(of tableString: NSAttributedString, naturalWidth: CGFloat) -> CGFloat {
        guard tableString.length > 0, naturalWidth > 0 else {
            return 0
        }
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        textContainer.lineFragmentPadding = 0
        layoutManager.textContainer = textContainer
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.attributedString = tableString
        textContainer.size = CGSize(width: naturalWidth, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return self.heightCore(usingLaidOut: layoutManager)
    }
}

// MARK: - AttributedStringRenderer

/// Converts an array of ``BlockNode``s to a single ``NSAttributedString``
/// suitable for display in a ``UITextView`` / ``NSTextView``.
///
/// The renderer is a pure value type with no mutable state — it is safe to
/// share across threads and to instantiate multiple times cheaply.
public struct AttributedStringRenderer: @unchecked Sendable {
    public init(style: RenderStyle = .default, availableWidth: CGFloat = .greatestFiniteMagnitude) {
        self.style = style
        self.availableWidth = availableWidth
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        para.paragraphSpacing = style.paragraphSpacing
        self.bodyParagraph = para.copy() as! NSParagraphStyle
        let sepPara = NSMutableParagraphStyle()
        sepPara.paragraphSpacing = 0
        sepPara.lineSpacing = 0
        self.separator = NSAttributedString(
            string: "\n",
            attributes: [
                .font: style.bodyFont,
                .paragraphStyle: sepPara.copy() as! NSParagraphStyle,
            ]
        )
    }

    public let style: RenderStyle
    /// Available render width used to compute table column tab stops.
    public let availableWidth: CGFloat
    /// Pre-computed block separator — avoids allocating NSMutableParagraphStyle per blockSeparator() call.
    public let separator: NSAttributedString
    /// Cache of loaded images, keyed by source URL string. Updated by MarkdownLabelView after async load.
    public var imageCache: [String: PlatformImage] = [:]
    /// 渲染好的公式字形缓存，键含有效字号/颜色/scale/renderer 代际。平台层填充。
    public var mathCache: [MathCacheKey: MathRenderedGlyph] = [:]
    /// 当前光栅化 scale 与 renderer 代际，参与缓存键（平台层设置）。
    public var mathRasterScale: CGFloat = 1
    public var mathRendererGeneration: Int = 0

    /// Render an array of top-level blocks.
    public func render(_ blocks: [BlockNode]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.append(self.blockSeparator())
            }
            result.append(self.renderBlock(block))
        }
        return result.copy() as! NSAttributedString
    }

    // MARK: - Block rendering

    public func renderBlock(_ block: BlockNode) -> NSAttributedString {
        switch block {
        case .paragraph(let inlines):
            self.renderParagraph(inlines)
        case .heading(let level, let inlines):
            self.renderHeading(level: level, content: inlines)
        case .codeBlock(let language, let body):
            self.renderCodeBlock(language: language, body: body)
        case .blockquote(let blocks):
            self.renderBlockquote(blocks)
        case .bulletList(let items):
            self.renderBulletList(items)
        case .orderedList(let start, let items):
            self.renderOrderedList(items, start: start)
        case .thematicBreak:
            self.renderThematicBreak()
        case .htmlBlock(let text):
            NSAttributedString(string: text, attributes: self.bodyAttributes())
        case .mathBlock(let latex):
            self.renderMathBlock(latex: latex)
        case .table(let columns, let head, let rows):
            self.renderTable(columns: columns, head: head, rows: rows)
        }
    }

    /// A narrow separator inserted between consecutive top-level blocks.
    public func blockSeparator() -> NSAttributedString {
        self.separator
    }

    /// Pre-computed body paragraph style — avoids allocating NSMutableParagraphStyle on every inline node.
    private let bodyParagraph: NSParagraphStyle

    // MARK: Paragraph

    private func renderParagraph(_ inlines: [InlineNode]) -> NSAttributedString {
        self.renderInlines(inlines, attributes: self.bodyAttributes())
    }

    // MARK: Heading

    private func renderHeading(level: Int, content: [InlineNode]) -> NSAttributedString {
        var attrs = self.bodyAttributes()
        attrs[.font] = self.style.headingFont(level: level)
        let para = NSMutableParagraphStyle()
        // Generous space above headings, tighter below (GitHub uses margin-top > margin-bottom)
        para.paragraphSpacingBefore = level <= 2 ? 24 : 20
        para.paragraphSpacing = level <= 2 ? 8 : 6
        para.lineSpacing = 2
        attrs[.paragraphStyle] = para
        return self.renderInlines(content, attributes: attrs)
    }

    // MARK: Code block

    private func renderCodeBlock(language: String?, body: String) -> NSAttributedString {
        // Trim single trailing newline added by cmark-gfm.
        let text = body.hasSuffix("\n") ? String(body.dropLast()) : body
        let para = NSMutableParagraphStyle()
        // Horizontal padding mirrors the rounded-rect drawn in MarkdownLabelView.
        para.headIndent = 16
        para.firstLineHeadIndent = 16
        para.tailIndent = -16
        para.lineSpacing = 4
        para.paragraphSpacing = 0
        let highlighted = SyntaxHighlighter.highlight(
            text,
            language: language,
            font: self.style.codeFont,
            defaultColor: self.style.codeTextColor
        ).mutableCopy() as! NSMutableAttributedString
        highlighted.addAttribute(
            .paragraphStyle,
            value: para.copy() as! NSParagraphStyle,
            range: NSRange(location: 0, length: highlighted.length)
        )
        return highlighted
    }

    // MARK: Blockquote

    private func renderBlockquote(_ blocks: [BlockNode]) -> NSAttributedString {
        let indentedStyle = self.style.indentedForQuote()
        let subRenderer = AttributedStringRenderer(style: indentedStyle)
        let inner = subRenderer.render(blocks).mutableCopy() as! NSMutableAttributedString
        let range = NSRange(location: 0, length: inner.length)
        // Body text is already rendered with quoteColor because indentedForQuote() sets
        // textColor = quoteColor. We do NOT do a blanket foregroundColor overwrite here —
        // that would destroy inline-code, link, and image placeholder colors.
        // Add left indentation via paragraph style
        inner.enumerateAttribute(.paragraphStyle, in: range) { value, subRange, _ in
            let base = (value as? NSParagraphStyle) ?? NSParagraphStyle.default
            let mutable = base.mutableCopy() as! NSMutableParagraphStyle
            mutable.headIndent += self.style.quoteIndent
            mutable.firstLineHeadIndent += self.style.quoteIndent
            inner.addAttribute(.paragraphStyle, value: mutable, range: subRange)
        }
        return inner
    }

    // MARK: Lists

    private func renderBulletList(_ items: [ListItem], depth: Int = 0) -> NSAttributedString {
        self.joinedListItems(items.map { self.renderListItem($0, prefix: "•\t", depth: depth) })
    }

    private func renderOrderedList(_ items: [ListItem], start: Int, depth: Int = 0) -> NSAttributedString {
        let rendered = items.enumerated().map { index, item in
            self.renderListItem(item, prefix: "\(start + index).\t", depth: depth)
        }
        return self.joinedListItems(rendered)
    }

    private func renderListItem(_ item: ListItem, prefix: String, depth: Int = 0) -> NSAttributedString {
        let checkboxPrefix = switch item.checkbox {
        case .checked: "\u{2611} " // ☑
        case .unchecked: "\u{2610} " // ☐
        case nil: ""
        }

        // Each nesting level adds 24pt: depth=0 → indent=24, depth=1 → indent=48, etc.
        let baseIndent: CGFloat = 24
        let indent = baseIndent * CGFloat(depth + 1)
        let bulletIndent = baseIndent * CGFloat(depth)
        let para = NSMutableParagraphStyle()
        para.headIndent = indent
        para.firstLineHeadIndent = bulletIndent
        para.tabStops = [NSTextTab(textAlignment: .natural, location: indent)]
        para.paragraphSpacing = depth == 0 ? 4 : 2
        para.lineSpacing = 3

        // Build own-line content: bullet prefix + first paragraph (if any)
        let result = NSMutableAttributedString(string: prefix + checkboxPrefix, attributes: self.bodyAttributes())
        let remainingBlocks: ArraySlice<BlockNode>
        if let firstBlock = item.blocks.first, case .paragraph(let inlines) = firstBlock {
            result.append(self.renderInlines(inlines, attributes: self.bodyAttributes()))
            remainingBlocks = item.blocks.dropFirst()
        } else {
            remainingBlocks = item.blocks[...]
        }

        // Apply paragraph style ONLY to own-line content so nested sub-list styles are preserved.
        result.addAttribute(
            .paragraphStyle,
            value: para,
            range: NSRange(location: 0, length: result.length)
        )

        // Append nested blocks (each carries its own paragraph style).
        for block in remainingBlocks {
            result.append(NSAttributedString(string: "\n"))
            switch block {
            case .bulletList(let subItems):
                result.append(self.renderBulletList(subItems, depth: depth + 1))
            case .orderedList(let s, let subItems):
                result.append(self.renderOrderedList(subItems, start: s, depth: depth + 1))
            default:
                result.append(self.renderBlock(block))
            }
        }
        return result
    }

    private func joinedListItems(_ items: [NSAttributedString]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (i, item) in items.enumerated() {
            if i > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            result.append(item)
        }
        return result
    }

    // MARK: Thematic break

    private func renderThematicBreak() -> NSAttributedString {
        // Invisible 8pt-tall placeholder — the visible line is drawn by MarkdownLabelView.
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = 12
        para.paragraphSpacing = 12
        para.minimumLineHeight = 8
        para.maximumLineHeight = 8
        return NSAttributedString(
            string: "\u{00A0}",
            attributes: [
                .font: PlatformFont.systemFont(ofSize: 1),
                .foregroundColor: PlatformColor.clear,
                .paragraphStyle: para,
            ]
        )
    }

    // MARK: Table

    private func renderTable(
        columns: [ColumnAlignment],
        head: [TableCell],
        rows: [[TableCell]]
    )
        -> NSAttributedString {
        guard !head.isEmpty else {
            return NSAttributedString()
        }
        let result = NSMutableAttributedString()
        let rowColumnCount = rows.map(\.count).max() ?? 0
        let cols = max(head.count, rowColumnCount, columns.count, 1)

        // Column widths are content-aware so horizontally scrolling tables do not draw
        // text across visual cell borders. If the table fits, distribute spare width.
        let minColWidth: CGFloat = 72
        let horizontalInset: CGFloat = 14
        let cellHorizontalPadding: CGFloat = 12
        let usableWidth = self.availableWidth > horizontalInset * 2
            ? self.availableWidth - horizontalInset * 2
            : minColWidth * CGFloat(cols)
        let measuredWidths = self.tableColumnWidths(
            columns: cols,
            head: head,
            rows: rows,
            cellHorizontalPadding: cellHorizontalPadding,
            minColWidth: minColWidth
        )
        let measuredTotal = measuredWidths.reduce(0, +)
        let colWidths: [CGFloat]
        if measuredTotal < usableWidth {
            let extraPerColumn = (usableWidth - measuredTotal) / CGFloat(cols)
            colWidths = measuredWidths.map { $0 + extraPerColumn }
        } else {
            colWidths = measuredWidths
        }
        let naturalTableWidth = horizontalInset * 2 + colWidths.reduce(0, +)
        let needsScroll = naturalTableWidth > self.availableWidth + 0.5
        let columnAlignments = (0 ..< cols).map { index in
            index < columns.count ? columns[index] : .none
        }
        var columnStart = horizontalInset
        let tabStops: [NSTextTab] = (0 ..< cols).map { index in
            let start = columnStart
            let end = start + colWidths[index] - cellHorizontalPadding
            columnStart += colWidths[index]
            let alignment = columnAlignments[index]
            switch alignment {
            case .right:
                return NSTextTab(textAlignment: .right, location: end, options: [:])
            case .center:
                return NSTextTab(textAlignment: .center, location: start + colWidths[index] / 2, options: [:])
            case .left:
                return NSTextTab(textAlignment: .left, location: start + cellHorizontalPadding, options: [:])
            case .none:
                return NSTextTab(textAlignment: .left, location: start + cellHorizontalPadding, options: [:])
            }
        }

        // Header paragraph style
        let headerPara: NSParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 2
            p.paragraphSpacing = 8
            p.paragraphSpacingBefore = 8
            p.headIndent = 0
            p.firstLineHeadIndent = 0
            p.tabStops = tabStops
            p.defaultTabInterval = 0
            return p.copy() as! NSParagraphStyle
        }()

        // Body row paragraph style
        let bodyRowPara: NSParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 2
            p.paragraphSpacingBefore = 6
            p.paragraphSpacing = 6
            p.headIndent = 0
            p.firstLineHeadIndent = 0
            p.tabStops = tabStops
            p.defaultTabInterval = 0
            return p.copy() as! NSParagraphStyle
        }()

        // Header row — cells separated by \t so tab stops control column alignment
        var hAttrs = self.bodyAttributes()
        hAttrs[.font] = self.style.bodyFont.bold()
        hAttrs[.paragraphStyle] = headerPara
        let headerStr = NSMutableAttributedString(string: "\t", attributes: hAttrs)
        for (i, cell) in head.enumerated() {
            if i > 0 {
                headerStr.append(NSAttributedString(string: "\t", attributes: hAttrs))
            }
            headerStr.append(self.renderInlines(cell.content, attributes: hAttrs))
        }
        headerStr.addAttribute(
            .markdownTableSection,
            value: 0,
            range: NSRange(location: 0, length: headerStr.length)
        )
        headerStr.addAttribute(
            .markdownTableColumns,
            value: cols,
            range: NSRange(location: 0, length: headerStr.length)
        )
        headerStr.addAttribute(
            .markdownTableColumnWidths,
            value: colWidths,
            range: NSRange(location: 0, length: headerStr.length)
        )
        result.append(headerStr)

        // Body rows
        for (rowIdx, row) in rows.enumerated() {
            result.append(NSAttributedString(string: "\n", attributes: self.bodyAttributes()))
            var rAttrs = self.bodyAttributes()
            rAttrs[.paragraphStyle] = bodyRowPara
            let rowStr = NSMutableAttributedString(string: "\t", attributes: rAttrs)
            for (i, cell) in row.enumerated() {
                if i > 0 {
                    rowStr.append(NSAttributedString(string: "\t", attributes: rAttrs))
                }
                rowStr.append(self.renderInlines(cell.content, attributes: rAttrs))
            }
            let section = rowIdx + 1
            rowStr.addAttribute(
                .markdownTableSection,
                value: section,
                range: NSRange(location: 0, length: rowStr.length)
            )
            rowStr.addAttribute(
                .markdownTableColumns,
                value: cols,
                range: NSRange(location: 0, length: rowStr.length)
            )
            rowStr.addAttribute(
                .markdownTableColumnWidths,
                value: colWidths,
                range: NSRange(location: 0, length: rowStr.length)
            )
            result.append(rowStr)
        }
        // When the table is too wide, keep only a single lightweight placeholder
        // line in the main TextKit stack. The real table is rendered by the scroll
        // overlay at natural width. The reserved height is computed *here, at
        // render time*, by measuring this very `result` (the full non-overflow
        // table string) at `naturalTableWidth` via `TableMeasurement.height` —
        // the exact same function & inputs the overlay's `TableContentView` uses,
        // so the reservation and the overlay height are constructively equal. No
        // platform write-back; every re-render (incl. per-token streaming) emits
        // the correct height, so there is no convergence race.
        if needsScroll {
            let trueTableHeight = TableMeasurement.height(
                of: result,
                naturalWidth: naturalTableWidth
            )
            return self.overflowTablePlaceholder(
                columns: cols,
                trueTableHeight: trueTableHeight,
                columnWidths: colWidths,
                naturalTableWidth: naturalTableWidth
            )
        }
        return result
    }

    /// A single invisible placeholder that reserves vertical space for an
    /// overflowing (horizontally-scrolling) table. The real table is drawn by
    /// the platform scroll overlay (`TableContentView` at natural width). The
    /// reserved height is `trueTableHeight` — measured at render time by
    /// `TableMeasurement.height` from the *same* full table string the overlay
    /// lays out, at the *same* natural width — so the main-stack reservation and
    /// the overlay height are constructively equal (one arithmetic on one layout,
    /// not two algorithms reconciled by write-back). Every re-render (incl. the
    /// per-token streaming re-render forced by `tailReparseStartIndex`) emits the
    /// correct height, so there is no convergence race and no platform write-back.
    private func overflowTablePlaceholder(
        columns: Int,
        trueTableHeight: CGFloat,
        columnWidths: [CGFloat],
        naturalTableWidth: CGFloat
    )
        -> NSAttributedString {
        // Reserve the height via a single forced-line-height paragraph (the exact
        // technique `renderThematicBreak` uses for a precise reservation): one
        // invisible NBSP in a 1pt clear font whose paragraph style pins
        // minimum == maximum line height to `trueTableHeight`. This makes the
        // laid-out fragment height *exactly* the overlay height (no font
        // asc/descent/leading slack — which is why an attachment's `bounds` alone
        // was ~3pt off).
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 0
        para.paragraphSpacing = 0
        para.paragraphSpacingBefore = 0
        para.minimumLineHeight = trueTableHeight
        para.maximumLineHeight = trueTableHeight

        let result = NSMutableAttributedString(
            string: "\u{00A0}",
            attributes: [
                .font: PlatformFont.systemFont(ofSize: 1),
                .foregroundColor: PlatformColor.clear,
                .paragraphStyle: para.copy() as! NSParagraphStyle,
            ]
        )
        // Keep the existing table marker attributes so the platform layer can
        // still locate this table block (overlay positioning, decorations skip,
        // column separators). section 0 keeps it a single logical row group.
        self.applyTableAttributes(
            to: result,
            section: 0,
            columns: columns,
            columnWidths: columnWidths,
            naturalTableWidth: naturalTableWidth
        )
        result.addAttribute(
            .markdownOverflowTablePlaceholder,
            value: true,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    private func applyTableAttributes(
        to string: NSMutableAttributedString,
        section: Int,
        columns: Int,
        columnWidths: [CGFloat],
        naturalTableWidth: CGFloat
    ) {
        let range = NSRange(location: 0, length: string.length)
        string.addAttribute(.markdownTableSection, value: section, range: range)
        string.addAttribute(.markdownTableColumns, value: columns, range: range)
        string.addAttribute(.markdownTableColumnWidths, value: columnWidths, range: range)
        string.addAttribute(.markdownTableNaturalWidth, value: naturalTableWidth, range: range)
    }

    private func tableColumnWidths(
        columns: Int,
        head: [TableCell],
        rows: [[TableCell]],
        cellHorizontalPadding: CGFloat,
        minColWidth: CGFloat
    )
        -> [CGFloat] {
        var widths = Array(repeating: minColWidth, count: columns)
        var headerAttrs = self.bodyAttributes()
        headerAttrs[.font] = self.style.bodyFont.bold()
        for (index, cell) in head.enumerated() where index < columns {
            widths[index] = max(
                widths[index],
                measuredInlineWidth(cell.content, attributes: headerAttrs) + cellHorizontalPadding * 2
            )
        }

        let rowAttrs = self.bodyAttributes()
        for row in rows {
            for (index, cell) in row.enumerated() where index < columns {
                widths[index] = max(
                    widths[index],
                    measuredInlineWidth(cell.content, attributes: rowAttrs) + cellHorizontalPadding * 2
                )
            }
        }
        return widths.map { ceil($0) }
    }

    private func measuredInlineWidth(
        _ inlines: [InlineNode],
        attributes: [NSAttributedString.Key: Any]
    )
        -> CGFloat {
        let rendered = self.renderInlines(inlines, attributes: attributes)
        guard rendered.length > 0 else {
            return 0
        }
        let rect = rendered.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(rect.width)
    }

    // MARK: - Inline rendering

    private func renderInlines(
        _ inlines: [InlineNode],
        attributes: [NSAttributedString.Key: Any]
    )
        -> NSAttributedString {
        let result = NSMutableAttributedString()
        for node in inlines {
            result.append(self.renderInline(node, attributes: attributes))
        }
        return result
    }

    private func renderInline(
        _ node: InlineNode,
        attributes: [NSAttributedString.Key: Any]
    )
        -> NSAttributedString {
        switch node {
        case .text(let str):
            return NSAttributedString(string: str, attributes: attributes)

        case .softBreak:
            return NSAttributedString(string: " ", attributes: attributes)

        case .lineBreak:
            return NSAttributedString(string: "\n", attributes: attributes)

        case .inlineCode(let code):
            var a = attributes
            a[.font] = self.style.codeFont
            a[.foregroundColor] = self.style.inlineCodeTextColor
            a[.backgroundColor] = self.style.inlineCodeBgColor
            return NSAttributedString(string: code, attributes: a)

        case .emphasis(let children):
            var a = attributes
            if let font = a[.font] as? PlatformFont {
                a[.font] = font.italic()
            }
            return self.renderInlines(children, attributes: a)

        case .strong(let children):
            var a = attributes
            if let font = a[.font] as? PlatformFont {
                a[.font] = font.bold()
            }
            return self.renderInlines(children, attributes: a)

        case .strikethrough(let children):
            var a = attributes
            a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            return self.renderInlines(children, attributes: a)

        case .link(let destination, _, let children):
            var a = attributes
            a[.foregroundColor] = self.style.linkColor
            a[.underlineStyle] = NSUnderlineStyle.single.rawValue
            if let url = URL(string: destination) {
                a[.link] = url
            }
            return self.renderInlines(children, attributes: a)

        case .image(let source, let alt):
            // If the image is cached, return an inline attachment.
            if let image = imageCache[source] {
                let attachment = NSTextAttachment()
                attachment.image = image
                let maxW: CGFloat = self.availableWidth.isFinite ? max(1, self.availableWidth) : 280
                let sz = image.size
                let scale = sz.width > maxW ? maxW / sz.width : 1.0
                attachment.bounds = CGRect(
                    x: 0,
                    y: -4,
                    width: sz.width * scale,
                    height: sz.height * scale
                )
                return NSAttributedString(attachment: attachment)
            }
            // Placeholder with custom attribute so the view can start async loading.
            let label = alt.isEmpty ? (source.isEmpty ? "image" : source) : alt
            var a = attributes
            a[.foregroundColor] = self.style.linkColor.withAlphaComponent(0.8)
            a[.markdownImageSource] = source
            return NSAttributedString(string: "\u{1F5BC} \(label)", attributes: a)

        case .html(let raw):
            return NSAttributedString(string: raw, attributes: attributes)

        case .math(let latex):
            return self.renderMath(latex: latex, display: false, baseAttributes: attributes)
        }
    }

    // MARK: - Math rendering

    private func mathPayload(latex: String, display: Bool) -> String {
        "\(display ? "1" : "0")\u{1F}\(latex)"
    }

    private func effectiveMathPointSize() -> CGFloat {
        // Known limitation: math size is anchored to bodyFont unconditionally. Inline $x$
        // inside a heading will size off body, not the heading run font. Threading the
        // active run font through renderInline would be a larger refactor; inline math in
        // headings is uncommon enough that this trade-off is accepted.
        let base = self.style.bodyFont.pointSize
        return MathMetrics.effectivePointSize(textPointSize: base, mathScale: self.style.mathScale)
    }

    private func mathColor() -> PlatformColor {
        self.style.mathColorOverride ?? self.style.textColor
    }

    private func renderMath(
        latex: String,
        display: Bool,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let key = MathCacheKey(
            latex: latex, display: display,
            pointSize: self.effectiveMathPointSize(),
            colorHex: MathMetrics.colorHex(self.mathColor()),
            rasterScale: self.mathRasterScale,
            rendererGeneration: self.mathRendererGeneration
        )
        if let glyph = self.mathCache[key] {
            let attachment = NSTextAttachment()
            attachment.image = glyph.image
            let sz = glyph.image.size
            let exToPoints = self.effectiveMathPointSize() * 0.5
            attachment.bounds = CGRect(
                x: 0,
                y: glyph.baselineOffsetEx * exToPoints,
                width: sz.width,
                height: sz.height
            )
            return NSAttributedString(attachment: attachment)
        }
        var a = baseAttributes
        a[.font] = self.style.codeFont
        a[.foregroundColor] = self.style.secondaryTextColor
        a[.markdownMathSource] = self.mathPayload(latex: latex, display: display)
        return NSAttributedString(string: latex, attributes: a)
    }

    private func renderMathBlock(latex: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = self.style.paragraphSpacing
        let base = self.bodyAttributes().merging([.paragraphStyle: para]) { _, new in new }
        let body = self.renderMath(latex: latex, display: true, baseAttributes: base)
        let m = NSMutableAttributedString(attributedString: body)
        m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
        return m
    }

    // MARK: - Attribute helpers

    private func bodyAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: self.style.bodyFont,
            .foregroundColor: self.style.textColor,
            .paragraphStyle: self.bodyParagraph,
        ]
    }

}
