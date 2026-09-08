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

/// The platform half of Task 10: semantic leaves become real accessibility
/// elements with real layout frames, and survive streaming without moving focus.
@MainActor
@Suite(.serialized)
struct MarkdownAccessibilityPlatformTests {
    private func view(_ markdown: String, width: Double = 360) async -> MarkdownLabelView {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: width, height: 4000))
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #else
        view.layoutSubtreeIfNeeded()
        #endif
        view.setMarkdown(markdown)
        _ = await eventually { view.currentSnapshot != nil }
        return view
    }

    private func elements(_ view: MarkdownLabelView) -> [MarkdownAccessibilityElement] {
        view.markdownAccessibilityElements
    }

    @Test func theViewExposesOneElementPerSemanticLeafInReadingOrder() async {
        let view = await self.view("# Title\n\nalpha [one](https://a.test) beta")
        defer { view.dismantleRenderSession() }
        #expect(self.elements(view).map(\.label) == ["Title", "alpha ", "one", " beta"])
    }

    /// A container that also spoke would make a reader hear the paragraph and
    /// then each of its parts.
    @Test func theViewItselfIsNotAnAccessibilityElement() async {
        let view = await self.view("# Title\n\nalpha [one](https://a.test) beta")
        defer { view.dismantleRenderSession() }
        #if canImport(UIKit)
        #expect(!view.isAccessibilityElement)
        #expect((view.accessibilityElements?.count ?? 0) == 4)
        #else
        #expect(view.accessibilityChildren()?.count == 4)
        #endif
    }

    /// Frames come from TextKit layout, not a guess: an element a reader cannot
    /// point at is not usable, and two leaves must not share one rect.
    @Test func everyElementHasItsOwnRealLayoutFrame() async {
        let view = await self.view("# Title\n\nalpha [one](https://a.test) beta")
        defer { view.dismantleRenderSession() }
        let frames = self.elements(view).map(\.frame)
        #expect(frames.count == 4)
        for frame in frames {
            #expect(frame.width > 0 && frame.height > 0, "degenerate frame: \(frame)")
            #expect(view.bounds.intersects(frame), "frame outside the view: \(frame)")
        }
        // The heading is its own line above the paragraph.
        #expect(frames[0].maxY <= frames[1].minY + 1)
        // The link sits to the right of the text before it, on the same line.
        #expect(frames[2].minX > frames[1].minX)
        #expect(frames[3].minX > frames[2].minX)
    }

    @Test func aLinkElementActivatesThroughThePolicy() async throws {
        let handler = RecordingLinkHandler()
        let view = await self.view("alpha [one](https://a.test) beta")
        defer { view.dismantleRenderSession() }
        view.linkConfiguration = .derived(policy: AllowEverythingPolicy(), handler: handler)
        let link = try #require(self.elements(view).first { $0.label == "one" })
        #expect(link.activate())
        #expect(await eventually { handler.opened.map(\.absoluteString) == ["https://a.test"] })
        #expect(self.elements(view).first { $0.label == "alpha " }?.activate() == false)
    }

    /// The visual overlay for a wide table would otherwise expose every cell a
    /// second time.
    @Test func aTableIsExposedOnceWithCellCoordinates() async {
        let view = await self.view("| Name | Age |\n|---|---|\n| Ada | 36 |", width: 90)
        defer { view.dismantleRenderSession() }
        let elements = self.elements(view)
        #expect(elements.map(\.label) == ["Name", "Age", "Ada", "36"], "duplicated table exposure")
        #expect(elements.last?.detail == .cell(row: 1, column: 1, columnHeader: "Age"))
    }

    /// Appending must reuse the platform object for a surviving leaf, or focus
    /// leaves the element the reader was on with every streamed chunk.
    @Test func appendingReusesThePlatformObjectsOfSurvivingLeaves() async throws {
        let view = await self.view("# Title\n\nalpha beta")
        defer { view.dismantleRenderSession() }
        let heading = try #require(self.elements(view).first)
        #expect(heading.label == "Title")
        view.appendMarkdown(" and more text")
        #expect(await eventually { self.elements(view).last?.label == "alpha beta and more text" })
        #expect(self.elements(view).first === heading, "the heading's element was rebuilt, so focus would jump")
    }

    /// A leaf that disappears must not leave a stale object behind.
    @Test func replacingTheDocumentDropsTheOldElements() async throws {
        let view = await self.view("# Title\n\nalpha")
        defer { view.dismantleRenderSession() }
        let before = try #require(self.elements(view).first)
        view.setMarkdown("completely different")
        #expect(await eventually { self.elements(view).map(\.label) == ["completely different"] })
        #expect(self.elements(view).first !== before)
    }
}
