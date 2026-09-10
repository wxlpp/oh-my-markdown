import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import MarkdownCore
import Testing

@MainActor
struct MarkdownReviewTests {
    @Test func snapshotRejectsStaleDocumentAndInvalidUTF16Ranges() throws {
        let text = NSAttributedString(string: "中文😀 **text**")
        let selection = MarkdownSelectionSnapshot(documentID: "chapter", revision: "v1", renderedRange: NSRange(location: 0, length: 4), quote: "中文😀")
        #expect(selection.matches(documentID: "chapter", revision: "v1", text: text))
        #expect(!selection.matches(documentID: "chapter", revision: "v2", text: text))
        #expect(!MarkdownSelectionSnapshot(documentID: "chapter", revision: "v1", renderedRange: NSRange(location: 0, length: Int.max), quote: "中文😀").matches(documentID: "chapter", revision: "v1", text: text))
        #expect(try JSONDecoder().decode(MarkdownSelectionSnapshot.self, from: JSONEncoder().encode(selection)) == selection)
    }

    @Test func annotationsDoNotStartAParseAndRejectStaleQuote() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        view.setMarkdown("中文😀 **加粗**\n\n第二段")
        await view.settled { view.currentSnapshot != nil }
        let count = view._materializationCount
        let selection = MarkdownSelectionSnapshot(documentID: "c", revision: "1", renderedRange: NSRange(location: 0, length: 4), quote: "中文😀")
        view.reviewConfiguration = MarkdownReviewConfiguration(documentID: "c", revision: "1", annotations: [MarkdownAnnotation(id: "a", selection: selection)], onComment: { _ in })
        #expect(view.validReviewAnnotations.count == 1)
        #expect(view._materializationCount == count)
        view.reviewConfiguration = MarkdownReviewConfiguration(documentID: "c", revision: "2", annotations: [MarkdownAnnotation(id: "a", selection: selection)], onComment: { _ in })
        #expect(view.validReviewAnnotations.isEmpty)
        view.dismantleRenderSession()
    }
}
