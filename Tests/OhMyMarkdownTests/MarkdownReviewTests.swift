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

@MainActor
struct MarkdownReviewTests {
    @Test func snapshotRejectsStaleDocumentAndInvalidUTF16Ranges() throws {
        let text = NSAttributedString(string: "中文😀 **text**")
        let selection = MarkdownSelectionSnapshot(documentID: "chapter", revision: "v1", renderedRange: NSRange(location: 0, length: 4), quote: "中文😀", renderedContentID: "rendered")
        #expect(selection.matches(documentID: "chapter", revision: "v1", text: text, renderedContentID: "rendered"))
        #expect(!selection.matches(documentID: "chapter", revision: "v2", text: text, renderedContentID: "rendered"))
        #expect(!MarkdownSelectionSnapshot(documentID: "chapter", revision: "v1", renderedRange: NSRange(location: 0, length: Int.max), quote: "中文😀", renderedContentID: "rendered").matches(documentID: "chapter", revision: "v1", text: text, renderedContentID: "rendered"))
        #expect(try JSONDecoder().decode(MarkdownSelectionSnapshot.self, from: JSONEncoder().encode(selection)) == selection)
    }

    @Test func annotationsDoNotStartAParseAndRejectStaleQuote() async {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        view.setMarkdown("中文😀 **加粗**\n\n第二段")
        await view.settled { view.currentSnapshot != nil }
        let count = view._materializationCount
        let selection = MarkdownSelectionSnapshot(documentID: "c", revision: "1", renderedRange: NSRange(location: 0, length: 4), quote: "中文😀", renderedContentID: view.currentSnapshot?.renderedContentID ?? "")
        view.reviewConfiguration = MarkdownReviewConfiguration(documentID: "c", revision: "1", annotations: [MarkdownAnnotation(id: "a", selection: selection)], onComment: { _ in })
        #expect(view.validReviewAnnotations.count == 1)
        #expect(view._materializationCount == count)
        view.reviewConfiguration = MarkdownReviewConfiguration(documentID: "c", revision: "2", annotations: [MarkdownAnnotation(id: "a", selection: selection)], onComment: { _ in })
        #expect(view.validReviewAnnotations.isEmpty)
        view.dismantleRenderSession()
    }

    @Test func expiredMenuActionCannotCommentOnAnotherSnapshot() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        var comments: [MarkdownSelectionSnapshot] = []
        view.reviewConfiguration = MarkdownReviewConfiguration(documentID: "c", revision: "1", onComment: { comments.append($0) })
        view.setMarkdown("first😀")
        await view.settled { view.currentSnapshot != nil }
        let selection = try #require(view.reviewSelection(in: NSRange(location: 0, length: 5)))
        let snapshotID = view.currentSnapshot?.id
        view.performReviewComment(selection, snapshotID: snapshotID)
        #expect(comments == [selection])
        view.setMarkdown("first😀 changed")
        view.performReviewComment(selection, snapshotID: snapshotID)
        #expect(comments.count == 1)
        await view.settled { view.currentSnapshot?.id != snapshotID }
        view.performReviewComment(selection, snapshotID: snapshotID)
        #expect(comments.count == 1)
        view.dismantleRenderSession()
    }

    @Test func renderedIdentityRejectsResourceCoordinateChangesAndSurvivesRebuilds() throws {
        let blocks: [BlockNode] = [.paragraph([.text("same "), .image(source: "https://example.com/image.png", alt: "alt"), .text(" same")])]
        let unresolved = MaterializationFixture().snapshot(blocks)
        let rebuilt = MaterializationFixture().snapshot(blocks)
        #expect(unresolved.renderedContentID == rebuilt.renderedContentID)
        var resolvedFixture = MaterializationFixture()
        #if canImport(UIKit)
        let image = try #require(UIImage(systemName: "star"))
        #else
        let image = NSImage(size: CGSize(width: 10, height: 10))
        #endif
        resolvedFixture.images["https://example.com/image.png"] = image
        let resolved = resolvedFixture.snapshot(blocks)
        #expect(unresolved.renderedContentID != resolved.renderedContentID)
        let selection = MarkdownSelectionSnapshot(documentID: "c", revision: "1", renderedRange: NSRange(location: 0, length: 4), quote: "same", renderedContentID: unresolved.renderedContentID)
        #expect(selection.status(documentID: "c", revision: "1", text: resolved.attributedString, renderedContentID: resolved.renderedContentID) == .renderedContentChanged)
        #expect(selection.matches(documentID: "c", revision: "1", text: rebuilt.attributedString, renderedContentID: rebuilt.renderedContentID))
    }
}
