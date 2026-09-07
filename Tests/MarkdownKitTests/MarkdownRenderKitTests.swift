import MarkdownCore
@testable import MarkdownRenderKit
import Testing

// MARK: - MarkdownRenderKitTests

@Suite("MarkdownRenderKit")
@MainActor
struct MarkdownRenderKitTests {
    @Test("Incremental editor highlighting expands fenced code blocks")
    func incrementalHighlightRangeExpandsFencedCodeBlock() {
        let source = """
        before

        ```swift
        let value = 1
        print(value)
        ```

        after
        """
        let nsSource = source as NSString
        let editedRange = nsSource.range(of: "print(value)")

        let range = MarkdownSourceHighlighter(style: .default)
            .expandedHighlightRange(in: source, around: editedRange)
        let snippet = (source as NSString).substring(with: range)
        let normalizedSnippet = snippet.trimmingCharacters(in: .newlines)

        #expect(normalizedSnippet.hasPrefix("```swift"))
        #expect(normalizedSnippet.hasSuffix("```"))
    }

    @Test("Incremental editor highlighting stays within the affected paragraph")
    func incrementalHighlightRangeUsesParagraphOutsideCodeBlock() {
        let source = """
        first paragraph

        second paragraph with `code`

        third paragraph
        """
        let nsSource = source as NSString
        let editedRange = nsSource.range(of: "second paragraph")

        let range = MarkdownSourceHighlighter(style: .default)
            .expandedHighlightRange(in: source, around: editedRange)
        let snippet = (source as NSString).substring(with: range)

        #expect(snippet.contains("second paragraph with `code`"))
        #expect(snippet.contains("first paragraph") == false)
        #expect(snippet.contains("third paragraph") == false)
    }

    @Test("Incremental editor highlighting expands unclosed fenced code blocks to EOF")
    func incrementalHighlightRangeExpandsUnclosedFencedCodeBlock() {
        let source = """
        before

        ```swift
        let value = 1
        print(value)
        """
        let nsSource = source as NSString
        let editedRange = nsSource.range(of: "print(value)")

        let range = MarkdownSourceHighlighter(style: .default)
            .expandedHighlightRange(in: source, around: editedRange)
        let snippet = (source as NSString).substring(with: range)
        let normalizedSnippet = snippet.trimmingCharacters(in: .newlines)

        #expect(normalizedSnippet.hasPrefix("```swift"))
        #expect(normalizedSnippet.contains("print(value)"))
        #expect(range.upperBound == nsSource.length)
    }

