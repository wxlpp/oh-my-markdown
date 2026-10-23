import Foundation
@testable import MarkdownPlatformView
import Testing
#if canImport(UIKit)
import UIKit

@Suite(.serialized)
struct MarkdownTextSelectionTests {
    @Test @MainActor func widthProbePreservesDecorationDrawing() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("前面的普通段落需要足够长，才能在不同宽度下换行，并且改变后面引用段落的位置。\n\n> 引用的竖线应该与正文对齐。")
        await view.settled { view.currentSnapshot != nil }
        view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let before = try #require(renderer.image { _ in view.draw(view.bounds) }.pngData())
        _ = view.sizeThatFits(CGSize(width: 10000, height: CGFloat.greatestFiniteMagnitude))
        let after = try #require(renderer.image { _ in view.draw(view.bounds) }.pngData())
        let matches = before == after
        #expect(matches)
    }

    @Test @MainActor func widthProbePreservesAnnotationGeometry() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("前面的普通段落需要足够长，才能在不同宽度下换行，并且改变后面引用段落的位置。\n\nApple 平台。")
        await view.settled { view.currentSnapshot != nil }
        view.layoutIfNeeded()
        let text = try #require(view.contentStorage.textStorage?.string as NSString?)
        let range = text.range(of: "Apple")
        let expected = view.reviewRects(for: range)
        _ = view.sizeThatFits(CGSize(width: 10000, height: CGFloat.greatestFiniteMagnitude))
        #expect(view.reviewRects(for: range) == expected)
    }

    @Test @MainActor func measuringAnotherWidthPreservesSelectionGeometry() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 362, height: 400))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("可以先从 Swift 官方文档入手，了解语言、标准库和工具链。[1](https://example.com)\n\nApple 平台的具体 API 可以查阅开发者文档；目前只有搜索摘要。")
        await view.settled { view.currentSnapshot != nil }
        view.layoutIfNeeded()
        let text = try #require(view.contentStorage.textStorage?.string as NSString?)
        let apple = text.range(of: "Apple")
        let start = try #require(view.position(from: view.beginningOfDocument, offset: apple.location))
        let end = try #require(view.position(from: start, offset: apple.length))
        let range = try #require(view.textRange(from: start, to: end))
        view.selectedTextRange = range
        let expectedCaret = view.caretRect(for: start)
        let expectedFirst = view.firstRect(for: range)
        let expectedSelection = view.selectionRects(for: range).map(\.rect)
        for width: CGFloat in [10000, 180, 500] {
            _ = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            #expect(view.selectionRects(for: range).map(\.rect) == expectedSelection)
            _ = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            #expect(view.caretRect(for: start) == expectedCaret)
            _ = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            #expect(view.firstRect(for: range) == expectedFirst)
        }
    }

    @Test(arguments: ["甲乙丙丁", "مرحبا", "office", "👩‍💻e\u{301}后"]) @MainActor func closestPositionUsesNearestCaretBoundary(sample: String) async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        defer { view.dismantleRenderSession() }
        view.setMarkdown(sample)
        await view.settled { view.currentSnapshot != nil }
        var index = 0
        for character in sample {
            let length = String(character).utf16.count
            let start = try #require(view.position(from: view.beginningOfDocument, offset: index))
            let end = try #require(view.position(from: start, offset: length))
            let range = try #require(view.textRange(from: start, to: end))
            let selection = try #require(view.selectionRects(for: range).first)
            let rect = view.firstRect(for: range)
            let rtl = selection.writingDirection == .rightToLeft
            for (fraction, expected) in [(0.25, rtl ? index + length : index), (0.75, rtl ? index : index + length)] {
                let hit = try #require(view.closestPosition(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.midY)))
                #expect(view.offset(from: view.beginningOfDocument, to: hit) == expected)
            }
            index += length
        }
    }

    @Test @MainActor func selectionSetterMatchesNativeNotificationContract() async throws {
        let native = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        native.text = "甲乙丙丁戊己庚辛"
        let custom = MarkdownLabelView(frame: native.frame)
        defer { custom.dismantleRenderSession() }
        custom.setMarkdown(native.text)
        await custom.settled { custom.currentSnapshot != nil }
        let nativeDelegate = SelectionNotificationRecorder()
        let customDelegate = SelectionNotificationRecorder()
        native.inputDelegate = nativeDelegate
        custom.inputDelegate = customDelegate
        for endOffset in [4, 5, 6, 7, 6, 5] {
            for input: any UITextInput in [native, custom] {
                let start = try #require(input.position(from: input.beginningOfDocument, offset: 2))
                let end = try #require(input.position(from: input.beginningOfDocument, offset: endOffset))
                input.selectedTextRange = input.textRange(from: start, to: end)
                let selection = try #require(input.selectedTextRange)
                #expect(input.offset(from: input.beginningOfDocument, to: selection.start) == 2)
                #expect(input.offset(from: input.beginningOfDocument, to: selection.end) == endOffset)
            }
        }
        #expect(customDelegate.events == nativeDelegate.events)
    }

    @Test(arguments: ["甲乙丙丁", "مرحبا", "office", "👩‍💻e\u{301}后"]) @MainActor func characterHitIncludesBothHalvesOfGlyph(sample: String) async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        defer { view.dismantleRenderSession() }
        view.setMarkdown(sample)
        await view.settled { view.currentSnapshot != nil }
        var index = 0
        for character in sample {
            let length = String(character).utf16.count
            let start = try #require(view.position(from: view.beginningOfDocument, offset: index))
            let end = try #require(view.position(from: start, offset: length))
            index += length
            let range = try #require(view.textRange(from: start, to: end))
            let rect = view.firstRect(for: range)
            for fraction in [0.25, 0.75] {
                let hit = try #require(view.characterRange(at: CGPoint(x: rect.minX + rect.width * fraction, y: rect.midY)))
                #expect(view.text(in: hit) == view.text(in: range))
            }
        }
    }

    @Test @MainActor func paragraphEndBlankHitStaysBeforeSeparator() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("第一段\n\n第二段")
        await view.settled { view.currentSnapshot != nil }
        let end = try #require(view.position(from: view.beginningOfDocument, offset: 3))
        let caret = view.caretRect(for: end)
        let hit = try #require(view.closestPosition(to: CGPoint(x: caret.maxX + 30, y: caret.midY)))
        #expect(view.offset(from: view.beginningOfDocument, to: hit) == 3)
    }

    @Test @MainActor func lineEndBlankHitResolvesToInsertionBoundary() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("甲乙丙")
        await view.settled { view.currentSnapshot != nil }
        let end = view.caretRect(for: view.endOfDocument)
        let position = try #require(view.closestPosition(to: CGPoint(x: end.maxX + 30, y: end.midY)))
        #expect(view.offset(from: view.beginningOfDocument, to: position) == view.documentLength)
        let start = view.caretRect(for: view.beginningOfDocument)
        let before = try #require(view.closestPosition(to: CGPoint(x: start.minX - 30, y: start.midY)))
        #expect(view.offset(from: view.beginningOfDocument, to: before) == 0)
    }

    @Test(arguments: ["", "> "]) @MainActor func repeatedVerticalMovementRetainsHorizontalIntent(prefix: String) async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("\(prefix)abcdefghij  \n\(prefix)x  \n\(prefix)abcdefghij")
        await view.settled { view.currentSnapshot != nil }
        let start = try #require(view.position(from: view.beginningOfDocument, offset: 8))
        let short = try #require(view.position(from: start, in: .down, offset: 1))
        let last = try #require(view.position(from: short, in: .down, offset: 1))
        #expect(abs(view.caretRect(for: last).midX - view.caretRect(for: start).midX) < 1)
        let twoLines = try #require(view.position(from: start, in: .down, offset: 2))
        #expect(view.offset(from: last, to: twoLines) == 0)
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

    @Test @MainActor func mixedDirectionRectsFollowSelectedRun() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("abc مرحبا xyz")
        await view.settled { view.currentSnapshot != nil }
        let start = try #require(view.position(from: view.beginningOfDocument, offset: 4))
        let end = try #require(view.position(from: start, offset: 5))
        let range = try #require(view.textRange(from: start, to: end))
        let rects = view.selectionRects(for: range)
        #expect(!rects.isEmpty)
        #expect(rects.allSatisfy { $0.writingDirection == .rightToLeft })
    }

    @Test @MainActor func paragraphBoundaryRespectsStorageDirection() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("مرحبا\n\nEnglish")
        await view.settled { view.currentSnapshot != nil }
        let text = try #require(view.currentSnapshot).attributedString.string as NSString
        let position = try #require(view.position(from: view.beginningOfDocument, offset: text.range(of: "English").location))
        #expect(view.baseWritingDirection(for: position, in: .forward) == .leftToRight)
        #expect(view.baseWritingDirection(for: position, in: .backward) == .rightToLeft)
    }

    @Test @MainActor func farthestPositionExistsAtDocumentEdges() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("第一行\n\n最后一行")
        await view.settled { view.currentSnapshot != nil }
        let range = try #require(view.textRange(from: view.beginningOfDocument, to: view.endOfDocument))
        for direction: UITextLayoutDirection in [.up, .down, .left, .right] {
            #expect(view.position(within: range, farthestIn: direction) != nil)
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

@MainActor private final class SelectionNotificationRecorder: NSObject, UITextInputDelegate {
    var events: [String] = []
    @available(iOS 18.4, *)
    func conversationContext(_ context: UIConversationContext?, didChange textInput: (any UITextInput)?) {}
    func selectionWillChange(_ textInput: (any UITextInput)?) {
        self.events.append("selectionWillChange")
    }

    func selectionDidChange(_ textInput: (any UITextInput)?) {
        self.events.append("selectionDidChange")
    }

    func textWillChange(_ textInput: (any UITextInput)?) {
        self.events.append("textWillChange")
    }

    func textDidChange(_ textInput: (any UITextInput)?) {
        self.events.append("textDidChange")
    }
}
#endif
