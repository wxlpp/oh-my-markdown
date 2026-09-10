import Foundation
import OhMyMarkdown
import Testing

#if canImport(AppKit)
import AppKit
import MarkdownPlatformView

// MARK: - MarkdownEditorProxyTests (macOS)

@Suite("MarkdownEditor public API (proxy + onInsertText)")
struct MarkdownEditorProxyTests {
    @MainActor
    @Test("onInsertText .allow lets the keystroke through")
    func onInsertTextAllowsByDefault() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        editor.setMarkdown("hello")
        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        var seen: String?
        editor.onInsertText = { _, replacement in
            seen = replacement
            return .allow
        }

        let allowed = editor.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 5, length: 0),
            replacementString: "!"
        )

        #expect(allowed)
        #expect(seen == "!")
    }

    @MainActor
    @Test("onInsertText .reject blocks the insertion")
    func onInsertTextRejectsKeystroke() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        editor.setMarkdown("hello")
        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        editor.onInsertText = { _, replacement in
            replacement == "/" ? .reject : .allow
        }

        let allowed = editor.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 5, length: 0),
            replacementString: "/"
        )

        #expect(allowed == false)
        #expect(textView.string == "hello")
    }

    @MainActor
    @Test("onInsertText .replace performs the substitution and moves the caret")
    func onInsertTextReplacesText() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        editor.setMarkdown("foo bar")
        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.setSelectedRange(NSRange(location: 3, length: 0))

        editor.onInsertText = { _, replacement in
            replacement == "-" ? .replace("—") : .allow
        }

        let allowed = editor.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 3, length: 0),
            replacementString: "-"
        )

        #expect(allowed == false)
        #expect(textView.string == "foo— bar")
        #expect(textView.selectedRange().location == 3 + ("—" as NSString).length)
    }

    @MainActor
    @Test("setMarkdown(_:) does not trigger onInsertText")
    func setMarkdownDoesNotTriggerHook() {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        var hookCalled = false
        editor.onInsertText = { _, _ in
            hookCalled = true
            return .allow
        }
        editor.setMarkdown("programmatic content")
        #expect(hookCalled == false)
    }

    @MainActor
    @Test("onInsertText is skipped during IME composition")
    func hookSkippedDuringIMEComposition() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        editor.setMarkdown("hello")
        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        // Start an IME composition. NSTextView conforms to NSTextInputClient.
        textView.setMarkedText(
            "拼",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: 5, length: 0)
        )
        #expect(textView.hasMarkedText())

        var hookCalled = false
        editor.onInsertText = { _, _ in
            hookCalled = true
            return .reject
        }

        let allowed = editor.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 5, length: 1),
            replacementString: "拼"
        )

        // Hook must be skipped so IME commits aren't surfaced as ad-hoc input.
        #expect(hookCalled == false)
        #expect(allowed == true)

        textView.unmarkText()
    }

    @MainActor
    @Test("setSelection clamps to text length")
    func setSelectionClampsToTextLength() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        editor.setMarkdown("hi")

        editor.setSelection(NSRange(location: 999, length: 999))

        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        #expect(textView.selectedRange().location <= 2)
        #expect(textView.selectedRange().upperBound <= 2)
    }

    @MainActor
    @Test("setSelection delivers exactly one onSelectionChange callback")
    func setSelectionFiresSingleCallback() {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        editor.setMarkdown("hello world")
        var callbackCount = 0
        editor.onSelectionChange = { _ in callbackCount += 1 }

        editor.setSelection(NSRange(location: 5, length: 0))

        #expect(callbackCount == 1)
    }

    @MainActor
    @Test("scrollToRange brings the target glyph into the viewport")
    func scrollToRangeBringsTargetIntoView() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 72))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 72),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editor
        editor.layoutSubtreeIfNeeded()

        let source = (1 ... 80).map { "line \($0)" }.joined(separator: "\n")
        editor.setMarkdown(source)

        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        try textView.layoutManager?.ensureLayout(for: #require(textView.textContainer))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let lateRange = ((textView.string as NSString).range(of: "line 75"))
        #expect(lateRange.location != NSNotFound)
        editor.scrollToRange(lateRange, animated: false)
        try textView.layoutManager?.ensureLayout(for: #require(textView.textContainer))

        #expect(scrollView.contentView.bounds.origin.y > 0)
    }

    @MainActor
    @Test("currentCaretRect returns a finite rect after layout")
    func caretRectIsFiniteAfterLayout() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editor
        editor.layoutSubtreeIfNeeded()
        editor.setMarkdown("hello world")
        editor.setSelection(NSRange(location: 5, length: 0))

        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        try textView.layoutManager?.ensureLayout(for: #require(textView.textContainer))

        let rect = try #require(editor.currentCaretRect)
        #expect(!rect.isNull)
        #expect(!rect.isInfinite)
        #expect(rect.height > 0)
    }

    @MainActor
    @Test("currentCaretRect handles empty document")
    func caretRectHandlesEmptyDocument() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editor
        editor.layoutSubtreeIfNeeded()
        editor.setMarkdown("")

        let rect = try #require(editor.currentCaretRect)
        #expect(rect.height > 0)
        #expect(!rect.isNull)
    }

    @MainActor
    @Test("currentCaretRect handles caret at end-of-document after newline")
    func caretRectHandlesEndOfDocument() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editor
        editor.layoutSubtreeIfNeeded()
        editor.setMarkdown("hello\n")
        let endLocation = ("hello\n" as NSString).length
        editor.setSelection(NSRange(location: endLocation, length: 0))

        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        try textView.layoutManager?.ensureLayout(for: #require(textView.textContainer))

        let rect = try #require(editor.currentCaretRect)
        #expect(rect.height > 0)
        #expect(!rect.isNull)
    }

    @MainActor
    @Test("visibleNSRange covers a non-empty slice of the document")
    func visibleRangeNonEmpty() throws {
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editor
        editor.layoutSubtreeIfNeeded()
        let source = (1 ... 30).map { "line \($0)" }.joined(separator: "\n")
        editor.setMarkdown(source)
        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        try textView.layoutManager?.ensureLayout(for: #require(textView.textContainer))

        let range = try #require(editor.visibleNSRange)
        #expect(range.length > 0)
    }
}

