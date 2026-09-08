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

    @Test func renderedCopyOfAnUnresolvedImageKeepsThePlaceholderTheReaderSees() async throws {
        let view = await self.view("![a cat](https://e.com/c.png)")
        defer { view.dismantleRenderSession() }
        self.selectAll(view)
        let result = try #require(view.renderedSelectionResult())
        #expect(result.text.contains("a cat"))
        #expect(!result.text.contains("\u{FFFC}"))
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
