import Foundation
import MarkdownKit
#if canImport(AppKit)
import AppKit
import MarkdownPlatformView
#endif
import Testing

// MARK: - MarkdownEditorCommandTests

@Suite("MarkdownEditorCommands")
struct MarkdownEditorCommandTests {
    @Test("Return continues unordered list and resets task marker")
    func continueUnorderedTaskList() throws {
        let text = "- [x] done"
        let result = try #require(
            MarkdownEditorCommands.insertNewline(in: text, selection: NSRange(location: text.count, length: 0))
        )

        #expect(result.text == "- [x] done\n- [ ] ")
        #expect(result.selectedRange == NSRange(location: result.text.count, length: 0))
    }

    @Test("Return exits empty list item")
    func exitEmptyListItem() throws {
        let text = "- "
        let result = try #require(
            MarkdownEditorCommands.insertNewline(in: text, selection: NSRange(location: text.count, length: 0))
        )

        #expect(result.text == "\n")
        #expect(result.selectedRange == NSRange(location: 1, length: 0))
    }

    @Test("Indent and outdent operate on selected lines")
    func indentAndOutdentSelection() {
        let original = "first\nsecond"
        let indented = MarkdownEditorCommands.indentSelection(
            in: original,
            selection: NSRange(location: 0, length: original.count)
        )
        #expect(indented.text == "    first\n    second")
        #expect(indented.selectedRange.upperBound <= (indented.text as NSString).length)

        let outdented = MarkdownEditorCommands.outdentSelection(
            in: indented.text,
            selection: indented.selectedRange
        )
        #expect(outdented.text == original)
    }

    @Test("Indent uses UTF-16 offsets for emoji-containing text")
    func indentSelectionWithEmojiText() {
        let original = "😀 first\nsecond"
        let selection = NSRange(location: 0, length: (original as NSString).length)

        let indented = MarkdownEditorCommands.indentSelection(in: original, selection: selection)

        #expect(indented.text == "    😀 first\n    second")
        #expect(indented.selectedRange.upperBound <= (indented.text as NSString).length)

        let outdented = MarkdownEditorCommands.outdentSelection(
            in: indented.text,
            selection: indented.selectedRange
        )
        #expect(outdented.text == original)
    }

    @Test("Toggle task list inserts and flips checkbox markers")
    func toggleTaskMarkers() throws {
        let inserted = try #require(
            MarkdownEditorCommands.toggleTaskList(in: "- item", selection: NSRange(location: 2, length: 0))
        )
        #expect(inserted.text == "- [ ] item")

        let toggled = try #require(
            MarkdownEditorCommands.toggleTaskList(in: inserted.text, selection: NSRange(location: 4, length: 0))
        )
        #expect(toggled.text == "- [x] item")
    }

    @Test("Wrap selection applies Markdown delimiters")
    func wrapSelection() throws {
        let text = "hello"
        let result = try #require(
            MarkdownEditorCommands.wrapSelection(
                in: text,
                selection: NSRange(location: 0, length: 5),
                prefix: "**",
                suffix: "**"
            )
        )

        #expect(result.text == "**hello**")
        #expect(result.selectedRange == NSRange(location: 2, length: 5))
    }

    #if canImport(AppKit)
    @MainActor
    @Test("macOS custom editor commands can be undone with Command-Z")
    func macEditorCommandUndo() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        editor.setMarkdown("hello")

        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        #expect(editor.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))) == true)
        #expect(textView.string == "    hello")

        let undoManager = try #require(textView.undoManager)
        undoManager.undo()

        #expect(textView.string == "hello")
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @MainActor
    @Test("macOS editor wrapper forwards first responder to NSTextView")
    func macEditorWrapperForwardsFirstResponder() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editor

        #expect(window.makeFirstResponder(editor) == true)
        #expect(window.firstResponder === textView)
    }

    @MainActor
    @Test("macOS Command-Z key equivalent undoes custom editor commands")
    func macCommandZUndoesCustomCommand() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        editor.setMarkdown("hello")

        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        #expect(editor.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))) == true)
        #expect(textView.string == "    hello")

        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "z",
                charactersIgnoringModifiers: "z",
                isARepeat: false,
                keyCode: 6
            )
        )

        #expect(textView.performKeyEquivalent(with: event) == true)
        #expect(textView.string == "hello")
    }

    @MainActor
    @Test("macOS Command-Z undoes normal typing instead of highlight-only changes")
    func macCommandZUndoesTyping() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        editor.setMarkdown("hello")

        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        textView.insertText("!", replacementRange: textView.selectedRange())
        #expect(textView.string == "hello!")

        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "z",
                charactersIgnoringModifiers: "z",
                isARepeat: false,
                keyCode: 6
            )
        )

        #expect(textView.performKeyEquivalent(with: event) == true)
        #expect(textView.string == "hello")
    }

    @MainActor
    @Test("macOS editor wrapper forwards Command-Z into the inner text view")
    func macWrapperCommandZForwardsToInnerTextView() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        editor.setMarkdown("hello")

        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        #expect(editor.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))) == true)
        #expect(textView.string == "    hello")

        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "z",
                charactersIgnoringModifiers: "z",
                isARepeat: false,
                keyCode: 6
            )
        )

        #expect(editor.performKeyEquivalent(with: event) == true)
        #expect(textView.string == "hello")
    }

    @MainActor
    @Test("macOS Return at EOF scrolls continued list item into view")
    func macReturnAtEOFScrollsContinuedListItemIntoView() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 72))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 72),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editor
        editor.layoutSubtreeIfNeeded()

        let source = (1 ... 60).map { "- item \($0)" }.joined(separator: "\n")
        editor.setMarkdown(source)

        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        try textView.layoutManager?.ensureLayout(for: #require(textView.textContainer))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))

        #expect(editor.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))) == true)
        #expect(textView.string.hasSuffix("\n- "))
        try textView.layoutManager?.ensureLayout(for: #require(textView.textContainer))
        let maxScrollY = max(0, textView.frame.height - scrollView.contentView.bounds.height)
        #expect(scrollView.contentView.bounds.origin.y >= maxScrollY - 1)
    }

    @MainActor
    @Test("macOS append then Return twice at EOF keeps layout and bottom scroll stable")
    func macAppendThenReturnTwiceAtEOFKeepsBottomScrollStable() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 260, height: 96))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 96),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editor
        editor.layoutSubtreeIfNeeded()

        let initial = (1 ... 50).map { "paragraph \($0)" }.joined(separator: "\n")
        editor.setMarkdown(initial)
        editor.setMarkdown(initial + "\n\n- [ ] 新任务\n- [ ] 继续输入")

        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        try textView.layoutManager?.ensureLayout(for: #require(textView.textContainer))
        textView.scrollToEndOfDocument(nil)

        #expect(editor.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))) == true)
        #expect(editor.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))) == true)

        let textContainer = try #require(textView.textContainer)
        textView.layoutManager?.ensureLayout(for: textContainer)
        let usedHeight = textView.layoutManager?.usedRect(for: textContainer).height ?? 0
        let documentHeight = max(textView.bounds.height, usedHeight + textView.textContainerInset.height * 2)
        let maxScrollY = max(0, documentHeight - scrollView.contentView.bounds.height)

        #expect(usedHeight > scrollView.contentView.bounds.height)
        #expect(scrollView.contentView.bounds.origin.y >= maxScrollY - 1)
    }
    #endif
}