    @Test("Markdown source highlighting styles headings emphasis links lists and code")
    func sourceHighlightingCoversEditorTokens() async {
        let style = RenderStyle.default
        let source = """
        # Title

        > Quote
        - [x] task item
        1. ordered item
        **bold** and *italic* and [link](https://example.com) and `code`

        ```swift
        let value = 1
        ```
        """

        let highlighter = MarkdownSourceHighlighter(style: style)
        var spans: [SyntaxHighlightKey: [SyntaxHighlightSpan]] = [:]
        for request in highlighter.syntaxRequests(for: source) {
            spans[request] = await SyntaxHighlightCache.shared.spans(for: request.code, language: request.language)
        }
        let highlighted = highlighter.highlight(source, syntaxSpans: spans)
        let ns = highlighted.string as NSString

        let titleIndex = ns.range(of: "Title").location
        let quoteMarkerIndex = ns.range(of: "> ").location
        let taskMarkerIndex = ns.range(of: "[x]").location
        let orderedMarkerIndex = ns.range(of: "1. ").location
        let boldIndex = ns.range(of: "bold").location
        let italicIndex = ns.range(of: "italic").location
        let linkIndex = ns.range(of: "[link](https://example.com)").location
        let inlineCodeIndex = ns.range(of: "`code`").location
        let swiftKeywordIndex = ns.range(of: "let value").location

        let titleFont = highlighted.attribute(.font, at: titleIndex, effectiveRange: nil) as? PlatformFont
        let quoteColor = highlighted.attribute(
            .foregroundColor,
            at: quoteMarkerIndex,
            effectiveRange: nil
        ) as? PlatformColor
        let taskColor = highlighted.attribute(
            .foregroundColor,
            at: taskMarkerIndex,
            effectiveRange: nil
        ) as? PlatformColor
        let orderedFont = highlighted.attribute(.font, at: orderedMarkerIndex, effectiveRange: nil) as? PlatformFont
        let boldFont = highlighted.attribute(.font, at: boldIndex, effectiveRange: nil) as? PlatformFont
        let italicFont = highlighted.attribute(.font, at: italicIndex, effectiveRange: nil) as? PlatformFont
        let linkColor = highlighted.attribute(.foregroundColor, at: linkIndex, effectiveRange: nil) as? PlatformColor
        let inlineCodeFont = highlighted.attribute(.font, at: inlineCodeIndex, effectiveRange: nil) as? PlatformFont
        let inlineCodeBackground = highlighted.attribute(
            .backgroundColor,
            at: inlineCodeIndex,
            effectiveRange: nil
        ) as? PlatformColor
        let fencedCodeFont = highlighted.attribute(.font, at: swiftKeywordIndex, effectiveRange: nil) as? PlatformFont
        let fencedCodeColor = highlighted.attribute(
            .foregroundColor,
            at: swiftKeywordIndex,
            effectiveRange: nil
        ) as? PlatformColor

        #expect(titleFont?.isEqual(style.h1Font) == true)
        #expect(quoteColor?.isEqual(fixtureColor(style.quoteBarColor)) == true)
        #expect(taskColor?.isEqual(fixtureColor(style.linkColor)) == true)
        #expect(orderedFont?.isEqual(style.codeFont) == true)
        #expect(isBold(font: boldFont) == true)
        #expect(isItalic(font: italicFont) == true)
        #expect(linkColor?.isEqual(fixtureColor(style.linkColor)) == true)
        #expect(inlineCodeFont?.isEqual(style.codeFont) == true)
        #expect(inlineCodeBackground?.isEqual(fixtureColor(style.inlineCodeBgColor)) == true)
        #expect(fencedCodeFont?.isEqual(style.codeFont) == true)
        #expect(fencedCodeColor?.isEqual(fixtureColor(style.codeTextColor)) == false)
    }

    @Test("Heading emphasis preserves heading size while applying traits")
    func headingEmphasisPreservesHeadingFontSize() {
        let style = RenderStyle.default
        let source = "# **Title** and *focus*"

        let highlighted = MarkdownSourceHighlighter(style: style).highlight(source)
        let ns = highlighted.string as NSString
        let boldIndex = ns.range(of: "Title").location
        let italicIndex = ns.range(of: "focus").location

        let boldFont = highlighted.attribute(.font, at: boldIndex, effectiveRange: nil) as? PlatformFont
        let italicFont = highlighted.attribute(.font, at: italicIndex, effectiveRange: nil) as? PlatformFont

        #expect(isBold(font: boldFont) == true)
        #expect(isItalic(font: italicFont) == true)
        #expect(fontSize(of: boldFont) == style.h1Font.pointSize)
        #expect(fontSize(of: italicFont) == style.h1Font.pointSize)
    }

    @Test("Table alignment markers produce matching tab-stop alignments")
    func tableAlignmentMarkersAreRendered() {
        let document = MarkdownDocument(parsing: """
        | Left | Center | Right |
        | :--- | :----: | ----: |
        | A | B | C |
        """)

        let renderer = MaterializationFixture(style: .default, availableWidth: 320)
        let rendered = renderer.render(document.blocks)
        let paragraph = rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let tabStops = paragraph?.tabStops ?? []

        #expect(tabStops.count == 3)
        #expect(tabStops[0].alignment == .left)
        #expect(tabStops[1].alignment == .center)
        #expect(tabStops[2].alignment == .right)
    }