// MARK: - MarkdownEditorProxyAttachmentTests

@Suite("MarkdownEditorProxy attachment lifetime")
struct MarkdownEditorProxyAttachmentTests {
    @MainActor
    @Test("Proxy methods are safe when no view is attached")
    func proxyMethodsSafeWithoutAttachedView() {
        let proxy = MarkdownEditorProxy()
        // No view attached → calls should be silent no-ops.
        proxy.scrollToRange(NSRange(location: 0, length: 1))
        proxy.setSelection(NSRange(location: 0, length: 0))
        #expect(proxy.caretRect == nil)
        #expect(proxy.visibleRange == nil)
    }
}
#endif

#if canImport(UIKit)
import MarkdownPlatformView
import UIKit

// MARK: - MarkdownEditorProxyTests (iOS)

@Suite("MarkdownEditor public API (iOS proxy + onInsertText)")
struct MarkdownEditorProxyiOSTests {
    @MainActor
    @Test("iOS onInsertText .allow lets the keystroke through")
    func onInsertTextAllowsByDefault() {
        let editor = MarkdownEditorTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        editor.setMarkdown("hello")
        editor.selectedRange = NSRange(location: 5, length: 0)

        var seen: String?
        editor.onInsertText = { _, replacement in
            seen = replacement
            return .allow
        }

        let allowed = editor.textView(
            editor,
            shouldChangeTextIn: NSRange(location: 5, length: 0),
            replacementText: "!"
        )

        #expect(allowed)
        #expect(seen == "!")
    }

