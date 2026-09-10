import CoreGraphics
import Foundation
import MarkdownCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The only new boundary that creates platform rendering objects.
@MainActor
package struct RenderMaterializer {
    private let configuration: RenderConfigurationSnapshot
    private var syntaxSpans: [PreparedSyntax] = []
    private var syntaxIndex = 0
    private var currentBlockIndex = 0

    package init(configuration: RenderConfigurationSnapshot) {
        self.configuration = configuration
    }

    package func materialize(
        _ model: RenderDisplayModel, resources: ResolvedResourceSnapshot, snapshotID: UUID = UUID()
    ) -> RenderSnapshot {
        if model.preparedDocument != nil {
            return self.materializePrepared(model: model, resources: resources, snapshotID: snapshotID)
        }
        let result = NSMutableAttributedString(string: "")
        var owners: [any ResourceResidencyOwner] = []
        for run in model.runs {
            let font = font(for: run.role)
            let token = run.role == .code ? self.configuration.colors.code : self.configuration.colors.body
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = self.configuration.spacing.paragraph
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: self.color(token), .paragraphStyle: paragraph,
            ]
            if let id = run.resourceID, let resource = resources.values[id] {
                let image: PlatformImage
                let baseline: Double
                let owner: any ResourceResidencyOwner
                switch resource {
                case .image(let value, let retained):
                    image = value
                    baseline = 0
                    owner = retained
                case .math(let retained), .svg(let retained):
                    image = retained.image
                    baseline = retained.baselineOffset
                    owner = retained
                }
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(
                    x: 0, y: baseline, width: image.size.width, height: image.size.height
                )
                let text = NSMutableAttributedString(attachment: attachment)
                text.addAttributes(attributes, range: NSRange(location: 0, length: text.length))
                result.append(text)
                owners.append(owner)
            } else {
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        return RenderSnapshot(id: snapshotID, attributedString: result, displayModel: model, resourceOwners: owners)
    }

    /// Converts audited immutable image backing to a platform image only here.
    package static func platformImage(
        from backing: ImmutableCGImageBacking, frame: Int = 0, scale: Double = 1
    ) -> PlatformImage? {
        guard backing.frames.indices.contains(frame), scale.isFinite, scale > 0 else { return nil }
        let image = backing.frames[frame]
        #if canImport(UIKit)
        return UIImage(cgImage: image, scale: scale, orientation: .up)
        #else
        return NSImage(
            cgImage: image,
            size: NSSize(width: Double(image.width) / scale, height: Double(image.height) / scale)
        )
        #endif
    }

    package func platformImage(
        from backing: ImmutableCGImageBacking, frame: Int = 0, scale: Double = 1
    ) -> PlatformImage? {
        Self.platformImage(from: backing, frame: frame, scale: scale)
    }

    private func font(for role: MarkdownTextRole) -> PlatformFont {
        let size =
            self.configuration.typography.pointSizes[role] ?? self.configuration.typography.pointSizes[.body] ?? 16
        if let data = configuration.typography.fontDescriptors[role] {
            #if canImport(UIKit)
            if let descriptor = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: UIFontDescriptor.self, from: data
            ) {
                return UIFont(descriptor: descriptor, size: size)
            }
            #else
            if let descriptor = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSFontDescriptor.self, from: data
            ),
                let font = NSFont(descriptor: descriptor, size: size) {
                return font
            }
            #endif
        }
        if let name = configuration.typography.fontNames[role],
           let font = PlatformFont(name: name, size: size) {
            return font
        }
        return role == .code
            ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
    }

    private func color(_ token: ColorToken) -> PlatformColor {
        PlatformColor(red: token.red, green: token.green, blue: token.blue, alpha: token.alpha)
    }

    private func materializePrepared(model: RenderDisplayModel, resources: ResolvedResourceSnapshot, snapshotID: UUID) -> RenderSnapshot {
        let result = NSMutableAttributedString(string: "")
        var starts: [Int] = []
        var owners: [any ResourceResidencyOwner] = []
        var overlays: [Int: RenderTableOverlay] = [:]
        let blocks = model.preparedDocument?.blockStorage ?? PersistentValues([])
        for (index, bundle) in model.bundles.enumerated() {
            var prepared = self
            // Recipes have the same traversal order as their prepared runs.
            // No source-key hashing/equality is moved into platform assembly.
            prepared.syntaxSpans = bundle.syntaxSpans
            prepared.syntaxIndex = 0
            prepared.currentBlockIndex = index
            if index > 0 {
                // Renders no leaf: it is the join between two blocks, and a
                // newline's segment sits at the end of the *previous* line, so
                // tagging it would stretch the next block's first element up
                // into the block before it.
                let separator = PreparedRun(
                    text: "\n", attributes: PreparedAttributes(color: nil, paragraph: PreparedParagraph(lineSpacing: 0)),
                    accessibilityOrdinal: -1
                )
                let join = NSMutableAttributedString(attributedString: prepared.materializeRun(separator, resources: resources, owners: &owners))
                if index - 1 < blocks.count, self.chromeInset(for: blocks[index - 1].block) > 0, result.length > 0,
                   let paragraph = result.attribute(.paragraphStyle, at: result.length - 1, effectiveRange: nil) {
                    join.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: join.length))
                }
                result.append(join)
            }
            let blockStart = result.length
            for piece in bundle.content {
                switch piece {
                case .blockStart: starts.append(result.length)
                case .run(let run): result.append(prepared.materializeRun(run, resources: resources, owners: &owners))
                case .table(let table): result.append(prepared.materializeTable(table, resources: resources, owners: &owners, overlays: &overlays))
                }
            }
            if index < blocks.count {
                let inset = self.chromeInset(for: blocks[index].block)
                if inset > 0, result.length > blockStart {
                    let string = result.mutableString
                    let first = string.paragraphRange(for: NSRange(location: blockStart, length: 0))
                    let last = string.paragraphRange(for: NSRange(location: result.length - 1, length: 0))
                    for (range, leading) in [(first, true), (last, false)] {
                        let style = ((result.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                        if leading { style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, inset + 4) }
                        else { style.paragraphSpacing = max(style.paragraphSpacing, inset + 4) }
                        result.addAttribute(.paragraphStyle, value: style, range: range)
                    }
                }
            }
        }
        return RenderSnapshot(id: snapshotID, attributedString: result, displayModel: model, resourceOwners: owners, blockStarts: starts, tableOverlays: overlays)
    }

    private func chromeInset(for block: BlockNode) -> CGFloat {
        switch block {
        case .codeBlock(let language, _):
            // SVG has its own placeholder/attachment reservation contract.
            language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "svg" ? 0 : 8
        case .table: 8
        case .blockquote: 4
        default: 0
        }
    }

    private func paragraph(_ value: PreparedParagraph) -> NSParagraphStyle {
        let result = NSMutableParagraphStyle()
        result.lineSpacing = value.lineSpacing
        result.paragraphSpacing = value.spacing
        result.paragraphSpacingBefore = value.before
        result.headIndent = value.head
        result.firstLineHeadIndent = value.first
        result.tailIndent = value.tail
        result.minimumLineHeight = value.height
        result.maximumLineHeight = value.height
        if value.centered { result.alignment = .center }
        // A snapshot is publicly constructible, and a stop at or before the
        // margin is not a stop; `defaultTabInterval` is documented non-negative.
        if let tab = value.tab, tab > 0 {
            result.tabStops = [NSTextTab(textAlignment: .natural, location: tab)]
            // Past its last tab stop a paragraph has nowhere to put a tab, and
            // TextKit drops the rest of the line instead of wrapping it: `10.` at
            // an accessibility size is wider than `tab` and would lose its item.
            result.defaultTabInterval = tab
        }
        return result.copy() as! NSParagraphStyle
    }

    private func preparedColor(_ value: PreparedColor) -> PlatformColor {
        switch value {
        case .body: self.color(self.configuration.colors.body)
        case .secondary: self.color(self.configuration.colors.secondary)
        case .code: self.color(self.configuration.colors.code)
        case .inlineCode: self.color(self.configuration.colors.additional["inlineCode"] ?? self.configuration.colors.code)
        case .inlineBackground: self.color(self.configuration.colors.additional["inlineCodeBackground"] ?? self.configuration.colors.body)
        case .link: self.color(self.configuration.colors.link)
        case .image: self.color(self.configuration.colors.link).withAlphaComponent(0.8)
        case .quote: self.color(self.configuration.colors.additional["quote"] ?? self.configuration.colors.secondary)
        case .clear: .clear
        }
    }

    private func attributes(_ value: PreparedAttributes) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [:]
        if let role = value.role {
            var resolved = self.font(for: role)
            for bold in value.traits {
                resolved = bold ? resolved.bold() : resolved.italic()
            }
            result[.font] = value.tinyFont ? PlatformFont.systemFont(ofSize: 1) : resolved
        }
        if let color = value.color { result[.foregroundColor] = self.preparedColor(color) }
        if let color = value.background { result[.backgroundColor] = self.preparedColor(color) }
        if let value = value.paragraph { result[.paragraphStyle] = self.paragraph(value) }
        if value.strike { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if value.underline { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if let url = value.destination.flatMap(URL.init(string:)) { result[.link] = url }
        return result
    }

    /// One character wide, which is what makes `.markdownCopyText` safe to
    /// substitute whole: a longer run would paste entirely for a selection that
    /// only touched part of it.
    private func attachment(image: PlatformImage?, bounds: CGRect, attributes: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = bounds
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
        return result
    }

    private mutating func nextSyntaxSpans() -> [SyntaxHighlightSpan] {
        defer { self.syntaxIndex += 1 }
        return self.syntaxIndex < self.syntaxSpans.count ? self.syntaxSpans[self.syntaxIndex].spans : []
    }

    /// A copy must never contain the object-replacement character an attachment
    /// occupies, so every attachment carries the text that stands in for it.
    private func copyText(of run: PreparedRun) -> String {
        run.copyText ?? run.text
    }

    private mutating func materializeRun(_ run: PreparedRun, resources: ResolvedResourceSnapshot, owners: inout [any ResourceResidencyOwner]) -> NSAttributedString {
        let result = self.materializeRunContent(run, resources: resources, owners: &owners)
        guard run.accessibilityOrdinal >= 0, result.length > 0 else { return result }
        let tagged = NSMutableAttributedString(attributedString: result)
        tagged.addAttribute(
            .markdownAccessibilityLeaf, value: AccessibilityLeafKey(block: self.currentBlockIndex, ordinal: run.accessibilityOrdinal),
            range: NSRange(location: 0, length: tagged.length)
        )
        return tagged
    }

    private mutating func materializeRunContent(_ run: PreparedRun, resources: ResolvedResourceSnapshot, owners: inout [any ResourceResidencyOwner]) -> NSAttributedString {
        var attrs = self.attributes(run.attributes)
        let copy = self.copyText(of: run)
        if let source = run.sourceText { attrs[.markdownCopySource] = source }
        var semantic: [NSAttributedString.Key: Any] = [.markdownCopyText: copy]
        if let source = run.sourceText { semantic[.markdownCopySource] = source }
        switch run.kind {
        case .text: return NSAttributedString(string: run.text, attributes: attrs)
        case .code:
            let spans = self.nextSyntaxSpans()
            let result = NSMutableAttributedString(attributedString: SyntaxHighlighter.highlight(run.text, spans: spans, font: self.font(for: .code), defaultColor: self.preparedColor(.code)))
            if let para = attrs[.paragraphStyle] { result.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: result.length)) }
            return result
        case .image(let id, let source, let width, let resolves):
            if resolves, case .image(let image, let owner) = resources.values[id] {
                owners.append(owner)
                let maxWidth = width.isFinite ? max(1, width) : 280
                let scale = image.size.width > maxWidth ? maxWidth / image.size.width : 1
                return self.attachment(image: image, bounds: CGRect(x: 0, y: -4, width: image.size.width * scale, height: image.size.height * scale), attributes: semantic)
            }
            attrs[.markdownImageSource] = source
            // The reader sees "🖼 alt" here and an image once it loads; both must
            // copy as the alt text alone, so the marker is dropped from copies
            // rather than substituted — substitution is for characters that read
            // as nothing, and it may only cover one character at a time.
            let placeholder = NSMutableAttributedString(string: run.text, attributes: attrs)
            // UTF-16 units, not Characters: the marker is an emoji and a range is
            // measured the way the attributed string is.
            let markerLength = (run.text as NSString).length - (copy as NSString).length
            if run.text.hasSuffix(copy), markerLength > 0 {
                placeholder.addAttribute(
                    .markdownCopySkip, value: true, range: NSRange(location: 0, length: markerLength)
                )
            }
            return placeholder
        case .math(let id, let latex, let display, let width, let staticPlaceholder, let resolves):
            let para = attrs[.paragraphStyle]
            if resolves, case .math(let owner) = resources.values[id] {
                let image = owner.image
                let baseline = owner.baselineOffset
                owners.append(owner)
                return self.attachment(image: image, bounds: CGRect(x: 0, y: baseline, width: image.size.width, height: image.size.height), attributes: display ? semantic.merging([.paragraphStyle: para!]) { a, _ in a } : semantic)
            }
            let payload = "\(display ? "1" : "0")\u{1F}\(latex)"
            if staticPlaceholder {
                let pointSize = self.configuration.typography.pointSizes[.body] ?? 16
                return self.attachment(image: nil, bounds: CGRect(x: 0, y: 0, width: width.isFinite ? width : pointSize * 10, height: max(1, pointSize * 2)), attributes: semantic.merging([.paragraphStyle: para!, .markdownMathSource: payload]) { a, _ in a })
            }
            attrs[.markdownMathSource] = payload
            return NSAttributedString(string: run.text, attributes: attrs)
        case .svg(let id, let source, let placeholderWidth, let placeholderHeight, let staticPlaceholder, let resolves):
            let spans = self.nextSyntaxSpans()
            var centered = PreparedParagraph(lineSpacing: 0, centered: true)
            if let inherited = run.attributes.paragraph {
                centered.head = inherited.head - 16
                centered.first = inherited.first - 16
            }
            if resolves, case .svg(let owner) = resources.values[id] {
                let image = owner.image
                owners.append(owner)
                return self.attachment(image: image, bounds: CGRect(origin: .zero, size: image.size), attributes: semantic.merging([.paragraphStyle: self.paragraph(centered)]) { a, _ in a })
            }
            if staticPlaceholder {
                return self.attachment(image: nil, bounds: CGRect(x: 0, y: 0, width: placeholderWidth, height: placeholderHeight), attributes: semantic.merging([.paragraphStyle: self.paragraph(centered), .markdownSVGBlockSource: source]) { a, _ in a })
            }
            let result = NSMutableAttributedString(attributedString: SyntaxHighlighter.highlight(run.text, spans: spans, font: self.font(for: .code), defaultColor: self.preparedColor(.code)))
            result.addAttributes([.paragraphStyle: attrs[.paragraphStyle]!, .markdownSVGBlockSource: source], range: NSRange(location: 0, length: result.length))
            return result
        }
    }

    /// Cell contents and alignment arrive prepared; only font-dependent measurements
    /// and platform paragraph/tab objects are resolved here.
    private mutating func materializeTable(_ table: PreparedTable, resources: ResolvedResourceSnapshot, owners: inout [any ResourceResidencyOwner], overlays: inout [Int: RenderTableOverlay]) -> NSAttributedString {
        guard !table.head.isEmpty else { return NSAttributedString(string: "") }
        let ownerStart = owners.count
        func cell(_ runs: [PreparedRun]) -> NSAttributedString {
            let result = NSMutableAttributedString(string: "")
            for run in runs {
                result.append(self.materializeRun(run, resources: resources, owners: &owners))
            }
            return result
        }
        let head = table.head.map(cell)
        let rows = table.rows.map { $0.map(cell) }
        let count = max(head.count, rows.map(\.count).max() ?? 0, table.columns.count, 1)
        var widths = Array(repeating: CGFloat(72), count: count)
        for row in [head] + rows {
            for (index, cell) in row.enumerated() {
                let bounds = cell.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                widths[index] = max(widths[index], ceil(bounds.width) + 24)
            }
        }
        widths = widths.map { ceil($0) }
        let usable = table.width > 28 ? table.width - 28 : Double(72 * count)
        let total = widths.reduce(0, +)
        if total < usable { widths = widths.map { $0 + (usable - total) / Double(count) } }
        let natural = 28 + widths.reduce(0, +)
        var start: CGFloat = 14
        let tabs = (0 ..< count).map { index -> NSTextTab in
            let lower = start
            let end = lower + widths[index] - 12
            start += widths[index]
            switch index < table.columns.count ? table.columns[index] : .none {
            case .right: return NSTextTab(textAlignment: .right, location: end)
            case .center: return NSTextTab(textAlignment: .center, location: lower + widths[index] / 2)
            case .left, .none: return NSTextTab(textAlignment: .left, location: lower + 12)
            }
        }
        let result = NSMutableAttributedString(string: "")
        for (index, row) in ([head] + rows).enumerated() {
            let body = self.attributes(PreparedAttributes(paragraph: PreparedParagraph(spacing: self.configuration.spacing.paragraph)))
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: body)) }
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 2
            para.paragraphSpacing = index == 0 ? 8 : 6
            para.paragraphSpacingBefore = index == 0 ? 8 : 6
            para.tabStops = tabs
            para.defaultTabInterval = 0
            var attrs = body
            if index == 0 { attrs[.font] = self.font(for: .body).bold() }
            attrs[.paragraphStyle] = para.copy() as! NSParagraphStyle
            var leading = attrs
            leading[.markdownCopySkip] = true
            let line = NSMutableAttributedString(string: "\t", attributes: leading)
            let ordinals = index == 0 ? table.headOrdinals : (index - 1 < table.rowOrdinals.count ? table.rowOrdinals[index - 1] : [])
            for (cellIndex, value) in row.enumerated() {
                // The tag spans the separator before the cell as well, so a cell
                // with no text still has an extent a reader can point at.
                // From 0 for the first cell: it has no separator before it, so an
                // empty one would otherwise have no extent and be dropped. The
                // row's leading tab carries `markdownCopySkip`, so covering it
                // costs a copy nothing.
                let cellStart = cellIndex == 0 ? 0 : line.length
                if cellIndex > 0 { line.append(NSAttributedString(string: "\t", attributes: attrs)) }
                let content = NSMutableAttributedString(attributedString: value)
                value.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: value.length)) { existing, range, _ in
                    if existing != nil { content.addAttribute(.paragraphStyle, value: para, range: range) }
                }
                line.append(content)
                if cellIndex < ordinals.count, line.length > cellStart {
                    line.addAttribute(
                        .markdownAccessibilityLeaf,
                        value: AccessibilityLeafKey(block: self.currentBlockIndex, ordinal: ordinals[cellIndex]),
                        range: NSRange(location: cellStart, length: line.length - cellStart)
                    )
                }
            }
            line.addAttributes([.markdownTableSection: index, .markdownTableColumns: count, .markdownTableColumnWidths: widths], range: NSRange(location: 0, length: line.length))
            result.append(line)
        }
        if natural > table.width + 0.5 {
            let height = TableMeasurement.height(of: result, naturalWidth: natural)
            let tsv = TableMeasurement.copyText(of: result)
            if table.overlayEligible {
                overlays[self.currentBlockIndex] = RenderTableOverlay(attributedString: result, naturalWidth: natural, height: height, style: self.resolvedStyle(), resourceOwners: Array(owners[ownerStart...]))
            }
            let para = self.paragraph(PreparedParagraph(lineSpacing: 0, head: table.quoteIndent, first: table.quoteIndent, height: height))
            return NSAttributedString(string: "\u{00A0}", attributes: [.font: PlatformFont.systemFont(ofSize: 1), .foregroundColor: PlatformColor.clear, .paragraphStyle: para, .markdownTableSection: 0, .markdownTableColumns: count, .markdownTableColumnWidths: widths, .markdownTableNaturalWidth: natural, .markdownOverflowTablePlaceholder: true, .markdownCopyText: tsv])
        }
        if table.quoteIndent != 0 {
            result.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: result.length)) { value, range, _ in
                let para = ((value as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                para.headIndent += table.quoteIndent
                para.firstLineHeadIndent += table.quoteIndent
                result.addAttribute(.paragraphStyle, value: para, range: range)
            }
        }
        return result
    }

    /// Decode inert descriptors and RGBA values only in this actor domain.
    package func resolvedStyle() -> RenderStyle {
        var style = RenderStyle.default
        style.bodyFont = self.font(for: .body)
        style.codeFont = self.font(for: .code)
        style.h1Font = self.font(for: .heading(level: 1))
        style.h2Font = self.font(for: .heading(level: 2))
        style.h3Font = self.font(for: .heading(level: 3))
        style.h4Font = self.font(for: .heading(level: 4))
        style.h5Font = self.font(for: .heading(level: 5))
        style.h6Font = self.font(for: .heading(level: 6))
        style.textColor = self.color(self.configuration.colors.body)
        style.secondaryTextColor = self.color(self.configuration.colors.secondary)
        style.codeTextColor = self.color(self.configuration.colors.code)
        style.linkColor = self.color(self.configuration.colors.link)
        let extra = self.configuration.colors.additional
        if let value = extra["codeBackground"] { style.codeBackgroundColor = self.color(value) }
        if let value = extra["inlineCode"] { style.inlineCodeTextColor = self.color(value) }
        if let value = extra["inlineCodeBackground"] { style.inlineCodeBgColor = self.color(value) }
        if let value = extra["quote"] { style.quoteColor = self.color(value) }
        if let value = extra["quoteBar"] { style.quoteBarColor = self.color(value) }
        if let value = extra["headingBorder"] { style.headingBorderColor = self.color(value) }
        if let value = extra["mathToken"] { style.mathTokenColor = self.color(value) }
        style.mathColorOverride = extra["mathOverride"].map(self.color)
        style.paragraphSpacing = self.configuration.spacing.paragraph
        style.quoteIndent = self.configuration.spacing.quoteIndent
        style.mathScale = self.configuration.mathScale
        return style
    }
}
