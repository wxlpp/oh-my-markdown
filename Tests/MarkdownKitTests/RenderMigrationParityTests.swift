import CryptoKit
import Foundation
import MarkdownCore
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Frozen Task 4B output preserves independent attribute/layout expectations.
/// Literal assertions keep individual contracts readable alongside the JSON baseline.
@MainActor
struct RenderMigrationParityTests {
    @Test func overflowOverlayRetainsFullAttributedTableAndMeasuredGeometry() async throws {
        let source = "before\n\n| **Bold** | [Link](https://example.com/table) |\n| :--- | ---: |\n| *italic* | `code` |\n\nafter"
        let pair = try await self.render(source, width: 120)
        let overlay = try #require(pair.snapshot.tableOverlays[1])
        #expect(pair.snapshot.attributedString.string == "before\n\u{00A0}\nafter")
        #expect(pair.snapshot.blockStarts == [0, 7, 9])
        #expect(overlay.attributedString.string == "\tBold\tLink\n\titalic\tcode")
        var style = RenderStyle.default
        style.bodyFont = .systemFont(ofSize: 16)
        try self.assertGolden(overlay.attributedString, model: pair.snapshot.displayModel, width: overlay.naturalWidth)
        #expect(overlay.naturalWidth >= 172)
        #expect(overlay.height == TableMeasurement.height(of: overlay.attributedString, naturalWidth: overlay.naturalWidth))
        let paragraph = try #require(pair.snapshot.attributedString.attribute(.paragraphStyle, at: 7, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.minimumLineHeight == overlay.height)
        let link = (overlay.attributedString.string as NSString).range(of: "Link")
        #expect(overlay.attributedString.attribute(.link, at: link.location, effectiveRange: nil) as? URL == URL(string: "https://example.com/table"))
    }