    @MainActor
    @Test("iOS onInsertText .reject blocks the insertion")
    func onInsertTextRejectsKeystroke() {
        let editor = MarkdownEditorTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        editor.setMarkdown("hello")
        editor.selectedRange = NSRange(location: 5, length: 0)

        editor.onInsertText = { _, replacement in
            replacement == "/" ? .reject : .allow
        }

        let allowed = editor.textView(
            editor,
            shouldChangeTextIn: NSRange(location: 5, length: 0),
            replacementText: "/"
        )

        #expect(allowed == false)
        #expect(editor.text == "hello")
    }

    @MainActor
    @Test("iOS onInsertText .replace performs the substitution and moves the caret")
    func onInsertTextReplacesText() {
        let editor = MarkdownEditorTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        editor.setMarkdown("foo bar")
        editor.selectedRange = NSRange(location: 3, length: 0)

        editor.onInsertText = { _, replacement in
            replacement == "-" ? .replace("—") : .allow
        }

        let allowed = editor.textView(
            editor,
            shouldChangeTextIn: NSRange(location: 3, length: 0),
            replacementText: "-"
        )

        #expect(allowed == false)
        #expect(editor.text == "foo— bar")
        #expect(editor.selectedRange.location == 3 + ("—" as NSString).length)
    }

    @MainActor
    @Test("iOS setMarkdown(_:) does not trigger onInsertText")
    func setMarkdownDoesNotTriggerHook() {
        let editor = MarkdownEditorTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        var hookCalled = false
        editor.onInsertText = { _, _ in
            hookCalled = true
            return .allow
        }
        editor.setMarkdown("programmatic content")
        #expect(hookCalled == false)
    }

    @MainActor
    @Test("iOS setSelection clamps to text length and fires one callback")
    func setSelectionClampsAndFiresOnce() {
        let editor = MarkdownEditorTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        editor.setMarkdown("hello world")
        var callbackCount = 0
        editor.onSelectionChange = { _ in callbackCount += 1 }

        editor.setSelection(NSRange(location: 999, length: 999))

        #expect(editor.selectedRange.location <= 11)
        #expect(editor.selectedRange.upperBound <= 11)
        #expect(callbackCount == 1)
    }

    @MainActor
    @Test("iOS scrollToRange brings the target glyph into the viewport")
    func scrollToRangeBringsTargetIntoView() {
        let editor = MarkdownEditorTextView(frame: CGRect(x: 0, y: 0, width: 240, height: 72))
        editor.layoutIfNeeded()
        let source = (1 ... 80).map { "line \($0)" }.joined(separator: "\n")
        editor.setMarkdown(source)
        editor.layoutManager.ensureLayout(for: editor.textContainer)
        editor.contentOffset = .zero

        let lateRange = (editor.text as NSString).range(of: "line 75")
        #expect(lateRange.location != NSNotFound)
        editor.scrollToRange(lateRange, animated: false)
        editor.layoutManager.ensureLayout(for: editor.textContainer)

        #expect(editor.contentOffset.y > 0)
    }

    @MainActor
    @Test("iOS currentCaretRect returns a finite rect")
    func caretRectIsFinite() throws {
        let editor = MarkdownEditorTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        editor.layoutIfNeeded()
        editor.setMarkdown("hello world")
        editor.setSelection(NSRange(location: 5, length: 0))
        editor.layoutManager.ensureLayout(for: editor.textContainer)

        let rect = try #require(editor.currentCaretRect)
        #expect(!rect.isNull)
        #expect(!rect.isInfinite)
        #expect(rect.height > 0)
    }

    @MainActor
    @Test("iOS visibleNSRange covers a non-empty slice of the document")
    func visibleRangeNonEmpty() throws {
        let editor = MarkdownEditorTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        editor.layoutIfNeeded()
        let source = (1 ... 30).map { "line \($0)" }.joined(separator: "\n")
        editor.setMarkdown(source)
        editor.layoutManager.ensureLayout(for: editor.textContainer)

        let range = try #require(editor.visibleNSRange)
        #expect(range.length > 0)
    }
}
#endif
