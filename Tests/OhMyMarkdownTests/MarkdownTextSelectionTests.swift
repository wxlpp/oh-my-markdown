import Foundation
@testable import MarkdownPlatformView
import Testing
#if canImport(UIKit)
import UIKit

@Suite(.serialized)
struct MarkdownTextSelectionTests {
    @Test @MainActor func characterHitIncludesBothHalvesOfGlyph() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("甲乙丙丁")
        await view.settled { view.currentSnapshot != nil }
        for index in 0 ..< 4 {
            let start = try #require(view.position(from: view.beginningOfDocument, offset: index))
            let end = try #require(view.position(from: start, offset: 1))
            let range = try #require(view.textRange(from: start, to: end))
            let rect = view.firstRect(for: range)
            for fraction in [0.25, 0.75] {
                let hit = try #require(view.characterRange(at: CGPoint(x: rect.minX + rect.width * fraction, y: rect.midY)))
                #expect(view.text(in: hit) == view.text(in: range))
            }
        }
    }

    @Test @MainActor func mixedDirectionCharacterExtensionSelectsOneGrapheme() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("abc مرحبا xyz")
        await view.settled { view.currentSnapshot != nil }
        let text = try #require(view.currentSnapshot).attributedString.string as NSString
        for index in 1 ..< text.length {
            let position = try #require(view.position(from: view.beginningOfDocument, offset: index))
            for direction: UITextLayoutDirection in [.left, .right] {
                let range = try #require(view.characterRange(byExtending: position, in: direction))
                let selected = try #require(view.text(in: range))
                #expect(selected.count <= 1, "index \(index), direction \(direction): \(selected)")
            }
        }
    }

    @Test @MainActor func extendingSelectionKeepsComposedCharactersWhole() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("前👩‍💻e\u{301}后")
        await view.settled { view.currentSnapshot != nil }
        let text = try #require(view.currentSnapshot).attributedString.string as NSString
        for character in ["👩‍💻", "e\u{301}"] {
            let range = text.range(of: character)
            let start = try #require(view.position(from: view.beginningOfDocument, offset: range.location))
            let end = try #require(view.position(from: start, offset: range.length))
            let forward = try #require(view.characterRange(byExtending: start, in: .right))
            let backward = try #require(view.characterRange(byExtending: end, in: .left))
            #expect(view.text(in: forward) == character)
            #expect(view.text(in: backward) == character)
            let next = try #require(view.position(from: start, in: .right, offset: 1))
            #expect(view.offset(from: start, to: next) == range.length)
        }
    }

    @Test @MainActor func verticalMovementFollowsRenderedLines() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 180, height: 800))
        defer { view.dismantleRenderSession() }
        view.setMarkdown(String(repeating: "一二三四五六七八九十", count: 8))
        await view.settled { view.currentSnapshot != nil }
        let start = try #require(view.position(from: view.beginningOfDocument, offset: 2))
        let down = try #require(view.position(from: start, in: .down, offset: 1))
        #expect(view.caretRect(for: down).midY > view.caretRect(for: start).midY + 5)
        let up = try #require(view.position(from: down, in: .up, offset: 1))
        #expect(abs(view.caretRect(for: up).midY - view.caretRect(for: start).midY) < 1)
    }

    @Test @MainActor func rightToLeftSelectionReportsItsDirectionAndVisualEdge() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("مرحبا بالعالم")
        await view.settled { view.currentSnapshot != nil }
        let start = try #require(view.position(from: view.beginningOfDocument, offset: 1))
        let end = try #require(view.position(from: start, offset: 3))
        let range = try #require(view.textRange(from: start, to: end))
        #expect(view.baseWritingDirection(for: start, in: .forward) == .rightToLeft)
        #expect(view.selectionRects(for: range).allSatisfy { $0.writingDirection == .rightToLeft })
        let right = try #require(view.position(within: range, farthestIn: .right))
        let left = try #require(view.position(within: range, farthestIn: .left))
        #expect(view.offset(from: start, to: right) == 0)
        #expect(view.offset(from: end, to: left) == 0)
    }

    @Test @MainActor func logicalOffsetsRejectPositionsOutsideDocument() async {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("正文")
        await view.settled { view.currentSnapshot != nil }
        #expect(view.position(from: view.beginningOfDocument, offset: -1) == nil)
        #expect(view.position(from: view.endOfDocument, offset: 1) == nil)
    }

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
            #expect((range.location ... NSMaxRange(range)).contains(offset))
            #expect(rects.contains { $0.containsStart })
            #expect(rects.contains { $0.containsEnd })
            #expect(abs(view.firstRect(for: textRange).minY - rect.minY) < 1)
            let restricted = try #require(view.closestPosition(to: CGPoint(x: 310, y: 650), within: textRange))
            #expect((range.location ... NSMaxRange(range)).contains(view.offset(from: view.beginningOfDocument, to: restricted)))
        }
    }

    @Test @MainActor func nativeTokenizerSelectsWordInLaterParagraph() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 360, height: 500))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("第一段内容。\n\nApple 平台的具体 API 可以查阅开发者文档。\n\n> 最后一个引用段落。")
        await view.settled { view.currentSnapshot != nil }
        let string = try #require(view.currentSnapshot).attributedString.string as NSString
        let word = string.range(of: "Apple")
        let wordStart = try #require(view.position(from: view.beginningOfDocument, offset: word.location))
        let wordEnd = try #require(view.position(from: wordStart, offset: word.length))
        let wordRange = try #require(view.textRange(from: wordStart, to: wordEnd))
        let rect = try #require(view.selectionRects(for: wordRange).first).rect
        let hit = try #require(view.closestPosition(to: CGPoint(x: rect.midX, y: rect.midY)))
        #expect((word.location ... NSMaxRange(word)).contains(view.offset(from: view.beginningOfDocument, to: hit)))
        let offset = string.range(of: "Apple").location + 2
        let position = try #require(view.position(from: view.beginningOfDocument, offset: offset))
        let range = try #require(view.tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)))
        #expect(view.text(in: range) == "Apple")
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
            #expect((range.location ... NSMaxRange(range)).contains(view.offset(from: view.beginningOfDocument, to: position)))
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