    @Test("Unspecified table alignment is rendered as padded left")
    func unspecifiedTableAlignmentIsPaddedLeft() {
        let document = MarkdownDocument(parsing: """
        | Name | Value |
        | --- | --- |
        | A | B |
        """)

        let renderer = MaterializationFixture(style: .default, availableWidth: 320)
        let rendered = renderer.render(document.blocks)
        let paragraph = rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let tabStops = paragraph?.tabStops ?? []

        #expect(tabStops.count == 2)
        #expect(tabStops[0].alignment == .left)
        #expect(tabStops[1].alignment == .left)
        #expect(tabStops[0].location > 14)
        #expect(tabStops[1].location > tabStops[0].location + 72)
    }

    @Test("Table column widths expand to fit long cell content")
    func tableColumnWidthsExpandToFitLongCellContent() throws {
        let document = MarkdownDocument(parsing: """
        | Short | Description |
        | --- | --- |
        | A | This cell has enough text to require a wider natural table column. |
        """)

        let renderer = MaterializationFixture(style: .default, availableWidth: 180)
        let rendered = renderer.render(document.blocks)
        let widths = try #require(
            rendered
                .attribute(.markdownTableColumnWidths, at: 0, effectiveRange: nil) as? [CGFloat]
        )
        let naturalWidth = try #require(rendered.attribute(
            .markdownTableNaturalWidth,
            at: 0,
            effectiveRange: nil
        ) as? CGFloat)

        #expect(widths.count == 2)
        #expect(widths[1] > widths[0])
        #expect(naturalWidth > 180)
    }

    @Test("Overflow table uses a single forced-line-height placeholder in the main text layout")
    func overflowTableUsesLightweightPlaceholder() throws {
        let longText = "This cell has enough text to require a wider natural table column."
        let document = MarkdownDocument(parsing: """
        | Short | Description |
        | --- | --- |
        | A | \(longText) |
        """)

        let tableBlock = try #require(document.blocks.first)
        let renderer = MaterializationFixture(style: .default, availableWidth: 180)
        let rendered = renderer.render(document.blocks)
        let naturalWidth = try #require(
            rendered.attribute(.markdownTableNaturalWidth, at: 0, effectiveRange: nil) as? CGFloat
        )

        // The overflow table reservation collapsed to ONE invisible NBSP whose
        // paragraph style pins min == max line height to the table's *true*
        // rendered height, computed at render time by `TableMeasurement.height`
        // (the same algorithm & inputs the platform overlay's `TableContentView`
        // uses → constructively equal, no write-back). No cell text leaks into
        // the main stack, and there are no NBSP placeholder rows / newlines.
        #expect(rendered.string.contains(longText) == false)
        #expect(rendered.length == 1)
        #expect(rendered.string == "\u{00A0}")
        // Reserved height = a precise forced line-height (no font-leading slack)
        // equal to the overlay-equal true table height.
        let para = try #require(
            rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(para.maximumLineHeight > 0)
        #expect(para.maximumLineHeight == para.minimumLineHeight)
        // The marker the platform layer keys on to locate & position this block.
        #expect(
            rendered.attribute(.markdownOverflowTablePlaceholder, at: 0, effectiveRange: nil) as? Bool == true
        )
        // Markers preserved so platform overlay positioning / decoration skip still work.
        #expect(rendered.attribute(.markdownTableColumns, at: 0, effectiveRange: nil) as? Int == 2)
        // Constructive-equality contract, asserted directly against the single
        // height source of truth — `TableMeasurement.height` — instead of a
        // proxy attribute. The reserved forced line-height must exactly equal
        // `TableMeasurement.height` of the full (non-overflow) table string the
        // platform overlay's `TableContentView` lays out, at the same natural
        // width. We reconstruct that exact input the way the platform layer does
        // (`MaterializationFixture(availableWidth: naturalWidth).renderBlock`),
        // so this pins the same arithmetic on the same TextKit 2 layout the
        // overlay uses — no attribute, no platform write-back. If anyone changes
        // `overflowTablePlaceholder` to reserve a height other than
        // `TableMeasurement.height`, this assertion goes red.
        let overlayRenderer = MaterializationFixture(style: .default, availableWidth: naturalWidth)
        let fullTableString = overlayRenderer.renderBlock(tableBlock)
        let constructiveHeight = TableMeasurement.height(
            of: fullTableString,
            naturalWidth: naturalWidth
        )
        #expect(constructiveHeight > 0)
        #expect(para.maximumLineHeight == constructiveHeight)
    }

    @Test("Renderer reuses image cache when source URL has already been loaded")
    func rendererUsesCachedImages() {
        let block = BlockNode.paragraph([
            .image(source: "https://example.com/image.png", alt: "Example"),
        ])
        let cachedImage = makeImage()
        var renderer = MaterializationFixture(style: .default, availableWidth: 320)
        renderer.images["https://example.com/image.png"] = cachedImage

        let rendered = renderer.render([block])

        #expect(rendered.attribute(.attachment, at: 0, effectiveRange: nil) != nil)
        #expect(rendered.string.contains("Example") == false)
    }

    @Test("Renderer scales cached images to available width")
    func rendererScalesCachedImagesToAvailableWidth() throws {
        let block = BlockNode.paragraph([
            .image(source: "https://example.com/wide.png", alt: "Wide"),
        ])
        var renderer = MaterializationFixture(style: .default, availableWidth: 320)
        renderer.images["https://example.com/wide.png"] = makeImage(width: 800, height: 400)

        let rendered = renderer.render([block])
        let attachment = try #require(rendered.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)

        #expect(attachment.bounds.width == 320)
        #expect(attachment.bounds.height == 160)
    }

    @Test("RenderStyle.isSemanticallyEqual covers every stored property")
    func renderStyleSemanticallyEqualCoversAllProperties() {
        // If a property is added to RenderStyle, isSemanticallyEqual must be updated
        // to compare it. This test guards against silently missing one.
        let propertyCount = Mirror(reflecting: RenderStyle.default).children.count
        // 23 includes the three math fields (mathScale, mathColorOverride, mathTokenColor);
        // mathScale/mathColorOverride were added in Task 8, mathTokenColor in Task 9;
        // isSemanticallyEqual compares all three.
        #expect(
            propertyCount == 23,
            "RenderStyle has \(propertyCount) stored properties; update isSemanticallyEqual to match."
        )
    }
}

#if canImport(UIKit)
import UIKit

private func makeImage(width: CGFloat = 8, height: CGFloat = 8) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { ctx in
        UIColor.systemBlue.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

private func isBold(font: UIFont?) -> Bool {
    guard let font else {
        return false
    }
    return font.fontDescriptor.symbolicTraits.contains(.traitBold)
}

private func isItalic(font: UIFont?) -> Bool {
    guard let font else {
        return false
    }
    return font.fontDescriptor.symbolicTraits.contains(.traitItalic)
}

private func fontSize(of font: UIFont?) -> CGFloat? {
    font?.pointSize
}

#elseif canImport(AppKit)
import AppKit

private func makeImage(width: CGFloat = 8, height: CGFloat = 8) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
    image.unlockFocus()
    return image
}

private func isBold(font: NSFont?) -> Bool {
    guard let font else {
        return false
    }
    return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
}

private func isItalic(font: NSFont?) -> Bool {
    guard let font else {
        return false
    }
    return NSFontManager.shared.traits(of: font).contains(.italicFontMask)
}

private func fontSize(of font: NSFont?) -> CGFloat? {
    font?.pointSize
}
#endif
