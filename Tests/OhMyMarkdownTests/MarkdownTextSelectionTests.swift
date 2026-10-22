import Foundation
@testable import MarkdownPlatformView
import Testing
#if canImport(UIKit)
import UIKit

@Suite(.serialized)
struct MarkdownTextSelectionTests {
    @Test @MainActor func positionsAndHandlesFollowRenderedParagraphs() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 40, y: 150, width: 320, height: 700))
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 900))
        let window = UIWindow(frame: parent.bounds)
        let controller = UIViewController()
        controller.view = parent
        window.rootViewController = controller
        window.makeKeyAndVisible()
        parent.addSubview(view)
        defer { window.isHidden = true }
        defer { view.dismantleRenderSession() }
        view.setMarkdown("第一段用于检查选择。\n\n第二段包含需要选中的文字。\n\n第三段用于检查边界。")
        await view.settled { view.currentSnapshot != nil }
        let string = try #require(view.currentSnapshot).attributedString.string as NSString
        for word in ["第一段", "需要选中", "第三段"] {
            let range = string.range(of: word)
            let start = try #require(view.position(from: view.beginningOfDocument, offset: range.location))
            let end = try #require(view.position(from: start, offset: range.length))
            let textRange = try #require(view.textRange(from: start, to: end))
            let rects = view.selectionRects(for: textRange)
            let rect = try #require(rects.first).rect
            let position = try #require(view.closestPosition(to: CGPoint(x: rect.midX, y: rect.midY)))
            let offset = view.offset(from: view.beginningOfDocument, to: position)
            #expect((range.location...NSMaxRange(range)).contains(offset))
            #expect(rects.contains { $0.containsStart })
            #expect(rects.contains { $0.containsEnd })
            #expect(abs(view.firstRect(for: textRange).minY - rect.minY) < 1)
            let restricted = try #require(view.closestPosition(to: CGPoint(x: 310, y: 650), within: textRange))
            #expect((range.location...NSMaxRange(range)).contains(view.offset(from: view.beginningOfDocument, to: restricted)))
        }
    }
    @Test @MainActor func hitTestingTracksWrappedTextAndEmoji() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 220, height: 3000))
        defer { view.dismantleRenderSession() }
        view.setMarkdown(String(repeating: "中文段落包含 **重点文字** 和 emoji 👩‍💻，拖动选择应跟随文字。\n\n", count: 12))
        await view.settled { view.currentSnapshot != nil }
        let string = try #require(view.currentSnapshot).attributedString.string as NSString
        for offset in stride(from: 0, to: string.length, by: 7) {
            let range = string.rangeOfComposedCharacterSequence(at: offset)
            if string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let start = try #require(view.position(from: view.beginningOfDocument, offset: range.location))
            let end = try #require(view.position(from: start, offset: range.length))
            let textRange = try #require(view.textRange(from: start, to: end))
            let rect = try #require(view.selectionRects(for: textRange).first).rect
            let position = try #require(view.closestPosition(to: CGPoint(x: rect.midX, y: rect.midY)))
            #expect((range.location...NSMaxRange(range)).contains(view.offset(from: view.beginningOfDocument, to: position)))
        }
    }
    @Test @MainActor func enlargedCitationDoesNotStealOrdinaryText() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("来源参考[1](https://example.com/one)紧邻文字。")
        await view.settled { view.currentSnapshot != nil }
        let string = try #require(view.currentSnapshot).attributedString.string as NSString
        for word in ["考", "紧"] {
            let range = string.range(of: word)
            let start = try #require(view.position(from: view.beginningOfDocument, offset: range.location))
            let end = try #require(view.position(from: start, offset: 1))
            let textRange = try #require(view.textRange(from: start, to: end))
            let rect = try #require(view.selectionRects(for: textRange).first).rect
            #expect(!view.activateLink(at: CGPoint(x: rect.midX, y: rect.midY)))
        }
    }
    @Test @MainActor func smallCitationAcceptsNearMissWithoutOpeningDistantText() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("来源参考 [1](https://example.com/one) 和 [2](https://example.com/two)。")
        await view.settled { view.currentSnapshot != nil }
        let string = try #require(view.currentSnapshot).attributedString.string as NSString
        let range = string.range(of: "1")
        let start = try #require(view.position(from: view.beginningOfDocument, offset: range.location))
        let end = try #require(view.position(from: start, offset: 1))
        let textRange = try #require(view.textRange(from: start, to: end))
        let rect = try #require(view.selectionRects(for: textRange).first).rect
        let handler = RecordingLinkHandler()
        view.linkConfiguration = .webOnly(handler: handler)
        #expect(view.activateLink(at: CGPoint(x: rect.midX, y: rect.maxY + 5)))
        await handler.events.settled { !handler.opened.isEmpty }
        #expect(handler.opened.last?.absoluteString == "https://example.com/one")
        let second = string.range(of: "2")
        let secondStart = try #require(view.position(from: view.beginningOfDocument, offset: second.location))
        let secondEnd = try #require(view.position(from: secondStart, offset: 1))
        let secondRange = try #require(view.textRange(from: secondStart, to: secondEnd))
        let secondRect = try #require(view.selectionRects(for: secondRange).first).rect
        #expect(view.activateLink(at: CGPoint(x: secondRect.midX, y: secondRect.midY)))
        await handler.events.settled { handler.opened.count == 2 }
        #expect(handler.opened.last?.absoluteString == "https://example.com/two")
        #expect(!view.activateLink(at: CGPoint(x: rect.midX, y: rect.maxY + 45)))
    }
}
#endif