    @Test func overflowOverlayOwnsCellResourcesBeyondMainPlaceholder() async throws {
        let source = "| Photo | Math |\n|---|---|\n| ![alt](image.png) | $x$ |"
        var style = RenderStyle.default
        style.bodyFont = .systemFont(ofSize: 16)
        let configuration = style.snapshot(generation: 1)
        let document = MarkdownDocument(parsing: source)
        let input = RenderInput(document: document, source: source, availableWidth: 120, configuration: configuration, placeholderMode: .static)
        let model = try await RenderPreparer(configuration: configuration).prepare(input).preparingSyntax()
        let context = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let materializer = RenderMaterializer(configuration: configuration)
        let cgImage = try #require(context.makeImage())
        let backing = try ImmutableCGImageBacking(frames: [cgImage])
        let image = try #require(materializer.platformImage(from: backing))
        weak var observed: TestResourceOwner?
        var snapshot: RenderSnapshot?
        do {
            let owner = TestResourceOwner(retaining: image)
            observed = owner
            var values: [ResourceID: ResolvedPlatformResource] = [:]
            for resource in model.resources {
                switch resource {
                case .image(let id, _, _): values[id] = .image(image, owner: owner)
                case .math(let id, _, _): values[id] = .math(owner: RenderedResourceRecord(image: image, baselineOffset: -3).acquireLease())
                case .svg: break
                }
            }
            snapshot = materializer.materialize(model, resources: .init(values: values))
        }
        #expect(observed != nil)
        do {
            let overlay = try #require(snapshot?.tableOverlays[0])
            #expect(snapshot?.attributedString.string == "\u{00A0}")
            #expect(overlay.attributedString.string == "\tPhoto\tMath\n\t\u{FFFC}\t\u{FFFC}")
            try self.assertGolden(overlay.attributedString, model: #require(snapshot?.displayModel), width: overlay.naturalWidth)
            var bounds: [CGRect] = []
            overlay.attributedString.enumerateAttribute(.attachment, in: NSRange(location: 0, length: overlay.attributedString.length)) { value, _, _ in
                if let attachment = value as? NSTextAttachment { bounds.append(attachment.bounds) }
            }
            #expect(bounds == [CGRect(x: 0, y: -4, width: 40, height: 20), CGRect(x: 0, y: -3, width: 40, height: 20)])
            #expect(overlay.height == TableMeasurement.height(of: overlay.attributedString, naturalWidth: overlay.naturalWidth))
        }
        snapshot = nil
        #expect(observed == nil)
    }

    @Test(arguments: ["hello", "newest"])
    func singleParagraphHasNoSyntheticTerminalNewline(source: String) async throws {
        let pair = try await self.render(source, width: 320)
        #expect(pair.snapshot.attributedString.string == source)
        try self.assertParity(pair, width: 320)
    }

    @Test(arguments: [120.0, 640.0])
    func inlineTraitsLinksCodeAndBlockSeparators(width: Double) async throws {
        let source = "# Heading\n\n*italic* **bold** ~~gone~~ [label](https://example.com/path?q=1) `let x`"
        let pair = try await render(source, width: width)
        #expect(pair.snapshot.attributedString.string == "Heading\nitalic bold gone label let x")
        try self.assertParity(pair, width: width)
        let text = pair.snapshot.attributedString
        let link = (text.string as NSString).range(of: "label")
        #expect(text.attribute(.link, at: link.location, effectiveRange: nil) as? URL == URL(string: "https://example.com/path?q=1"))
        let strike = (text.string as NSString).range(of: "gone")
        #expect(text.attribute(.strikethroughStyle, at: strike.location, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        let code = (text.string as NSString).range(of: "let x")
        #expect(text.attribute(.backgroundColor, at: code.location, effectiveRange: nil) != nil)
    }

    @Test(arguments: [120.0, 640.0])
    func quotesNestedAndTaskListsPreserveMarkersAndIndents(width: Double) async throws {
        let source = "> outer\n>\n> > inner `code`\n\n3. first\n4. second\n\n- [x] done\n- [ ] pending\n  - child"
        let pair = try await render(source, width: width)
        let expected = "outer\ninner code\n3.\tfirst\n4.\tsecond\n•\t☑ done\n•\t☐ pending\n•\tchild"
        #expect(pair.snapshot.attributedString.string == expected)
        try self.assertParity(pair, width: width)
    }

    @Test(arguments: [120.0, 640.0])
    func fencedCodeHTMLAndThematicBreak(width: Double) async throws {
        let source = "```swift\nlet answer = 42\n```\n\n---\n\n<div>raw</div>"
        let pair = try await render(source, width: width)
        #expect(pair.snapshot.attributedString.string == "let answer = 42\n\u{00A0}\n<div>raw</div>\n")
        try self.assertParity(pair, width: width)
    }

    @Test(arguments: [120.0, 640.0])
    func alignedTableMeasuresOverflowAndTabStops(width: Double) async throws {
        let pair = try await render("| Left | Center | Right |\n| :--- | :---: | ---: |\n| a | b | c |", width: width)
        let expected = width == 120 ? "\u{00A0}" : "\tLeft\tCenter\tRight\n\ta\tb\tc"
        #expect(pair.snapshot.attributedString.string == expected)
        try self.assertParity(pair, width: width)
        let text = pair.snapshot.attributedString
        #expect(text.attribute(.markdownTableColumns, at: 0, effectiveRange: nil) as? Int == 3)
        if width == 120 {
            #expect(text.attribute(.markdownOverflowTablePlaceholder, at: 0, effectiveRange: nil) as? Bool == true)
            let natural = try #require(text.attribute(.markdownTableNaturalWidth, at: 0, effectiveRange: nil) as? CGFloat)
            #expect(natural > 120)
        } else {
            let paragraph = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            #expect(paragraph.tabStops.map(\.alignment) == [.left, .center, .right])
        }
    }

    @Test(arguments: [PlaceholderMode.static, .streaming])
    func missingResourcesPreserveReadableFallbacksAndStaticGeometry(mode: PlaceholderMode) async throws {
        let source = "![alt](missing.png) $x$\n\n$$\ny=2\n$$\n\n```svg\n<svg viewBox=\"0 0 200 100\"/>\n```"
        let pair = try await render(source, width: 120, mode: mode)
        let expected = mode == .static ? "🖼 alt x\n\u{FFFC}\n\u{FFFC}" : "🖼 alt x\ny=2\n<svg viewBox=\"0 0 200 100\"/>"
        #expect(pair.snapshot.attributedString.string == expected)
        try self.assertParity(pair, width: 120)
        if mode == .static {
            var bounds: [CGRect] = []
            pair.snapshot.attributedString.enumerateAttribute(.attachment, in: NSRange(location: 0, length: pair.snapshot.attributedString.length)) { value, _, _ in
                if let attachment = value as? NSTextAttachment { bounds.append(attachment.bounds) }
            }
            #expect(bounds == [CGRect(x: 0, y: 0, width: 120, height: 32), CGRect(x: 0, y: 0, width: 120, height: 60)])
        }
    }

    private struct Pair {
        let snapshot: RenderSnapshot
    }

    @Test
    func sourceCopyAndProgrammaticFallbackUseMaterializedUTF16Offsets() async throws {
        let source = "**A😀**\n\n| x | y |\n|---|---|\n| a | b |\n\nlast"
        let pair = try await render(source, width: 120, mode: .static)
        let model = pair.snapshot.displayModel
        #expect(pair.snapshot.attributedString.string == "A😀\n\u{00A0}\nlast")
        #expect(pair.snapshot.blockStarts == [0, 4, 6])
        let copied = try markdownSourceForRenderedSelection(renderedRange: NSRange(location: 1, length: 4), renderedPlainText: pair.snapshot.attributedString.string, blockStarts: pair.snapshot.blockStarts, parsedBlocks: #require(model.preparedBlocks), renderedLength: pair.snapshot.attributedString.length, originalSource: #require(model.source))
        #expect(copied == "**A😀**\n\n| x | y |\n|---|---|\n| a | b |")
        let configuration = RenderStyle.default.snapshot(generation: 0)
        let document = MarkdownDocument(parsedBlocks: [.init(block: .paragraph([.text("A😀")])), .init(block: .paragraph([.text("last")]))])
        let input = RenderInput(document: document, source: nil, availableWidth: 120, configuration: configuration, placeholderMode: .static)
        let prepared = try RenderPreparer(configuration: configuration).prepare(input)
        let snapshot = RenderMaterializer(configuration: configuration).materialize(prepared, resources: .init(values: [:]))
        #expect(snapshot.blockStarts == [0, 4])
        #expect(markdownSourceForRenderedSelection(renderedRange: NSRange(location: 1, length: 2), renderedPlainText: snapshot.attributedString.string, blockStarts: snapshot.blockStarts, parsedBlocks: document.parsedBlocks, renderedLength: snapshot.attributedString.length, originalSource: "") == "😀")
    }

    /// Task 9 replaced the all-or-nothing fallback this used to pin: a block the
    /// math transform rebuilt carries no source range, but its bytes still lie
    /// between the ranges of the blocks around it, so they are recoverable.
    @Test
    func mathBackfillWithoutSourceRangesRecoversBytesBetweenNeighbouringRanges() async throws {
        let source = "**A😀**\n\n$$\nx\n$$\n\nlast"
        let pair = try await render(source, width: 120, mode: .static)
        let blocks = try #require(pair.snapshot.displayModel.preparedBlocks)
        #expect(blocks[1].sourceRange == nil)
        #expect(pair.snapshot.blockStarts == [0, 4, 6])
        let text = pair.snapshot.attributedString
        #expect(markdownSourceForRenderedSelection(renderedRange: NSRange(location: 1, length: 4), renderedPlainText: text.string, blockStarts: [0, 4, 6], parsedBlocks: blocks, renderedLength: text.length, originalSource: source) == "**A😀**\n\n$$\nx\n$$")
    }

    @Test
    func customFontsColorsAndParagraphTokensRoundTrip() async throws {
        var style = RenderStyle.default
        style.bodyFont = .systemFont(ofSize: 19, weight: .medium)
        style.codeFont = .monospacedSystemFont(ofSize: 17, weight: .bold)
        style.h1Font = .systemFont(ofSize: 35, weight: .heavy)
        style.h2Font = .systemFont(ofSize: 29, weight: .light)
        style.h3Font = .systemFont(ofSize: 25, weight: .medium)
        style.h4Font = .systemFont(ofSize: 23, weight: .bold)
        style.h5Font = .systemFont(ofSize: 21, weight: .regular)
        style.h6Font = .systemFont(ofSize: 20, weight: .semibold)
        style.textColor = .red
        style.secondaryTextColor = .green
        style.codeTextColor = .blue
        style.codeBackgroundColor = .yellow
        style.inlineCodeTextColor = .magenta
        style.inlineCodeBgColor = .cyan
        style.linkColor = .brown
        style.quoteColor = .orange
        style.quoteBarColor = .purple
        style.headingBorderColor = .gray
        style.mathTokenColor = .white
        style.mathColorOverride = .black
        style.paragraphSpacing = 21
        style.quoteIndent = 31
        let source = "# One\n\n## Two\n\n### Three\n\n#### Four\n\n##### Five\n\n###### Six\n\nbody *italic* **bold** [link](https://example.com) `inline` $x$\n\n> quote\n\n```plain\ncode\n```"
        let document = MarkdownDocument(parsing: source)
        let configuration = style.snapshot(generation: 1)
        let input = RenderInput(document: document, source: source, availableWidth: 640, configuration: configuration, placeholderMode: .streaming)
        let materializer = RenderMaterializer(configuration: configuration)
        let model = try await RenderPreparer(configuration: configuration).prepare(input).preparingSyntax()
        let snapshot = materializer.materialize(model, resources: .init(values: [:]))
        #expect(snapshot.attributedString.string == "One\nTwo\nThree\nFour\nFive\nSix\nbody italic bold link inline x\nquote\ncode")
        try self.assertParity(Pair(snapshot: snapshot), width: 640)
        let restored = materializer.resolvedStyle().snapshot(generation: 1)
        #expect(restored.colors == configuration.colors)
        #expect(restored.typography.pointSizes == configuration.typography.pointSizes)
        #expect(materializer.resolvedStyle().bodyFont.isEqual(style.bodyFont))
        #expect(materializer.resolvedStyle().h3Font.isEqual(style.h3Font))
        #expect(restored.spacing == configuration.spacing)
    }

    @Test
    func resolvedImageMathSVGKeepGeometryScaleBaselineAndOwners() async throws {
        let source = "![alt](image.png) $x$\n\n```svg\n<svg viewBox=\"0 0 120 60\"/>\n```"
        var style = RenderStyle.default
        style.bodyFont = .systemFont(ofSize: 16)
        style.mathScale = 1.5
        let configuration = style.snapshot(generation: 8)
        let document = MarkdownDocument(parsing: source)
        let input = RenderInput(document: document, source: source, availableWidth: 120, configuration: configuration, placeholderMode: .static)
        let model = try await RenderPreparer(configuration: configuration).prepare(input).preparingSyntax()
        let materializer = RenderMaterializer(configuration: configuration)
        func image(width: Int, height: Int, scale: Double = 1) throws -> PlatformImage {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let backing = try ImmutableCGImageBacking(frames: [#require(context.makeImage())])
            return try #require(materializer.platformImage(from: backing, scale: scale))
        }
        let photo = try image(width: 400, height: 200, scale: 2)
        let math = try image(width: 30, height: 10)
        let svg = try image(width: 120, height: 60)
        weak var observed: TestResourceOwner?
        var snapshot: RenderSnapshot?
        do {
            let owner = TestResourceOwner(retaining: NSObject())
            observed = owner
            var values: [ResourceID: ResolvedPlatformResource] = [:]
            for resource in model.resources {
                switch resource {
                case .image(let id, _, _): values[id] = .image(photo, owner: owner)
                case .math(let id, _, _): values[id] = .math(owner: RenderedResourceRecord(image: math, baselineOffset: -3).acquireLease())
                case .svg(let id, _): values[id] = .svg(owner: RenderedResourceRecord(image: svg, baselineOffset: 0).acquireLease())
                }
            }
            snapshot = materializer.materialize(model, resources: .init(values: values))
        }
        #expect(observed != nil)
        do {
            let value = try #require(snapshot)
            #expect(value.attributedString.string == "\u{FFFC} \u{FFFC}\n\u{FFFC}")
            try self.assertParity(Pair(snapshot: value), width: 120)
            var bounds: [CGRect] = []
            value.attributedString.enumerateAttribute(.attachment, in: NSRange(location: 0, length: value.attributedString.length)) { attachment, _, _ in
                if let attachment = attachment as? NSTextAttachment { bounds.append(attachment.bounds) }
            }
            #expect(bounds == [CGRect(x: 0, y: -4, width: 120, height: 60), CGRect(x: 0, y: -3, width: 30, height: 10), CGRect(x: 0, y: 0, width: 120, height: 60)])
        }
        snapshot = nil
        #expect(observed == nil)
    }

    private func render(_ source: String, width: Double, mode: PlaceholderMode = .streaming) async throws -> Pair {
        let document = MarkdownDocument(parsing: source)
        var style = RenderStyle.default
        style.bodyFont = .systemFont(ofSize: 16)
        let configuration = style.snapshot(generation: 1)
        let input = RenderInput(document: document, source: source, availableWidth: width, configuration: configuration, placeholderMode: mode)
        let model = try await RenderPreparer(configuration: configuration).prepare(input).preparingSyntax()
        return Pair(snapshot: RenderMaterializer(configuration: configuration).materialize(model, resources: .init(values: [:])))
    }

    private func assertParity(_ pair: Pair, width: Double) throws {
        try self.assertGolden(pair.snapshot.attributedString, model: pair.snapshot.displayModel, width: width)
    }

    private func assertGolden(_ text: NSAttributedString, model: RenderDisplayModel, width: Double) throws {
        let identity = "\(model.source ?? "")|\(width)|\(model.placeholderMode)"
        let name = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        #if canImport(UIKit)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "RenderGolden/\(platform)"))
        let expected = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(expected["base"] as? String == "96c6bad422bb38f989f7595c4e2e3574ac50761d")
        #expect(expected["identity"] as? String == identity)
        #expect(expected["string"] as? String == text.string)
        #expect(expected["attributes"] as? [[String: String]] == canonicalAttributes(text))
        let expectedFrames = try #require(expected["frames"] as? [[Double]])
        let actualFrames = self.layout(text, width: width).map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
        #expect(actualFrames.count == expectedFrames.count)
        for (actual, expected) in zip(actualFrames, expectedFrames) {
            for (actualValue, expectedValue) in zip(actual, expected) {
                #expect(abs(actualValue - expectedValue) < 0.000001)
            }
        }
    }

    /// Replace only platform attachment identity; retain image point size and bounds.
    private func normalized(_ string: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: string)
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, range, _ in
            for (key, value) in attributes {
                guard let color = value as? PlatformColor else { continue }
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                #if canImport(UIKit)
                color.resolvedColor(with: .current).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                #else
                color.usingColorSpace(.sRGB)!.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                #endif
                result.addAttribute(key, value: [red, green, blue, alpha].map { String(format: "%.6f", Double($0)) }.joined(separator: ","), range: range)
            }
        }
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment {
                result.removeAttribute(.attachment, range: range)
                result.addAttribute(NSAttributedString.Key("parity.attachment"), value: "\(attachment.bounds)|\(String(describing: attachment.image?.size))", range: range)
            }
        }
        return result
    }

    private func layout(_ string: NSAttributedString, width: Double) -> [CGRect] {
        let storage = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        storage.addTextLayoutManager(manager)
        storage.attributedString = string
        manager.ensureLayout(for: manager.documentRange)
        var frames = [manager.usageBoundsForTextContainer]
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            frames.append(fragment.layoutFragmentFrame)
            frames += fragment.textLineFragments.map(\.typographicBounds)
            return true
        }
        return frames
    }
}

