import Foundation
import MarkdownCore
import MarkdownKit
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import SwiftUI
import Testing

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Task 9's copy matrix. Normal Copy must serialize exactly what is selected, as
/// a reader sees it; explicit source copy must return Markdown syntax and say
/// how faithful it was.
@MainActor
@Suite(.serialized)
struct MarkdownCopyTests {
    private func view(_ markdown: String, width: Double = 360) async -> MarkdownLabelView {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: width, height: 10000))
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #else
        view.layoutSubtreeIfNeeded()
        #endif
        view.setMarkdown(markdown)
        _ = await eventually { view.currentSnapshot != nil }
        return view
    }

    private func selectAll(_ view: MarkdownLabelView) {
        view._selectEntireDocumentForTesting()
    }

    // MARK: Rendered copy

    @Test func renderedCopyOfAResolvedImageUsesItsAltTextNotAnObjectReplacement() async throws {
        let view = await self.view("![a cat](https://e.com/c.png)")
        defer { view.dismantleRenderSession() }
        self.selectAll(view)
        let result = try #require(view.renderedSelectionResult())
        #expect(!result.text.contains("\u{FFFC}"))
        #expect(result.text.contains("a cat"))
        #expect(result.granularity == .exact)
    }

    /// The clipboard must not depend on whether the image happened to have
    /// loaded, so the placeholder copies as its alt text too — not as the
    /// "🖼 " prefix the reader sees while it is still loading.
    @Test func anUnresolvedImageCopiesTheSameTextAsAResolvedOne() async throws {
        let view = await self.view("![a cat](https://e.com/c.png)")
        defer { view.dismantleRenderSession() }
        let rendered = try #require(view.currentSnapshot).attributedString
        #expect(rendered.string.contains("🖼"), "fixture resolved, so it no longer tests the placeholder")
        self.selectAll(view)
        let result = try #require(view.renderedSelectionResult())
        #expect(result.text == "a cat")
    }

    @Test func renderedCopyOfInlineAndDisplayMathCarriesTheLatexAndNoPlaceholder() async throws {
        let view = await self.view("inline $x^2$ end\n\n$$\\sum_i i$$")
        defer { view.dismantleRenderSession() }
        self.selectAll(view)
        let result = try #require(view.renderedSelectionResult())
        #expect(result.text.contains("x^2"))
        #expect(result.text.contains("\\sum_i i"))
        #expect(!result.text.contains("\u{FFFC}"))
    }

    @Test func renderedCopyOfATableIsTabSeparatedCellsAndNewlineSeparatedRows() async throws {
        let view = await self.view("| a | b |\n|---|---|\n| 1 | 2 |")
        defer { view.dismantleRenderSession() }
        self.selectAll(view)
        let result = try #require(view.renderedSelectionResult())
        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.contains("a\tb"), "expected a TSV header row, got \(lines)")
        #expect(lines.contains("1\t2"), "expected a TSV body row, got \(lines)")
        #expect(!result.text.contains("\u{FFFC}"))
    }

    @Test func renderedCopyOfAPartialRangeStopsAtTheSelectionBoundary() async throws {
        let view = await self.view("alpha beta gamma")
        defer { view.dismantleRenderSession() }
        let result = try #require(view.renderedSelectionResult(forRenderedRange: NSRange(location: 6, length: 4)))
        #expect(result.text == "beta")
        #expect(result.granularity == .exact)
    }

    // MARK: Source copy

    @Test func sourceCopyOfAWholeBlockIsExactMarkdownSyntax() async throws {
        let view = await self.view("# Title\n\nbody text")
        defer { view.dismantleRenderSession() }
        let heading = try #require(view.currentSnapshot).blockStarts.first ?? 0
        let result = try #require(view.markdownSourceSelectionResult(
            forRenderedRange: NSRange(location: heading, length: "Title".count)
        ))
        #expect(result.text == "# Title")
        #expect(result.granularity == .exact)
    }

    @Test func sourceCopyOfAPartialBlockReportsThatItExpanded() async throws {
        let view = await self.view("# Title\n\nalpha beta gamma")
        defer { view.dismantleRenderSession() }
        let starts = try #require(view.currentSnapshot).blockStarts
        let bodyStart = try #require(starts.count > 1 ? starts[1] : nil)
        let result = try #require(view.markdownSourceSelectionResult(
            forRenderedRange: NSRange(location: bodyStart + 6, length: 4)
        ))
        #expect(result.text == "alpha beta gamma")
        #expect(result.granularity == .blockExpanded, "a partial selection must not claim to be exact")
    }

    @Test func sourceCopyKeepsMarkdownSyntaxForMathImagesAndTables() async throws {
        let view = await self.view("$$\\sum_i i$$\n\n![alt](https://e.com/p.png)\n\n| a | b |\n|---|---|\n| 1 | 2 |")
        defer { view.dismantleRenderSession() }
        self.selectAll(view)
        let result = try #require(view.markdownSourceSelectionResult())
        #expect(result.text.contains("$$\\sum_i i$$"))
        #expect(result.text.contains("![alt](https://e.com/p.png)"))
        #expect(result.text.contains("| a | b |"))
        #expect(!result.text.contains("\u{FFFC}"))
    }

    @Test func programmaticBlocksWithoutASourceReportRenderedFallback() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 360, height: 10000))
        defer { view.dismantleRenderSession() }
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #else
        view.layoutSubtreeIfNeeded()
        #endif
        view.blocks = MarkdownDocument(parsing: "programmatic text").blocks
        _ = await eventually { view.currentSnapshot != nil }
        self.selectAll(view)
        let result = try #require(view.markdownSourceSelectionResult())
        #expect(result.granularity == .renderedFallback)
        #expect(result.text.contains("programmatic text"))
    }

    /// Bracketing recovers bytes from the gap between neighbouring source
    /// ranges. It is only sound when the source-less run *starts* where the
    /// selection starts: a run reaching further back would hand over the bytes of
    /// blocks the reader never selected, and claim they were exact.
    @Test func aSourcelessRunReachingPastTheSelectionIsNotPassedOffAsExactSource() async throws {
        let view = await self.view("alpha $x$ one\n\nbeta $y$ two")
        defer { view.dismantleRenderSession() }
        let starts = try #require(view.currentSnapshot).blockStarts
        #expect(starts.count == 2)
        let firstBlock = NSRange(location: starts[0], length: starts[1] - 1 - starts[0])
        let result = try #require(view.markdownSourceSelectionResult(forRenderedRange: firstBlock))
        #expect(!result.text.contains("beta"), "copied a block the selection never covered: \(result.text)")
        #expect(result.granularity != .exact)
    }

    /// Whole-document selections may bracket freely, because there is nothing
    /// outside the selection for the bracket to reach into.
    @Test func aWholeDocumentOfSourcelessBlocksStillRecoversItsBytes() async throws {
        let view = await self.view("alpha $x$ one\n\nbeta $y$ two")
        defer { view.dismantleRenderSession() }
        self.selectAll(view)
        let result = try #require(view.markdownSourceSelectionResult())
        #expect(result.text == "alpha $x$ one\n\nbeta $y$ two")
        #expect(result.granularity == .exact)
    }

    /// Leading whitespace is load-bearing: four spaces are the difference between
    /// a code block and a paragraph, so a block's own range is never trimmed.
    @Test func indentationSurvivesWhenAnotherBlockInTheSelectionHasNoSourceRange() async throws {
        let source = "para\n\n    indented code\n    second line\n\n$$\nx\n$$"
        let view = await self.view(source)
        defer { view.dismantleRenderSession() }
        self.selectAll(view)
        let result = try #require(view.markdownSourceSelectionResult())
        #expect(result.text.contains("    indented code"), "lost the code block's indent: \(result.text)")
        #expect(result.granularity == .exact)
    }

    /// Bytes between blocks are copied verbatim rather than re-joined, so a
    /// single-newline separator is not silently turned into a blank line.
    @Test func bytesBetweenBlocksAreCopiedVerbatimNotRejoined() async throws {
        let source = "# H\ntext\n\n$$\nx\n$$"
        let view = await self.view(source)
        defer { view.dismantleRenderSession() }
        self.selectAll(view)
        let result = try #require(view.markdownSourceSelectionResult())
        #expect(result.text == source)
    }

    // MARK: Commands and resources

    /// Pins both the `resources:` wiring and the two `.strings` files: without
    /// them `NSLocalizedString` silently returns the key, and the menu item
    /// reads `markdown.copy.source`.
    @Test func theCommandTitlesComeFromTheResourceBundleNotTheKeys() {
        #expect(MarkdownCopyCommandTitle.markdownSource != "markdown.copy.source")
        #expect(MarkdownCopyCommandTitle.copy != "markdown.copy.rendered")
        #expect(!MarkdownCopyCommandTitle.markdownSource.isEmpty)
    }

    @Test func bothCopyCommandsAreOfferedForASelectionAndNothingElseIs() async throws {
        let view = await self.view("# Title")
        defer { view.dismantleRenderSession() }
        self.selectAll(view)
        #if canImport(UIKit)
        #expect(view.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil))
        #expect(view.canPerformAction(#selector(MarkdownLabelView.copyMarkdownSource(_:)), withSender: nil))
        // The narrow allow-list is what keeps Share / Look Up / Translate off a
        // rendered link; widening it reopens that.
        #expect(!view.canPerformAction(#selector(UIResponder.paste(_:)), withSender: nil))
        #expect(!view.canPerformAction(NSSelectorFromString("_share:"), withSender: nil))
        #else
        let menu = try #require(view.menu(for: NSEvent()))
        let titles = menu.items.map(\.title)
        #expect(titles.contains(MarkdownCopyCommandTitle.copy), "right-click cannot copy rendered text: \(titles)")
        #expect(titles.contains(MarkdownCopyCommandTitle.markdownSource))
        #endif
    }

    /// `renderedCopyText` emits a whole `.markdownCopyText` value for any
    /// sub-range that touches it, which is only correct while every such run is
    /// one character. A longer run would make a partial selection paste the whole
    /// thing and still report `.exact`. The parity goldens strip these keys, so
    /// nothing else would catch it.
    @Test func everyCopyTextRunIsExactlyOneCharacter() async throws {
        let view = await self.view("![alt](https://e.com/p.png)\n\n$$\nx\n$$\n\n| a | b |\n|---|---|\n| 1 | 2 |", width: 120)
        defer { view.dismantleRenderSession() }
        let text = try #require(view.currentSnapshot).attributedString
        var offenders: [NSRange] = []
        text.enumerateAttribute(.markdownCopyText, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil, range.length != 1 { offenders.append(range) }
        }
        #expect(offenders.isEmpty, "multi-character copyText runs break partial selections: \(offenders)")
    }

    /// A table too wide for the view collapses to a single placeholder character,
    /// so that character has to carry the whole table or the copy loses it.
    @Test func anOverflowingTableStillCopiesAsTSV() async throws {
        let view = await self.view("| alpha | beta | gamma |\n|---|---|---|\n| one | two | three |\n\ntail", width: 90)
        defer { view.dismantleRenderSession() }
        let snapshot = try #require(view.currentSnapshot)
        #expect(
            snapshot.attributedString.attribute(.markdownOverflowTablePlaceholder, at: 0, effectiveRange: nil) != nil,
            "fixture no longer overflows, so it stopped testing the placeholder path"
        )
        self.selectAll(view)
        let result = try #require(view.renderedSelectionResult())
        #expect(result.text.contains("alpha\tbeta\tgamma"), "overflow table lost its TSV: \(result.text.debugDescription)")
        #expect(result.text.contains("one\ttwo\tthree"))
        #expect(!result.text.contains("\u{FFFC}"))
    }

    // MARK: SwiftUI proxy

    @Test(arguments: [false, true]) @MainActor
    func theSelectionProxyReachesTheProductionViewAndReportsBothForms(streaming: Bool) async throws {
        let source = "# Title\n\n![alt](https://e.com/p.png)"
        let streamingSource = MarkdownStreamingSource(source)
        var captured: MarkdownSelectionProxy?
        let content = MarkdownSelectionReader { proxy in
            Group {
                if streaming { MarkdownStreamingText(streamingSource) } else { MarkdownText(source) }
            }
            .onAppear { captured = proxy }
        }
        #if canImport(UIKit)
        let host = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        #else
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        host.layoutSubtreeIfNeeded()
        #endif
        let label = try #require(await settleForLabel(in: host))
        #expect(await eventually { label.currentSnapshot != nil })
        let proxy = try #require(captured)
        // Nothing selected yet: both readers report nothing rather than guessing.
        #expect(proxy.renderedSelection == nil)
        #expect(proxy.markdownSourceSelection == nil)

        label._selectEntireDocumentForTesting()
        let rendered = try #require(proxy.renderedSelection)
        #expect(!rendered.text.contains("\u{FFFC}"))
        #expect(rendered.text.contains("Title"))
        #expect(!rendered.text.contains("# Title"))
        let markdown = try #require(proxy.markdownSourceSelection)
        #expect(markdown.text.contains("# Title"))
        #expect(markdown.text.contains("![alt](https://e.com/p.png)"))
        #expect(markdown.granularity == .exact)
        withExtendedLifetime(host) {}
    }

    @Test func normalCopyNoLongerExpandsToTheWholeSourceBlock() async throws {
        let view = await self.view("# Title\n\nalpha beta gamma")
        defer { view.dismantleRenderSession() }
        let starts = try #require(view.currentSnapshot).blockStarts
        let bodyStart = try #require(starts.count > 1 ? starts[1] : nil)
        let result = try #require(view.renderedSelectionResult(
            forRenderedRange: NSRange(location: bodyStart + 6, length: 4)
        ))
        #expect(result.text == "beta", "normal Copy must not expand a partial selection")
        #expect(!result.text.contains("# Title"))
    }
}
