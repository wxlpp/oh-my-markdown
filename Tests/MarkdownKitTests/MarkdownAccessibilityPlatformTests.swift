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
@Suite(.timeLimit(.minutes(5)), .serialized)
struct MarkdownAccessibilityPlatformTests {
    private func view(_ markdown: String, width: Double = 360) async -> MarkdownLabelView {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: width, height: 4000))
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #else
        view.layoutSubtreeIfNeeded()
        #endif
        view.setMarkdown(markdown)
        await view.settled { view.currentSnapshot != nil }
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
        #expect(Set(frames.map(\.debugDescription)).count == frames.count, "two leaves share one rect")
    }

    @Test func aLinkElementActivatesThroughThePolicy() async throws {
        let handler = RecordingLinkHandler()
        let view = await self.view("alpha [one](https://a.test) beta")
        defer { view.dismantleRenderSession() }
        view.linkConfiguration = .derived(policy: AllowEverythingPolicy(), handler: handler)
        let link = try #require(self.elements(view).first { $0.label == "one" })
        #expect(link.activate())
        await handler.events.settled { handler.opened.map(\.absoluteString) == ["https://a.test"] }
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

    /// An empty cell has no text of its own, so it had no tagged run and was
    /// dropped — leaving the row one cell shorter than its header, which is
    /// exactly what a reader counting across a row relies on.
    @Test(arguments: [
        "| Name | Age |\n|---|---|\n| Ada |  |",
        "| Name | Age |\n|---|---|\n|  | 36 |",
        "|  | Age |\n|---|---|\n| Ada | 36 |",
        "| Name | Age |\n|---|---|\n|  |  |",
    ])
    func anEmptyTableCellIsStillExposed(markdown: String) async {
        let view = await self.view(markdown)
        defer { view.dismantleRenderSession() }
        let elements = self.elements(view)
        #expect(elements.count == 4, "row is shorter than its header: \(elements.map(\.label))")
        #expect(elements.allSatisfy { $0.frame.width > 0 })
        #expect(elements.last?.detail == .cell(row: 1, column: 1, columnHeader: elements[1].label))
    }

    /// A nested list item is still a list item. The model says so; if the
    /// container never becomes an element, the reader hears plain text with no
    /// position while its sibling announces "2 of 2".
    @Test func aNestedListItemKeepsItsRoleAndPositionOnThePlatform() async throws {
        let view = await self.view("- a\n  - b\n- c")
        defer { view.dismantleRenderSession() }
        let outer = try #require(self.elements(view).first)
        #expect(outer.label == "a")
        #expect(outer.role == .listItem, "exposed as \(outer.role) with no item semantics")
        #expect(outer.detail == .listItem(position: 1, count: 2, checkbox: nil))
    }

    /// The steady state of a streamed list: the next marker has arrived, its
    /// text has not. An item with nothing readable is not a stop, and publishing
    /// it took another leaf's rect — the frame key carries no role, so a
    /// container's ordinal collides with a leaf's.
    @Test(arguments: ["- a\n\n  b\n-", "- a\n\n  b\n- ", "-\n- a"])
    func anItemWithNothingInItIsNotExposed(markdown: String) async {
        let view = await self.view(markdown)
        defer { view.dismantleRenderSession() }
        let elements = self.elements(view)
        #expect(elements.allSatisfy { !$0.label.isEmpty }, "empty element: \(elements.map(\.label))")
        let frames = elements.map(\.frame)
        #expect(Set(frames.map(\.debugDescription)).count == frames.count, "two elements share a rect: \(frames)")
    }

    /// The nearest enclosing item wins. Taking the ancestor's made an inner
    /// list's only item announce the outer list's position.
    @Test func aNestedItemAnnouncesItsOwnListsPosition() async throws {
        let view = await self.view("- x\n- - a\n\n    b\n- z")
        defer { view.dismantleRenderSession() }
        let inner = try #require(self.elements(view).first { $0.label == "a" })
        #expect(inner.detail == .listItem(position: 1, count: 1, checkbox: nil), "announced \(String(describing: inner.detail))")
    }

    /// A first child that carries its own detail must not swallow the item's
    /// position: a code block in a list still needs "1 of 2".
    @Test func anItemWhoseFirstBlockCarriesDetailKeepsItsPosition() async {
        let view = await self.view("- ```\n  code\n  ```\n\n  b\n- c")
        defer { view.dismantleRenderSession() }
        let spoken = self.elements(view).compactMap(\.spokenValue)
        #expect(spoken.contains { $0.contains("1") && $0.contains("2") }, "item position never spoken: \(spoken)")
    }

    /// The renderer draws `3.` and `4.`, and the marker is not a stop of its
    /// own, so announcing "1 of 2" would be the only number the reader gets and
    /// it would contradict the screen.
    @Test func anOrderedListAnnouncesTheNumbersItDraws() async {
        let view = await self.view("3. a\n4. b")
        defer { view.dismantleRenderSession() }
        let items = self.elements(view).filter { $0.role == .listItem }
        #expect(items.map(\.detail) == [
            .listItem(position: 3, count: 2, checkbox: nil),
            .listItem(position: 4, count: 2, checkbox: nil),
        ])
    }

    /// The tag/tree guard compares the *preparer*'s tags, but frames come from
    /// the *materializer*, which drops a tag for a run of zero length. A leaf can
    /// therefore satisfy the guard and still be unexposed — a class the guard is
    /// structurally unable to see, so it is checked here instead.
    @Test(arguments: [
        "# Title\n\nalpha [one](https://a.test) beta",
        "- a\n\n  b\n- c",
        "| Name | Age |\n|---|---|\n| Ada |  |",
        "> quoted\n>\n> $$\nx\n$$",
        "- [x] done\n- [ ] todo",
        "```swift\nlet a = 1\n```",
    ])
    func everyLeafWithSomethingToSayBecomesAnElement(markdown: String) async throws {
        let view = await self.view(markdown)
        defer { view.dismantleRenderSession() }
        let snapshot = try #require(view.currentSnapshot)
        func leaves(_ node: AccessibilityNode) -> [AccessibilityNode] {
            node.children.isEmpty ? [node] : node.children.flatMap(leaves)
        }
        let speaking = snapshot.displayModel.accessibilityRootsByBlock
            .flatMap { $0.flatMap(leaves) }
            .filter { !($0.label ?? "").isEmpty }
        let exposed = Set(self.elements(view).map(\.id))
        let missing = speaking.filter { !exposed.contains($0.id) }
        #expect(missing.isEmpty, "leaves with a label but no element: \(missing.map { $0.label ?? "" })")
    }

    /// Coordinates and headers that never leave the model are not "correct table
    /// relationships": a reader has to hear them.
    @Test func cellsAndListItemsSpeakTheirRelationships() async throws {
        let table = await self.view("| Name | Age |\n|---|---|\n| Ada | 36 |")
        defer { table.dismantleRenderSession() }
        let cell = try #require(self.elements(table).first { $0.label == "36" })
        let spoken = try #require(cell.spokenValue)
        #expect(spoken.contains("Age"))
        #expect(spoken.contains("2"), "no column position in \(spoken)")

        let list = await self.view("- [x] done\n- [ ] todo")
        defer { list.dismantleRenderSession() }
        let done = try #require(self.elements(list).first { $0.label == "done" })
        #expect(done.spokenValue?.isEmpty == false)
        #expect(done.spokenValue != self.elements(list).first { $0.label == "todo" }?.spokenValue)
    }

    /// The wrappers are what the OS calls; the shared element's `activate()` is
    /// not on that path, so it cannot cover them.
    @Test func theWrapperTheSystemCallsActivatesTheLink() async throws {
        let handler = RecordingLinkHandler()
        let view = await self.view("alpha [one](https://a.test) beta")
        defer { view.dismantleRenderSession() }
        view.linkConfiguration = .derived(policy: AllowEverythingPolicy(), handler: handler)
        #if canImport(UIKit)
        let wrappers = try #require(view.accessibilityElements as? [MarkdownAccessibilityUIElement])
        let link = try #require(wrappers.first { $0.accessibilityLabel == "one" })
        #expect(link.accessibilityActivate())
        #else
        let wrappers = try #require(view.accessibilityChildren() as? [MarkdownAccessibilityNSElement])
        let link = try #require(wrappers.first { $0.accessibilityLabel() == "one" })
        #expect(link.accessibilityPerformPress())
        #endif
        await handler.events.settled { handler.opened.map(\.absoluteString) == ["https://a.test"] }
    }

    /// A heading whose whole content is a link must stay a heading, or it drops
    /// out of heading navigation.
    @Test func aLinkOnlyHeadingIsStillAHeading() async throws {
        let view = await self.view("# [Home](https://a.test)\n\nbody")
        defer { view.dismantleRenderSession() }
        let heading = try #require(self.elements(view).first)
        #expect(heading.label == "Home")
        #expect(heading.role == .heading(level: 1))
        #expect(heading.activation != nil, "the link is no longer activatable")
    }

    /// Rendered HTML is visible text, so a reader must get it too.
    @Test func htmlBlocksAreExposed() async {
        let view = await self.view("<div>visible html</div>\n\nafter")
        defer { view.dismantleRenderSession() }
        #expect(self.elements(view).map(\.label).contains { $0.contains("visible html") })
    }

    /// Appending must reuse the platform object for a surviving leaf, or focus
    /// leaves the element the reader was on with every streamed chunk.
    @Test func appendingReusesThePlatformObjectsOfSurvivingLeaves() async throws {
        let view = await self.view("# Title\n\nalpha beta")
        defer { view.dismantleRenderSession() }
        let heading = try #require(self.elements(view).first)
        #expect(heading.label == "Title")
        view.appendMarkdown(" and more text")
        await view.settled { self.elements(view).last?.label == "alpha beta and more text" }
        #expect(self.elements(view).first === heading, "the heading's element was rebuilt, so focus would jump")
    }

    /// The object the accessibility client holds is the wrapper, not the inner
    /// element, so reusing only the element leaves the requirement unmet — and
    /// the reuse test above cannot see it.
    @Test func appendingReusesThePlatformWrappersTheClientHolds() async throws {
        let view = await self.view("# Title\n\nalpha beta")
        defer { view.dismantleRenderSession() }
        /// Compared by identity value: `===` on an existential inside the macro
        /// crashes the 6.3 compiler.
        func publishedFirst() -> ObjectIdentifier? {
            #if canImport(UIKit)
            (view.accessibilityElements?.first as? NSObject).map(ObjectIdentifier.init)
            #else
            (view.accessibilityChildren()?.first as? NSObject).map(ObjectIdentifier.init)
            #endif
        }
        let before = try #require(publishedFirst())
        view.appendMarkdown(" and more")
        await view.settled { self.elements(view).last?.label == "alpha beta and more" }
        #expect(publishedFirst() == before, "the published element was rebuilt, so focus would move")
    }

    #if canImport(AppKit) && !canImport(UIKit)
    /// Registrations accumulated one per overlay recreation — every width *and*
    /// style change — for the life of the view, because only two of the four
    /// paths that discard an overlay unregistered.
    ///
    /// The first version of this test asserted `_tableOverlays.count <= 1`, a
    /// tautology for a one-table fixture: review measured it passing with the fix
    /// reverted while a stale observer still fired. It counts the registrations
    /// themselves now.
    @MainActor @Test func tableOverlayScrollObserversAreBalanced() async {
        let view = await self.view(
            "| a | b | c | d | e | f |\n|---|---|---|---|---|---|\n| 1 | 2 | 3 | 4 | 5 | 6 |", width: 80
        )
        #expect(!view._tableOverlays.isEmpty, "fixture no longer overflows")
        #expect(view.tableOverlayScrollObservers.count == view._tableOverlays.count)

        // Every path that discards an overlay: style churn, then width.
        for size in [15.0, 17.0, 19.0] {
            var style = RenderStyle.default
            style.bodyFont = .systemFont(ofSize: size)
            view.renderStyle = style
            await view.settled { view.currentSnapshot != nil }
            #expect(
                view.tableOverlayScrollObservers.count == view._tableOverlays.count,
                "leaked \(view.tableOverlayScrollObservers.count - view._tableOverlays.count) observer(s) on a style change"
            )
        }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 4000)
        view.layoutSubtreeIfNeeded()
        await view.settled { view.currentSnapshot != nil }
        #expect(view.tableOverlayScrollObservers.count == view._tableOverlays.count)

        view.dismantleRenderSession()
        #expect(view.tableOverlayScrollObservers.isEmpty, "teardown left observers registered")
    }

    /// The view is flipped, AppKit's parent space is not. Publishing a top-down
    /// TextKit rect as-is mirrors every element about the view's midpoint, so
    /// the first line is reported at the bottom.
    @MainActor @Test func publishedFramesAreNotVerticallyMirrored() async throws {
        let view = await self.view("# Title\n\nalpha beta\n\nomega")
        defer { view.dismantleRenderSession() }
        #expect(view.isFlipped)
        let children = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(children.count >= 3)
        let heading = try #require(children.first)
        let last = try #require(children.last)
        // Bottom-up parent space: the first line has the *greatest* y.
        #expect(
            heading.accessibilityFrameInParentSpace().minY > last.accessibilityFrameInParentSpace().minY,
            "frames are mirrored: heading at \(heading.accessibilityFrameInParentSpace())"
        )
        #expect(heading.accessibilityFrameInParentSpace().maxY <= view.bounds.height + 1)
    }
    #endif

    /// A leaf that disappears must not leave a stale object behind.
    @Test func replacingTheDocumentDropsTheOldElements() async throws {
        let view = await self.view("# Title\n\nalpha")
        defer { view.dismantleRenderSession() }
        let before = try #require(self.elements(view).first)
        view.setMarkdown("completely different")
        await view.settled { self.elements(view).map(\.label) == ["completely different"] }
        #expect(self.elements(view).first !== before)
    }
}