/// Copy metadata is not rendering: it changes no glyph, and leaving it in would
/// also split runs at boundaries the golden fixtures never had. Stripped before
/// comparison; `MarkdownCopyTests` is what pins it.
func strippingCopyMetadata(_ text: NSAttributedString) -> NSAttributedString {
    let stripped = NSMutableAttributedString(attributedString: text)
    let whole = NSRange(location: 0, length: stripped.length)
    for key in [NSAttributedString.Key.markdownCopyText, .markdownCopySource, .markdownCopySkip] {
        stripped.removeAttribute(key, range: whole)
    }
    return stripped
}

@MainActor
func canonicalAttributes(_ text: NSAttributedString) -> [[String: String]] {
    func number(_ value: CGFloat) -> String {
        String(format: "%.6f", Double(value))
    }
    var rows: [[String: String]] = []
    strippingCopyMetadata(text).enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
        var row = ["range": "\(range.location):\(range.length)"]
        for (key, value) in attributes {
            let encoded: String
            if let font = value as? PlatformFont {
                #if canImport(UIKit)
                let fontName = font.fontDescriptor.postscriptName
                #else
                let fontName = font.fontDescriptor.postscriptName ?? font.fontName
                #endif
                encoded = "\(fontName)|\(number(font.pointSize))"
            } else if let color = value as? PlatformColor {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                #if canImport(UIKit)
                color.resolvedColor(with: .current).getRed(&r, green: &g, blue: &b, alpha: &a)
                #else
                color.usingColorSpace(.sRGB)!.getRed(&r, green: &g, blue: &b, alpha: &a)
                #endif
                encoded = [r, g, b, a].map(number).joined(separator: ",")
            } else if let paragraph = value as? NSParagraphStyle {
                encoded = [paragraph.lineSpacing, paragraph.paragraphSpacing, paragraph.paragraphSpacingBefore,
                           paragraph.headIndent, paragraph.firstLineHeadIndent, paragraph.tailIndent,
                           paragraph.minimumLineHeight, paragraph.maximumLineHeight, paragraph.defaultTabInterval]
                    .map(number).joined(separator: ",") + "|\(paragraph.alignment.rawValue)|" +
                    paragraph.tabStops.map { "\($0.alignment.rawValue):\(number($0.location))" }.joined(separator: ",")
            } else if let attachment = value as? NSTextAttachment {
                let size = attachment.image?.size ?? .zero
                encoded = [attachment.bounds.minX, attachment.bounds.minY, attachment.bounds.width, attachment.bounds.height, size.width, size.height].map(number).joined(separator: ",")
            } else if let values = value as? [CGFloat] {
                encoded = values.map(number).joined(separator: ",")
            } else if let url = value as? URL { encoded = url.absoluteString }
            else { encoded = String(describing: value) }
            row[key.rawValue] = encoded
        }
        rows.append(row)
    }
    return rows
}
