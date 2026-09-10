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

/// Task 11's layout contract. Growing the text must not produce a document that
/// collapses, overlaps itself, or loses the horizontal escape hatch for tables.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct AdaptiveLayoutTests {
    /// Every shape whose height comes from a different code path: wrapped body
    /// text, a heading, an indented code block, a quote, a list, a wide table,
    /// and an unresolved math attachment.
    private static let source = """
    # A heading long enough that it has to wrap at a readable measure

    A paragraph long enough to wrap several times at the widths this suite uses, so
    that line fragment geometry is exercised rather than a single short line.

    > A quoted paragraph that also wraps, because the quote indent scales too.

    - first item with enough text to wrap onto a second line
    - second item

    ```swift
    let indented = "        preserved"
    ```

    | Column one heading | Column two heading | Column three heading | Column four |
    | --- | --- | --- | --- |
    | a value | another value | a third value | a fourth value |
    """

    /// Ordered items only: the wide table in `source` is laid out at its natural
    /// width on purpose, so it cannot share a horizontal-containment assertion.
    /// It starts at 9 so the run crosses into two-digit markers, which are wide
    /// enough to pass the item tab stop at an accessibility size.
    private static let orderedListSource = """
    9. A ninth item with enough text that it has to wrap onto a further line here
    10. tenth
    11. eleventh
    """

    private static let width: CGFloat = 320

    /// The math block is appended rather than parsed, and it is display math on
    /// purpose: only display math reserves a static placeholder attachment, and
    /// that attachment's bounds are the ones taken from the body metric.
    private static func blocks() -> [BlockNode] {
        MarkdownDocument(parsing: self.source).blocks + [.mathBlock(latex: "x^2 + y^2 = z^2")]
    }

    /// Lays the produced string out in the same TextKit 2 configuration the label
    /// view uses, and returns each line fragment rect in document order.
    private static func fragments(_ string: NSAttributedString, width: CGFloat) -> [CGRect] {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: 0))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.attributedString = string
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var rects: [CGRect] = []
        layoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments {
                rects.append(line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY))
            }
            return true
        }
        return rects
    }

    /// The text TextKit actually placed into line fragments, which is not the
    /// string that went in: an unplaceable run leaves no fragment behind.
    private static func laidOutText(_ string: NSAttributedString, width: CGFloat) -> String {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: 0))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.attributedString = string
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var placed = ""
        layoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments {
                placed += line.attributedString.attributedSubstring(from: line.characterRange).string
            }
            return true
        }
        return placed
    }

    @Test(arguments: [MarkdownContentSizeCategory.extraSmall, .large, .accessibilityLarge, .accessibilityExtraExtraExtraLarge])
    func everyLineHasPositiveHeightAndNoneOverlap(category: MarkdownContentSizeCategory) {
        var fixture = MaterializationFixture(availableWidth: Self.width, placeholderMode: .static)
        fixture.contentSizeCategory = category
        let rects = Self.fragments(fixture.render(Self.blocks()), width: Self.width)
        #expect(rects.count > 10)
        for rect in rects {
            #expect(rect.height > 0)
            #expect(rect.width >= 0)
            #expect(rect.minY.isFinite && rect.height.isFinite)
        }
        // Fragments arrive in document order, so a later line starting above the
        // bottom of the previous one is text drawn on top of text.
        for (previous, next) in zip(rects, rects.dropFirst()) {
            #expect(next.minY >= previous.maxY - 0.5, "overlap at y=\(next.minY) after \(previous.maxY) in \(category)")
        }
    }

    @Test func theWholeDocumentGrowsWithTheCategory() {
        func height(_ category: MarkdownContentSizeCategory) -> CGFloat {
            var fixture = MaterializationFixture(availableWidth: Self.width, placeholderMode: .static)
            fixture.contentSizeCategory = category
            return Self.fragments(fixture.render(Self.blocks()), width: Self.width).map(\.maxY).max() ?? 0
        }
        let large = height(.large)
        #expect(large > 0)
        #expect(height(.accessibilityLarge) > large)
        #expect(height(.accessibilityExtraExtraExtraLarge) > height(.accessibilityLarge))
        #expect(height(.extraSmall) < large)
        // Chrome alone moves this document by 1.07x; the text moves it by 5.27x.
        // The threshold is what separates "the type scaled" from "only the margins did".
        #expect(height(.accessibilityExtraExtraExtraLarge) > large * 2)
    }

    /// An ordered marker is as wide as the type it is set in, so at accessibility
    /// sizes `1.` is wider than a fixed 24 pt tab stop. A run that overflows its
    /// paragraph's last tab stop is not wrapped — TextKit drops the rest of the
    /// line, and the item keeps its height while losing its text.
    @Test(arguments: [MarkdownContentSizeCategory.large, .accessibilityLarge, .accessibilityExtraExtraExtraLarge])
    func anOrderedItemKeepsItsTextAtEveryCategory(category: MarkdownContentSizeCategory) {
        var fixture = MaterializationFixture(availableWidth: Self.width, placeholderMode: .static)
        fixture.contentSizeCategory = category
        let string = fixture.render(MarkdownDocument(parsing: Self.orderedListSource).blocks)
        let placed = Self.laidOutText(string, width: Self.width)
        #expect(placed.contains("further line here"), "the ninth item lost its tail at \(category): \(placed.debugDescription)")
        #expect(placed.contains("tenth"), "a two-digit item lost its text at \(category): \(placed.debugDescription)")
        #expect(placed.contains("eleventh"))
        for rect in Self.fragments(string, width: Self.width) {
            #expect(rect.minX < Self.width, "a line begins past the container at \(category): \(rect)")
            #expect(rect.maxX <= Self.width + 0.5, "a line runs past the container at \(category): \(rect)")
        }
    }

    /// An item's first line starts at its tab stop and its wrapped lines at its
    /// head indent, so the two have to be the same number. Inside a quote the
    /// indents are shifted and the stop has to shift with them — and now that the
    /// stop is also the paragraph's tab interval, a stop left behind puts a wide
    /// marker's text past the text it introduces rather than in line with it.
    @Test(arguments: [MarkdownContentSizeCategory.large, .accessibilityExtraExtraExtraLarge])
    func aQuotedListsTabStopFollowsItsIndent(category: MarkdownContentSizeCategory) {
        let source = Self.orderedListSource.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")
        var fixture = MaterializationFixture(availableWidth: Self.width, placeholderMode: .static)
        fixture.contentSizeCategory = category
        let string = fixture.render(MarkdownDocument(parsing: source).blocks)
        let placed = Self.laidOutText(string, width: Self.width)
        #expect(placed.contains("further line here"), "a quoted item lost its tail at \(category): \(placed.debugDescription)")
        #expect(placed.contains("tenth"))
        var stops: [(CGFloat, CGFloat)] = []
        string.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            guard let paragraph = value as? NSParagraphStyle, let stop = paragraph.tabStops.first,
                  paragraph.tabStops.count == 1 else { return }
            stops.append((stop.location, paragraph.headIndent))
        }
        #expect(!stops.isEmpty)
        for (location, head) in stops {
            #expect(location == head, "a quoted item tabs to \(location) but wraps to \(head) at \(category)")
        }
    }

    /// A table that already overflows must keep overflowing rather than being
    /// squeezed into the main flow, or the horizontal scroll overlay disappears
    /// exactly when the reader most needs it.
    @Test(arguments: [MarkdownContentSizeCategory.large, .accessibilityExtraExtraExtraLarge])
    func wideTablesKeepTheirHorizontalOverflow(category: MarkdownContentSizeCategory) throws {
        var fixture = MaterializationFixture(availableWidth: Self.width, placeholderMode: .static)
        fixture.contentSizeCategory = category
        let snapshot = fixture.snapshot(Self.blocks())
        let overlay = try #require(snapshot.tableOverlays.values.first)
        #expect(overlay.naturalWidth > Self.width)
        #expect(overlay.height > 0)
    }

    @Test func theTableOverflowWidensWithTheCategory() {
        func natural(_ category: MarkdownContentSizeCategory) -> CGFloat {
            var fixture = MaterializationFixture(availableWidth: Self.width, placeholderMode: .static)
            fixture.contentSizeCategory = category
            return fixture.snapshot(Self.blocks()).tableOverlays.values.first?.naturalWidth ?? 0
        }
        #expect(natural(.accessibilityExtraExtraExtraLarge) > natural(.large))
    }

    /// The unresolved-math placeholder is sized from the body metric, so it has to
    /// follow the reader's setting rather than stay at a fixed 16pt box.
    @Test func attachmentPlaceholdersScaleWithTheCategory() {
        func attachmentHeights(_ category: MarkdownContentSizeCategory) -> [CGFloat] {
            var fixture = MaterializationFixture(availableWidth: Self.width, placeholderMode: .static)
            fixture.contentSizeCategory = category
            let string = fixture.render(Self.blocks())
            var heights: [CGFloat] = []
            string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, _, _ in
                if let attachment = value as? NSTextAttachment { heights.append(attachment.bounds.height) }
            }
            return heights
        }
        let large = attachmentHeights(.large)
        let huge = attachmentHeights(.accessibilityExtraExtraExtraLarge)
        #expect(!large.isEmpty)
        #expect(large.count == huge.count)
        for (small, big) in zip(large, huge) {
            #expect(big > small)
        }
    }

    /// Step 3's contract: the trait change has to arrive as one new configuration
    /// generation on the live session, not as a mutation of the host's style.
    @Test func aCategoryChangeReplacesTheConfigurationExactlyOnce() async throws {
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: Self.width, height: 480))
        defer { view.dismantleRenderSession() }
        let style = view.renderStyle
        // The device's own text size seeds the view, so the starting point is
        // pinned here rather than inherited from whatever the simulator was left at.
        view.contentSizeCategory = .large
        view.blocks = Self.blocks()
        await view.settled { view.currentSnapshot != nil }
        let before = try #require(view.currentCommitToken)
        let bodyBefore = try #require(view.currentSnapshot?.attributedString.bodyPointSize)

        view.contentSizeCategory = .accessibilityExtraExtraExtraLarge
        await view.settled { view.currentCommitToken?.configurationGeneration == before.configurationGeneration + 1 }
        #expect(try #require(view.currentSnapshot?.attributedString.bodyPointSize) > bodyBefore)
        #expect(view.renderStyle.isSemanticallyEqual(to: style))

        // Re-assigning the same category is not a change and must not spend a generation.
        let after = try #require(view.currentCommitToken)
        view.contentSizeCategory = .accessibilityExtraExtraExtraLarge
        #expect(view.currentCommitToken?.configurationGeneration == after.configurationGeneration)
    }

    #if canImport(UIKit)
    /// The system trait, not just a direct assignment, has to reach the session —
    /// that is the path a reader's Settings change actually travels.
    @Test func theSystemTraitDrivesTheCategory() async throws {
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: Self.width, height: 480))
        defer { view.dismantleRenderSession() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: 480))
        window.traitOverrides.preferredContentSizeCategory = .large
        window.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; view.removeFromSuperview() }
        view.layoutIfNeeded()
        view.blocks = Self.blocks()
        await view.settled { view.currentSnapshot != nil }
        try #require(view.contentSizeCategory == .large)
        let before = try #require(view.currentCommitToken)
        let bodyBefore = try #require(view.currentSnapshot?.attributedString.bodyPointSize)

        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        view.layoutIfNeeded()
        // UIKit delivers the trait change on a later turn, not inside the assignment.
        await view.settled { view.contentSizeCategory == .accessibilityExtraExtraExtraLarge }
        await view.settled { view.currentCommitToken?.configurationGeneration == before.configurationGeneration + 1 }
        #expect(try #require(view.currentSnapshot?.attributedString.bodyPointSize) > bodyBefore)
    }
    #endif
}

extension NSAttributedString {
    /// Largest font size in the string, which for these fixtures is the heading —
    /// enough to tell a scaled render from an unscaled one.
    fileprivate var bodyPointSize: CGFloat? {
        var largest: CGFloat?
        self.enumerateAttribute(.font, in: NSRange(location: 0, length: self.length)) { value, _, _ in
            guard let font = value as? PlatformFont else { return }
            largest = max(largest ?? 0, font.pointSize)
        }
        return largest
    }
}
