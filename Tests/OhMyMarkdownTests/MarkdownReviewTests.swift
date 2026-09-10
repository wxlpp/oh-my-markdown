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
    @Test func inlineCommentsReserveSpaceWithoutChangingSelectionOrParsing() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        view.reviewConfiguration = .init(documentID: "c", revision: "1", onComment: { _ in })
        view.setMarkdown("First paragraph.\n\nSecond paragraph.")
        await view.settled { view.currentSnapshot != nil }
        let selection = try #require(view.reviewSelection(in: NSRange(location: 0, length: 5)))
        let original = try #require(view.contentStorage.textStorage?.string)
        let count = view._materializationCount
        view.reviewConfiguration?.annotations = [.init(id: "a", selection: selection), .init(id: "b", selection: selection)]
        view.reviewConfiguration?.inlineCommentHeights = ["a": 100, "b": 80]
        let frames = view.inlineCommentFrames()
        let first = try #require(frames["a"])
        let second = try #require(frames["b"])
        #expect(first.height == 100)
        #expect(second.minY >= first.maxY + 12)
        let nextRange = (original as NSString).range(of: "Second")
        let next = try #require(view.reviewRects(for: nextRange).first)
        #expect(next.minY >= second.maxY)
        #expect(view.contentStorage.textStorage?.string == original)
        #expect(view.reviewSelection(in: selection.renderedRange) == selection)
        #expect(view._materializationCount == count)
        view.reviewConfiguration?.inlineCommentHeights = [:]
        #expect(view.inlineCommentFrames().isEmpty)
        #expect(try #require(view.reviewRects(for: nextRange).first).minY < next.minY - 150)
        view.dismantleRenderSession()
    }

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
        view.reviewConfiguration?.isCommentingEnabled = false
        view.performReviewComment(selection, snapshotID: snapshotID)
        #expect(comments.count == 1)
        view.reviewConfiguration?.isCommentingEnabled = true
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

    @Test func overlappingAnnotationsUseInputOrderAndExposeGeometryStatus() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        var tapped: [String] = []
        view.reviewConfiguration = MarkdownReviewConfiguration(documentID: "c", revision: "1", onComment: { _ in }, onAnnotationTap: { tapped.append($0) })
        view.setMarkdown("中文😀 **加粗**\n\n第二段")
        await view.settled { view.currentSnapshot != nil }
        let selection = try #require(view.reviewSelection(in: NSRange(location: 0, length: 4)))
        view.reviewConfiguration?.annotations = [MarkdownAnnotation(id: "first", selection: selection), MarkdownAnnotation(id: "second", selection: selection)]
        #expect(view.annotationStatus(id: "first") == .located)
        let rect = try #require(view.annotationRect(id: "first"))
        #expect(rect.width > 0 && rect.height > 0)
        #expect(view.activateReviewAnnotation(at: CGPoint(x: rect.midX, y: rect.midY)))
        #expect(tapped == ["first"])
        view.dismantleRenderSession()
    }

    #if canImport(AppKit)
    @Test func nativeMenuRetainsItsSelectionGenerationAcrossResourceRefresh() throws {
        _ = NSApplication.shared
        let blocks: [BlockNode] = [.paragraph([.text("same "), .image(source: "https://example.com/menu.png", alt: "alt"), .text(" same")])]
        let old = MaterializationFixture().snapshot(blocks)
        var fixture = MaterializationFixture()
        fixture.images["https://example.com/menu.png"] = NSImage(size: CGSize(width: 10, height: 10))
        let resolved = fixture.snapshot(blocks)
        var comments: [MarkdownSelectionSnapshot] = []
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        view.reviewConfiguration = MarkdownReviewConfiguration(documentID: "c", revision: "1", commentActionTitle: "评论", onComment: { comments.append($0) })
        let token = RenderCommitToken(sessionID: RenderSessionID(rawValue: UUID()), sequence: 1, sourceRevision: 1, configurationGeneration: 0)
        view.replaceSnapshot(old, token: token)
        let root = view.contentStorage.documentRange.location
        let end = try #require(view.contentStorage.location(root, offsetBy: 4))
        let range = try #require(NSTextRange(location: root, end: end))
        view.layoutManager.textSelections = [NSTextSelection(range: range, affinity: .downstream, granularity: .character)]
        let menu = try #require(view.menu(for: NSEvent()))
        let index = try #require(menu.items.firstIndex { $0.title == "评论" })
        menu.performActionForItem(at: index)
        #expect(comments.count == 1)
        #expect(comments.first?.renderedContentID == old.renderedContentID)
        // Resource publication replaces a snapshot without advancing the source token.
        view.replaceSnapshot(resolved, token: token)
        menu.performActionForItem(at: index)
        #expect(comments.count == 1)
        let currentMenu = try #require(view.menu(for: NSEvent()))
        let currentIndex = try #require(currentMenu.items.firstIndex { $0.title == "评论" })
        currentMenu.performActionForItem(at: currentIndex)
        #expect(comments.count == 2)
        #expect(comments.last?.renderedContentID == resolved.renderedContentID)
        view.dismantleRenderSession()
    }
    #endif

    #if canImport(UIKit)
    @Test func nativeSelectionMenuAddsCommentAndHonorsReadOnlyState() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        view.reviewConfiguration = MarkdownReviewConfiguration(documentID: "c", revision: "1", commentActionTitle: "评论", onComment: { _ in })
        view.setMarkdown("中文😀")
        await view.settled { view.currentSnapshot != nil }
        let range = MarkdownTextRange(from: 0, to: 4)
        let copy = UIAction(title: "Copy") { _ in }
        let menu = try #require(view.editMenu(for: range, suggestedActions: [copy]))
        #expect(menu.children.count == 2)
        #expect((menu.children.first as? UIAction)?.title == "评论")
        #expect(menu.children.last?.title == "Copy")
        view.reviewConfiguration?.isCommentingEnabled = false
        #expect(view.editMenu(for: range, suggestedActions: [copy]) == nil)
        view.reviewConfiguration?.copyActionTitle = "复制"
        view.reviewConfiguration?.copyMarkdownSourceActionTitle = "复制 Markdown 源码"
        let rendered = UICommand(title: "Copy", action: #selector(MarkdownLabelView.copy(_:)), propertyList: nil, alternates: [])
        let source = UICommand(title: "Copy Markdown Source", action: #selector(MarkdownLabelView.copyMarkdownSource(_:)), propertyList: nil, alternates: [])
        let localized = try #require(view.editMenu(for: range, suggestedActions: [UIMenu(children: [rendered, source])]))
        let group = try #require(localized.children.first as? UIMenu)
        #expect(group.children.map(\.title) == ["复制", "复制 Markdown 源码"])
        #expect(rendered.title == "Copy")
        view.dismantleRenderSession()
    }
    #endif
}
