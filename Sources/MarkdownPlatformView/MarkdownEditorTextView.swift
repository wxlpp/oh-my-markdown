import Foundation
import MarkdownRenderKit

private func mergeHighlightRanges(_ lhs: NSRange?, _ rhs: NSRange) -> NSRange {
    guard let lhs else {
        return rhs
    }
    return NSUnionRange(lhs, rhs)
}

#if canImport(UIKit)
import UIKit

@MainActor
public final class MarkdownEditorTextView: UITextView, UITextViewDelegate {
    override public init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        self.commonInit()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("Use init(frame:textContainer:)")
    }

    override public var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(self.handleTabKey)),
            UIKeyCommand(input: "\t", modifierFlags: [.shift], action: #selector(self.handleShiftTabKey)),
            UIKeyCommand(input: "b", modifierFlags: [.command], action: #selector(self.handleBoldCommand)),
            UIKeyCommand(input: "i", modifierFlags: [.command], action: #selector(self.handleItalicCommand)),
            UIKeyCommand(input: "k", modifierFlags: [.command], action: #selector(self.handleLinkCommand)),
            UIKeyCommand(input: "c", modifierFlags: [.command, .shift], action: #selector(self.handleCodeCommand)),
            UIKeyCommand(input: "x", modifierFlags: [.command, .shift], action: #selector(self.handleTaskCommand)),
            UIKeyCommand(input: "z", modifierFlags: [.command], action: #selector(self.handleUndoCommand)),
            UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(self.handleRedoCommand)),
        ]
    }

    public var onTextChange: ((String) -> Void)?
    public var onSelectionChange: ((MarkdownEditorSelection) -> Void)?

    /// Called before the editor applies a user-driven text change.
    ///
    /// The hook fires for any non-programmatic edit that flows through
    /// `shouldChangeTextIn`: typing, paste, deletion (empty replacement),
    /// auto-correct, drag-drop. Filter on `range`/`replacement` if you only
    /// care about a subset (e.g. slash-command insertions where
    /// `replacement == "/"`).
    ///
    /// Return `.allow` to let the editor proceed, `.reject` to drop the
    /// change, or `.replace(_:)` to substitute different text. The editor
    /// performs the replacement itself so undo stays atomic.
    ///
    /// Skipped while an IME composition is in flight so marked-text commits
    /// don't leak into application code as ad-hoc keystrokes.
    public var onInsertText: ((NSRange, String) -> MarkdownEditorInputAction)?

    public var renderStyle: RenderStyle = .default {
        didSet {
            guard !self.renderStyle.isSemanticallyEqual(to: oldValue) else {
                return
            }
            self.applyCurrentHighlighting()
        }
    }

    public var editorOptions: MarkdownEditorOptions = .default {
        didSet { self.applyOptions() }
    }

    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(self.undo(_:)) {
            return undoManager?.canUndo == true
        }
        if action == #selector(self.redo(_:)) {
            return undoManager?.canRedo == true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    public func setMarkdown(_ text: String, selectedRange: NSRange? = nil) {
        guard self.text != text || selectedRange != nil else {
            return
        }
        self.isApplyingProgrammaticChange = true
        self.text = text
        self.applyCurrentHighlighting(preserving: selectedRange ?? self.selectedRange)
        self.isApplyingProgrammaticChange = false
    }

    // MARK: - Programmatic control

    /// Set the selection (or caret position) without scrolling.
    ///
    /// Fires `onSelectionChange` exactly once for the clamped target range
    /// (the delegate's own `textViewDidChangeSelection` path is suppressed
    /// for this call so callers don't see a double-fire).
    public func setSelection(_ range: NSRange) {
        let length = (text as NSString).length
        let clamped = range.clamped(to: length)
        self.isApplyingProgrammaticChange = true
        selectedRange = clamped
        self.isApplyingProgrammaticChange = false
        self.onSelectionChange?(MarkdownEditorSelection(clamped))
    }

    /// Scroll until `range` is visible.
    ///
    /// `animated` is honoured on UIKit (where the default scroll animates);
    /// on AppKit it is a no-op hint — `NSTextView.scrollRangeToVisible` never
    /// animates.
    public func scrollToRange(_ range: NSRange, animated: Bool = true) {
        self.scrollSelectionToVisible(range, animated: animated)
    }

    /// Caret rect for the current selection start, in the receiver's
    /// coordinate space. `nil` when the editor has no text or layout.
    public var currentCaretRect: CGRect? {
        guard
            let position = self.position(from: beginningOfDocument, offset: selectedRange.location) else {
            return nil
        }
        let rect = self.caretRect(for: position)
        guard !rect.isNull, !rect.isInfinite else {
            return nil
        }
        return rect
    }

    /// Approximate character range currently visible in the viewport.
    public var visibleNSRange: NSRange? {
        let visibleRect = bounds.offsetBy(dx: -textContainerInset.left, dy: -textContainerInset.top)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        guard glyphRange.length > 0 else {
            return nil
        }
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    @objc
    public func undo(_ sender: Any?) {
        undoManager?.undo()
        self.onTextChange?(text)
        self.onSelectionChange?(MarkdownEditorSelection(selectedRange))
    }

    @objc
    public func redo(_ sender: Any?) {
        undoManager?.redo()
        self.onTextChange?(text)
        self.onSelectionChange?(MarkdownEditorSelection(selectedRange))
    }

    public func textViewDidChange(_ textView: UITextView) {
        guard !self.isApplyingProgrammaticChange else {
            return
        }
        let selection = selectedRange
        let highlightRange = self.pendingHighlightRange ?? selection
        if self.isComposingText {
            self.pendingHighlightRange = mergeHighlightRanges(self.pendingHighlightRange, highlightRange)
        } else {
            self.pendingHighlightRange = nil
            self.applyIncrementalHighlighting(around: highlightRange, preserving: selection)
        }
        self.onTextChange?(text)
        self.onSelectionChange?(MarkdownEditorSelection(selection))
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        guard !self.isApplyingProgrammaticChange else {
            return
        }
        self.onSelectionChange?(MarkdownEditorSelection(selectedRange))
    }

    /// Suppresses the system action for a `.link` run, the iOS counterpart of the
    /// AppKit `clickedOnLink` backstop. This class *is* the text view on iOS, so a
    /// host can set `dataDetectorTypes` on it directly; that plus
    /// `isEditable = false` is system link activation with no policy behind it.
    public func textView(_: UITextView, primaryActionFor _: UITextItem, defaultAction _: UIAction) -> UIAction? {
        nil
    }

    public func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText: String
    )
        -> Bool {
        guard !self.isApplyingProgrammaticChange else {
            return true
        }
        // Skip the hook while IME composition is in flight so marked-text
        // commits don't leak into application code as ad-hoc keystrokes.
        if markedTextRange == nil, let hook = self.onInsertText {
            switch hook(range, replacementText) {
            case .allow:
                break
            case .reject:
                return false
            case .replace(let replacement):
                self.applyInterceptReplacement(in: range, with: replacement)
                return false
            }
        }
        if
            replacementText == "\n",
            let edit = MarkdownEditorCommands.insertNewline(in: text, selection: range) {
            self.apply(edit, highlightRange: edit.selectedRange)
            return false
        }
        if replacementText == "\t" {
            self.apply(MarkdownEditorCommands.indentSelection(in: text, selection: range), highlightRange: range)
            return false
        }
        self.pendingHighlightRange = mergeHighlightRanges(
            self.pendingHighlightRange,
            NSRange(location: range.location, length: (replacementText as NSString).length)
        )
        return true
    }

    private var isApplyingProgrammaticChange = false
    private var pendingHighlightRange: NSRange?
    private var scrollGeneration: UInt64 = 0

    private var isComposingText: Bool {
        markedTextRange != nil
    }

    private func commonInit() {
        delegate = self
        allowsEditingTextAttributes = false
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        textContainer.lineFragmentPadding = 0
        smartInsertDeleteType = .no
        self.applyOptions()
        self.applyCurrentHighlighting()
    }

    private func applyOptions() {
        isEditable = self.editorOptions.isEditable
        isScrollEnabled = self.editorOptions.isScrollEnabled
        autocorrectionType = self.editorOptions.autocorrectionDisabled ? .no : .default
        spellCheckingType = self.editorOptions.autocorrectionDisabled ? .no : .default
        smartQuotesType = self.editorOptions.smartQuotesEnabled ? .yes : .no
        smartDashesType = self.editorOptions.smartDashesEnabled ? .yes : .no
    }

    private var syntaxRevision: UInt64 = 0
    private(set) var syntaxTask: Task<Void, Never>?
    package var prepareSyntax: @Sendable ([SyntaxHighlightKey]) async -> [SyntaxHighlightKey: [SyntaxHighlightSpan]] = { keys in
        var spans: [SyntaxHighlightKey: [SyntaxHighlightSpan]] = [:]
        for key in keys {
            guard !Task.isCancelled else { return [:] }
            spans[key] = await SyntaxHighlightCache.shared.spans(for: key.code, language: key.language)
        }
        return spans
    }

    package func cancelSyntaxHighlighting() {
        self.syntaxRevision += 1
        self.syntaxTask?.cancel()
        self.syntaxTask = nil
    }

    private func scheduleSyntaxHighlighting() {
        self.cancelSyntaxHighlighting()
        let revision = self.syntaxRevision
        let source = self.text ?? ""
        let configuration = MarkdownRenderConfiguration(style: self.renderStyle).snapshot(generation: revision)
        let requests = MarkdownSourceHighlighter(configuration: configuration).syntaxRequests(for: source)
        guard !requests.isEmpty else { return }
        let prepare = self.prepareSyntax
        self.syntaxTask = Task { [weak self, prepare, source, configuration, requests] in
            let spans = await prepare(requests)
            guard !Task.isCancelled, let self, self.syntaxRevision == revision, self.text ?? "" == source else { return }
            self.syntaxTask = nil
            let highlighted = MarkdownSourceHighlighter(configuration: configuration).highlight(source, syntaxSpans: spans)
            self.isApplyingProgrammaticChange = true
            self.performWithoutUndoRegistration {
                self.textStorage.beginEditing()
                highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length)) { attributes, range, _ in
                    // `setAttributes`, not `addAttributes`: replacing wipes any
                    // `.link` a detector or a paste left behind. Don't relax it.
                    self.textStorage.setAttributes(attributes, range: range)
                }
                self.textStorage.endEditing()
            }
            self.isApplyingProgrammaticChange = false
        }
    }

    isolated deinit { syntaxTask?.cancel() }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        if self.window == nil { self.cancelSyntaxHighlighting() }
    }

    /// What makes this file's exemption from `check-link-activation.sh`'s text-view
    /// inventory safe: the highlighter styles links with `.foregroundColor` and
    /// never emits `.link`, so this storage holds nothing a text view would open.
    /// `isRichText = false` does *not* provide that — it governs user-applied
    /// attributes, not `setAttributedString`. Pinned by
    /// `theEditorStorageNeverCarriesALinkAttribute`.
    private func applyCurrentHighlighting(preserving selection: NSRange? = nil) {
        self.scheduleSyntaxHighlighting()
        let highlighted = MarkdownSourceHighlighter(style: renderStyle).highlight(text)
        let clampedSelection = (selection ?? selectedRange).clamped(to: highlighted.length)
        self.isApplyingProgrammaticChange = true
        self.performWithoutUndoRegistration {
            textStorage.beginEditing()
            textStorage.setAttributedString(highlighted)
            textStorage.endEditing()
        }
        selectedRange = clampedSelection
        typingAttributes = [
            .font: self.renderStyle.bodyFont,
            .foregroundColor: self.renderStyle.textColor,
        ]
        self.isApplyingProgrammaticChange = false
    }

    private func applyIncrementalHighlighting(around editedRange: NSRange, preserving selection: NSRange) {
        self.scheduleSyntaxHighlighting()
        let highlighter = MarkdownSourceHighlighter(style: renderStyle)
        let targetRange = highlighter.expandedHighlightRange(in: text, around: editedRange)
        guard targetRange.length > 0 else {
            self.applyCurrentHighlighting(preserving: selection)
            return
        }
        let currentText = text as NSString
        let targetText = currentText.substring(with: targetRange)
        let highlighted = highlighter.highlight(targetText)
        let clampedSelection = selection.clamped(to: currentText.length)

        self.isApplyingProgrammaticChange = true
        self.performWithoutUndoRegistration {
            textStorage.beginEditing()
            textStorage.setAttributes([:], range: targetRange)
            highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length), options: []) {
                attributes, range, _ in
                let adjustedRange = NSRange(location: targetRange.location + range.location, length: range.length)
                textStorage.setAttributes(attributes, range: adjustedRange)
            }
            textStorage.endEditing()
        }
        selectedRange = clampedSelection
        typingAttributes = [
            .font: self.renderStyle.bodyFont,
            .foregroundColor: self.renderStyle.textColor,
        ]
        self.isApplyingProgrammaticChange = false
    }

    private func performWithoutUndoRegistration(_ updates: () -> Void) {
        // UIKit manages its internal undo stack for UITextView edits. Manually
        // toggling registration on _UITextUndoManager causes runtime state
        // mismatches, so syntax highlighting updates stay on the normal path here.
        updates()
    }

    private func apply(_ edit: MarkdownEditorEditResult, highlightRange: NSRange? = nil) {
        let oldText = text ?? ""
        let oldSelection = selectedRange
        self.registerUndo(previousText: oldText, previousSelection: oldSelection)
        self.isApplyingProgrammaticChange = true
        text = edit.text
        let targetRange = highlightRange ?? edit.selectedRange
        self.applyIncrementalHighlighting(around: targetRange, preserving: edit.selectedRange)
        self.scrollSelectionToVisible(edit.selectedRange)
        self.isApplyingProgrammaticChange = false
        self.onTextChange?(text)
        self.onSelectionChange?(MarkdownEditorSelection(edit.selectedRange))
    }

    private func applyInterceptReplacement(in range: NSRange, with replacement: String) {
        let nsText = (text ?? "") as NSString
        let safeRange = range.clamped(to: nsText.length)
        let newText = nsText.replacingCharacters(in: safeRange, with: replacement) as String
        let replacementLength = (replacement as NSString).length
        let newSelection = NSRange(location: safeRange.location + replacementLength, length: 0)
        self.apply(
            MarkdownEditorEditResult(text: newText, selectedRange: newSelection),
            highlightRange: NSRange(location: safeRange.location, length: replacementLength)
        )
    }

    private func scrollSelectionToVisible(_ selection: NSRange, animated: Bool = true) {
        self.scrollGeneration &+= 1
        let generation = self.scrollGeneration

        let textLength = (text as NSString).length
        guard textLength > 0 else {
            return
        }

        if selection.upperBound >= textLength {
            self.scrollToDocumentEnd()
            // Re-pin to the bottom after layout settles, but only if no
            // newer scroll request has come in.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scrollGeneration == generation else {
                    return
                }
                self.scrollToDocumentEnd()
            }
            return
        }

        let location = min(selection.location, textLength - 1)
        let length = max(1, min(selection.length, textLength - location))
        let clamped = NSRange(location: location, length: length)
        if animated {
            // UITextView.scrollRangeToVisible carries the default scroll
            // animation when the receiver is laid out and visible.
            scrollRangeToVisible(clamped)
        } else {
            // scrollRectToVisible(_:animated:) is the only path that
            // deterministically disables animation (scrollRangeToVisible has
            // no animated parameter; UIView.performWithoutAnimation only
            // catches implicit animations, not the scroll view's own).
            //
            // boundingRect(forGlyphRange:in:) is unreliable until layout has
            // run — calling ensureLayout(for:) up front avoids returning an
            // empty rect when the editor is freshly populated or off-screen.
            layoutManager.ensureLayout(for: textContainer)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: clamped,
                actualCharacterRange: nil
            )
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let viewRect = rect.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
            scrollRectToVisible(viewRect, animated: false)
        }
    }

    private func scrollToDocumentEnd() {
        layoutManager.ensureLayout(for: textContainer)
        setNeedsLayout()
        layoutIfNeeded()

        let usedRect = layoutManager.usedRect(for: textContainer)
        let laidOutContentHeight = usedRect.height + textContainerInset.top + textContainerInset.bottom
        let documentHeight = max(contentSize.height, laidOutContentHeight)
        let minOffsetY = -adjustedContentInset.top
        let maxOffsetY = max(
            minOffsetY,
            documentHeight - bounds.height + adjustedContentInset.bottom
        )
        setContentOffset(CGPoint(x: contentOffset.x, y: maxOffsetY), animated: false)
    }

    private func registerUndo(previousText: String, previousSelection: NSRange) {
        undoManager?.registerUndo(withTarget: self) { target in
            let currentText = target.text ?? ""
            let currentSelection = target.selectedRange
            target.registerUndo(previousText: currentText, previousSelection: currentSelection)
            target.isApplyingProgrammaticChange = true
            target.text = previousText
            target.applyCurrentHighlighting(preserving: previousSelection)
            target.isApplyingProgrammaticChange = false
            target.onTextChange?(target.text)
            target.onSelectionChange?(MarkdownEditorSelection(previousSelection))
        }
    }

    private func applyWrap(prefix: String, suffix: String, placeholder: String = "") {
        guard
            let edit = MarkdownEditorCommands.wrapSelection(
                in: text,
                selection: selectedRange,
                prefix: prefix,
                suffix: suffix,
                placeholder: placeholder
            ) else {
            return
        }
        self.apply(edit)
    }

    @objc
    private func handleTabKey() {
        self.apply(
            MarkdownEditorCommands.indentSelection(in: text, selection: selectedRange),
            highlightRange: selectedRange
        )
    }

    @objc
    private func handleShiftTabKey() {
        self.apply(
            MarkdownEditorCommands.outdentSelection(in: text, selection: selectedRange),
            highlightRange: selectedRange
        )
    }

    @objc
    private func handleBoldCommand() {
        self.applyWrap(prefix: "**", suffix: "**")
    }

    @objc
    private func handleItalicCommand() {
        self.applyWrap(prefix: "*", suffix: "*")
    }

    @objc
    private func handleLinkCommand() {
        self.applyWrap(prefix: "[", suffix: "](https://)", placeholder: "text")
    }

    @objc
    private func handleCodeCommand() {
        self.applyWrap(prefix: "`", suffix: "`")
    }

    @objc
    private func handleTaskCommand() {
        guard let edit = MarkdownEditorCommands.toggleTaskList(in: text, selection: selectedRange) else {
            return
        }
        self.apply(edit, highlightRange: selectedRange)
    }

    @objc
    private func handleUndoCommand() {
        self.undo(nil)
    }

    @objc
    private func handleRedoCommand() {
        self.redo(nil)
    }
}

#elseif canImport(AppKit)
import AppKit

@MainActor
public final class MarkdownEditorTextView: NSView, NSTextViewDelegate {
    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.commonInit()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override public var acceptsFirstResponder: Bool {
        true
    }

    public var onTextChange: ((String) -> Void)?
    public var onSelectionChange: ((MarkdownEditorSelection) -> Void)?

    /// Called before the editor applies a user-driven text change.
    ///
    /// The hook fires for any non-programmatic edit that flows through
    /// `shouldChangeTextIn`: typing, paste, deletion (empty replacement),
    /// auto-correct, drag-drop. Filter on `range`/`replacement` if you only
    /// care about a subset (e.g. slash-command insertions where
    /// `replacement == "/"`).
    ///
    /// Return `.allow` to let the editor proceed, `.reject` to drop the
    /// change, or `.replace(_:)` to substitute different text. The editor
    /// performs the replacement itself so undo stays atomic.
    ///
    /// Skipped while an IME composition is in flight so marked-text commits
    /// don't leak into application code as ad-hoc keystrokes.
    public var onInsertText: ((NSRange, String) -> MarkdownEditorInputAction)?

    public var renderStyle: RenderStyle = .default {
        didSet {
            guard !self.renderStyle.isSemanticallyEqual(to: oldValue) else {
                return
            }
            self.applyCurrentHighlighting()
        }
    }

    public var editorOptions: MarkdownEditorOptions = .default {
        didSet { self.applyOptions() }
    }

    override public func layout() {
        super.layout()
        self.scrollView.frame = bounds
        self.updateTextViewLayoutGeometry()
    }

    override public func becomeFirstResponder() -> Bool {
        guard let window else {
            return self.textView.becomeFirstResponder()
        }
        return window.makeFirstResponder(self.textView)
    }

    override public func resignFirstResponder() -> Bool {
        self.textView.resignFirstResponder()
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        if self.textView.performKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc
    public func undo(_ sender: Any?) {
        self.textView.undoManager?.undo()
    }

    @objc
    public func redo(_ sender: Any?) {
        self.textView.undoManager?.redo()
    }

    public func setMarkdown(_ text: String, selectedRange: NSRange? = nil) {
        guard self.textView.string != text || selectedRange != nil else {
            return
        }
        self.isApplyingProgrammaticChange = true
        self.textView.string = text
        self.applyCurrentHighlighting(preserving: selectedRange ?? self.textView.selectedRange())
        self.isApplyingProgrammaticChange = false
    }

    // MARK: - Programmatic control

    /// Set the selection (or caret position) without scrolling.
    ///
    /// Fires `onSelectionChange` exactly once for the clamped target range
    /// (the delegate's own `textViewDidChangeSelection` path is suppressed
    /// for this call so callers don't see a double-fire).
    public func setSelection(_ range: NSRange) {
        let length = (self.textView.string as NSString).length
        let clamped = range.clamped(to: length)
        self.isApplyingProgrammaticChange = true
        self.textView.setSelectedRange(clamped)
        self.isApplyingProgrammaticChange = false
        self.onSelectionChange?(MarkdownEditorSelection(clamped))
    }

    /// Scroll until `range` is visible.
    ///
    /// `animated` is honoured on UIKit (where the default scroll animates);
    /// on AppKit it is a no-op hint — `NSTextView.scrollRangeToVisible` never
    /// animates.
    public func scrollToRange(_ range: NSRange, animated _: Bool = true) {
        self.scrollSelectionToVisible(range)
    }

    /// Caret rect for the current selection start, expressed in the
    /// receiver's (wrapper view's) coordinate space.
    public var currentCaretRect: CGRect? {
        guard let layoutManager = self.textView.layoutManager else {
            return nil
        }
        let inset = self.textView.textContainerInset
        let selection = self.textView.selectedRange()
        let numberOfChars = layoutManager.textStorage?.length ?? 0

        // Empty document or caret at/past the last glyph: use the layout
        // manager's "extra line fragment" (the trailing phantom line). Falls
        // back to body-font metrics if no layout has happened yet.
        if numberOfChars == 0 || selection.location >= numberOfChars {
            let extra = layoutManager.extraLineFragmentRect
            let height = extra.height > 0 ? extra.height : self.renderStyle.bodyFont.boundingRectForFont.height
            let caretInTextView = NSRect(
                x: extra.origin.x + inset.width,
                y: extra.origin.y + inset.height,
                width: 1,
                height: max(height, 1)
            )
            return self.textView.convert(caretInTextView, to: self)
        }

        let glyphIndex = layoutManager.glyphIndexForCharacter(at: selection.location)
        guard glyphIndex < layoutManager.numberOfGlyphs else {
            return nil
        }
        let lineFragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
        let caretInTextView = NSRect(
            x: lineFragment.origin.x + glyphLocation.x + inset.width,
            y: lineFragment.origin.y + inset.height,
            width: 1,
            height: lineFragment.height
        )
        return self.textView.convert(caretInTextView, to: self)
    }

    /// Approximate character range currently visible in the viewport.
    public var visibleNSRange: NSRange? {
        guard
            let layoutManager = self.textView.layoutManager,
            let textContainer = self.textView.textContainer else {
            return nil
        }
        let visible = self.scrollView.contentView.bounds
        let visibleInTextView = self.textView.convert(visible, from: self.scrollView.contentView)
        let inset = self.textView.textContainerInset
        let containerRect = visibleInTextView.offsetBy(dx: -inset.width, dy: -inset.height)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        guard glyphRange.length > 0 else {
            return nil
        }
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    public func textDidChange(_ notification: Notification) {
        guard !self.isApplyingProgrammaticChange else {
            return
        }
        let selection = self.textView.selectedRange()
        let highlightRange = self.pendingHighlightRange ?? selection
        if self.isComposingText {
            self.pendingHighlightRange = mergeHighlightRanges(self.pendingHighlightRange, highlightRange)
        } else {
            self.pendingHighlightRange = nil
            self.applyIncrementalHighlighting(around: highlightRange, preserving: selection)
        }
        self.onTextChange?(self.textView.string)
        self.onSelectionChange?(MarkdownEditorSelection(selection))
    }

    /// Consumes the click. This view shows raw markdown source, so no run in it
    /// may reach an opener — and `isRichText = false` does not prevent one from
    /// existing: the standard Edit > Substitutions > Smart Links menu item calls
    /// `toggleAutomaticLinkDetection` on a plain-text view, after which typing a
    /// URL puts a real `.link` run in the storage. Returning `true` means handled.
    public func textView(_: NSTextView, clickedOnLink _: Any, at _: Int) -> Bool {
        true
    }

    public func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    )
        -> Bool {
        if
            !self.isApplyingProgrammaticChange,
            !self.textView.hasMarkedText(),
            let hook = self.onInsertText,
            let replacement = replacementString {
            switch hook(affectedCharRange, replacement) {
            case .allow:
                break
            case .reject:
                return false
            case .replace(let substitute):
                self.applyInterceptReplacement(in: affectedCharRange, with: substitute)
                return false
            }
        }
        self.pendingHighlightRange = mergeHighlightRanges(
            self.pendingHighlightRange,
            NSRange(
                location: affectedCharRange.location,
                length: (replacementString as NSString?)?.length ?? 0
            )
        )
        return true
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard !self.isApplyingProgrammaticChange else {
            return
        }
        self.onSelectionChange?(MarkdownEditorSelection(self.textView.selectedRange()))
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if
            commandSelector == #selector(NSResponder.insertNewline(_:)),
            let edit = MarkdownEditorCommands.insertNewline(
                in: self.textView.string,
                selection: self.textView.selectedRange()
            ) {
            self.apply(edit, highlightRange: edit.selectedRange)
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            self.apply(
                MarkdownEditorCommands.indentSelection(
                    in: self.textView.string,
                    selection: self.textView.selectedRange()
                ),
                highlightRange: self.textView.selectedRange()
            )
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            self.apply(
                MarkdownEditorCommands.outdentSelection(
                    in: self.textView.string,
                    selection: self.textView.selectedRange()
                ),
                highlightRange: self.textView.selectedRange()
            )
            return true
        }
        return false
    }

    fileprivate func applyShortcut(prefix: String, suffix: String, placeholder: String = "") -> Bool {
        guard
            let edit = MarkdownEditorCommands.wrapSelection(
                in: textView.string,
                selection: textView.selectedRange(),
                prefix: prefix,
                suffix: suffix,
                placeholder: placeholder
            ) else {
            return false
        }
        self.apply(edit, highlightRange: self.textView.selectedRange())
        return true
    }

    fileprivate func toggleTaskShortcut() -> Bool {
        guard
            let edit = MarkdownEditorCommands.toggleTaskList(
                in: textView.string,
                selection: textView.selectedRange()
            ) else {
            return false
        }
        self.apply(edit, highlightRange: self.textView.selectedRange())
        return true
    }

    fileprivate func performUndoKeyCommand(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else {
            return false
        }
        if event.modifierFlags.contains(.shift) {
            self.redo(nil)
        } else {
            self.undo(nil)
        }
        return true
    }

    private let scrollView = NSScrollView()
    private let textView = PlatformEditorTextView()
    private var isApplyingProgrammaticChange = false
    private var pendingHighlightRange: NSRange?
    private var scrollGeneration: UInt64 = 0

    private var isComposingText: Bool {
        self.textView.hasMarkedText()
    }

    private func commonInit() {
        self.textView.owner = self
        self.textView.delegate = self
        self.textView.drawsBackground = false
        self.textView.isRichText = false
        self.textView.isHorizontallyResizable = false
        self.textView.isVerticallyResizable = true
        self.textView.minSize = NSSize(width: 0, height: self.scrollView.contentSize.height)
        self.textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        self.textView.autoresizingMask = [.width]
        self.textView.textContainerInset = NSSize(width: 0, height: 10)
        self.textView.textContainer?.widthTracksTextView = true
        self.textView.allowsUndo = true
        self.scrollView.borderType = .noBorder
        self.scrollView.drawsBackground = false
        self.scrollView.hasVerticalScroller = true
        self.scrollView.hasHorizontalScroller = false
        self.scrollView.autoresizingMask = [.width, .height]
        self.scrollView.documentView = self.textView
        addSubview(self.scrollView)
        self.updateTextViewLayoutGeometry()
        self.applyOptions()
        self.applyCurrentHighlighting()
    }

    private func updateTextViewLayoutGeometry() {
        let contentSize = self.scrollView.contentSize
        self.textView.minSize = NSSize(width: 0, height: contentSize.height)
        self.textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        self.textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private func applyOptions() {
        self.textView.isEditable = self.editorOptions.isEditable
        self.textView.isSelectable = true
        self.textView.isAutomaticQuoteSubstitutionEnabled = self.editorOptions.smartQuotesEnabled
        self.textView.isAutomaticDashSubstitutionEnabled = self.editorOptions.smartDashesEnabled
        self.textView.isContinuousSpellCheckingEnabled = !self.editorOptions.autocorrectionDisabled
        self.textView.isAutomaticLinkDetectionEnabled = false
        self.scrollView.hasVerticalScroller = self.editorOptions.isScrollEnabled
    }

    private var syntaxRevision: UInt64 = 0
    private(set) var syntaxTask: Task<Void, Never>?
    package var prepareSyntax: @Sendable ([SyntaxHighlightKey]) async -> [SyntaxHighlightKey: [SyntaxHighlightSpan]] = { keys in
        var spans: [SyntaxHighlightKey: [SyntaxHighlightSpan]] = [:]
        for key in keys {
            guard !Task.isCancelled else { return [:] }
            spans[key] = await SyntaxHighlightCache.shared.spans(for: key.code, language: key.language)
        }
        return spans
    }

    package func cancelSyntaxHighlighting() {
        self.syntaxRevision += 1
        self.syntaxTask?.cancel()
        self.syntaxTask = nil
    }

    private func scheduleSyntaxHighlighting() {
        self.cancelSyntaxHighlighting()
        let revision = self.syntaxRevision
        let source = self.textView.string
        let configuration = MarkdownRenderConfiguration(style: self.renderStyle).snapshot(generation: revision)
        let requests = MarkdownSourceHighlighter(configuration: configuration).syntaxRequests(for: source)
        guard !requests.isEmpty else { return }
        let prepare = self.prepareSyntax
        self.syntaxTask = Task { [weak self, prepare, source, configuration, requests] in
            let spans = await prepare(requests)
            guard !Task.isCancelled, let self, self.syntaxRevision == revision, self.textView.string == source else { return }
            self.syntaxTask = nil
            let highlighted = MarkdownSourceHighlighter(configuration: configuration).highlight(source, syntaxSpans: spans)
            self.isApplyingProgrammaticChange = true
            self.performWithoutUndoRegistration {
                self.textView.textStorage?.beginEditing()
                highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length)) { attributes, range, _ in
                    // `setAttributes`, not `addAttributes`: replacing wipes any
                    // `.link` a detector or a paste left behind. Don't relax it.
                    self.textView.textStorage?.setAttributes(attributes, range: range)
                }
                self.textView.textStorage?.endEditing()
            }
            self.isApplyingProgrammaticChange = false
        }
    }

    isolated deinit { syntaxTask?.cancel() }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window == nil { self.cancelSyntaxHighlighting() }
    }

    /// What makes this file's exemption from `check-link-activation.sh`'s text-view
    /// inventory safe: the highlighter styles links with `.foregroundColor` and
    /// never emits `.link`, so this storage holds nothing a text view would open.
    /// `isRichText = false` does *not* provide that — it governs user-applied
    /// attributes, not `setAttributedString`. Pinned by
    /// `theEditorStorageNeverCarriesALinkAttribute`.
    private func applyCurrentHighlighting(preserving selection: NSRange? = nil) {
        self.scheduleSyntaxHighlighting()
        let highlighted = MarkdownSourceHighlighter(style: renderStyle).highlight(self.textView.string)
        let clampedSelection = (selection ?? self.textView.selectedRange()).clamped(to: highlighted.length)
        self.isApplyingProgrammaticChange = true
        self.performWithoutUndoRegistration {
            self.textView.textStorage?.beginEditing()
            self.textView.textStorage?.setAttributedString(highlighted)
            self.textView.textStorage?.endEditing()
        }
        self.textView.setSelectedRange(clampedSelection)
        self.textView.insertionPointColor = self.renderStyle.textColor
        self.isApplyingProgrammaticChange = false
    }

    private func applyIncrementalHighlighting(around editedRange: NSRange, preserving selection: NSRange) {
        self.scheduleSyntaxHighlighting()
        let highlighter = MarkdownSourceHighlighter(style: renderStyle)
        let targetRange = highlighter.expandedHighlightRange(in: self.textView.string, around: editedRange)
        guard targetRange.length > 0 else {
            self.applyCurrentHighlighting(preserving: selection)
            return
        }
        let currentText = self.textView.string as NSString
        let targetText = currentText.substring(with: targetRange)
        let highlighted = highlighter.highlight(targetText)
        let clampedSelection = selection.clamped(to: currentText.length)

        self.isApplyingProgrammaticChange = true
        self.performWithoutUndoRegistration {
            self.textView.textStorage?.beginEditing()
            self.textView.textStorage?.setAttributes([:], range: targetRange)
            highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length), options: []) {
                attributes, range, _ in
                let adjustedRange = NSRange(location: targetRange.location + range.location, length: range.length)
                self.textView.textStorage?.setAttributes(attributes, range: adjustedRange)
            }
            self.textView.textStorage?.endEditing()
        }
        self.textView.setSelectedRange(clampedSelection)
        self.textView.insertionPointColor = self.renderStyle.textColor
        self.isApplyingProgrammaticChange = false
    }

    private func performWithoutUndoRegistration(_ updates: () -> Void) {
        guard let undoManager = textView.undoManager else {
            updates()
            return
        }
        let wasUndoRegistrationEnabled = undoManager.isUndoRegistrationEnabled
        if wasUndoRegistrationEnabled {
            undoManager.disableUndoRegistration()
        }
        updates()
        if wasUndoRegistrationEnabled {
            undoManager.enableUndoRegistration()
        }
    }

    private func apply(_ edit: MarkdownEditorEditResult, highlightRange: NSRange? = nil) {
        let oldText = self.textView.string
        let oldSelection = self.textView.selectedRange()
        self.registerUndo(previousText: oldText, previousSelection: oldSelection)
        self.isApplyingProgrammaticChange = true
        self.textView.string = edit.text
        let targetRange = highlightRange ?? edit.selectedRange
        self.applyIncrementalHighlighting(around: targetRange, preserving: edit.selectedRange)
        self.scrollSelectionToVisible(edit.selectedRange)
        self.isApplyingProgrammaticChange = false
        self.onTextChange?(self.textView.string)
        self.onSelectionChange?(MarkdownEditorSelection(edit.selectedRange))
    }

    private func applyInterceptReplacement(in range: NSRange, with replacement: String) {
        let nsText = self.textView.string as NSString
        let safeRange = range.clamped(to: nsText.length)
        let newText = nsText.replacingCharacters(in: safeRange, with: replacement) as String
        let replacementLength = (replacement as NSString).length
        let newSelection = NSRange(location: safeRange.location + replacementLength, length: 0)
        self.apply(
            MarkdownEditorEditResult(text: newText, selectedRange: newSelection),
            highlightRange: NSRange(location: safeRange.location, length: replacementLength)
        )
    }

    private func scrollSelectionToVisible(_ selection: NSRange) {
        self.scrollGeneration &+= 1
        let generation = self.scrollGeneration

        let textLength = (textView.string as NSString).length
        guard textLength > 0 else {
            return
        }

        if selection.upperBound >= textLength {
            self.scrollToDocumentEnd()
            // Re-pin to the bottom after layout settles, but only if no
            // newer scroll request has come in.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scrollGeneration == generation else {
                    return
                }
                self.scrollToDocumentEnd()
            }
            return
        }

        let location = min(selection.location, textLength - 1)
        let length = max(1, min(selection.length, textLength - location))
        self.textView.scrollRangeToVisible(NSRange(location: location, length: length))
    }

    private func scrollToDocumentEnd() {
        let textContainer = self.textView.textContainer
        if let textContainer {
            self.textView.layoutManager?.ensureLayout(for: textContainer)
        }
        self.textView.layoutSubtreeIfNeeded()
        self.scrollView.layoutSubtreeIfNeeded()

        let clipView = self.scrollView.contentView
        let usedHeight = textContainer.flatMap { self.textView.layoutManager?.usedRect(for: $0).height } ?? self
            .textView.bounds.height
        let documentHeight = max(
            textView.bounds.height,
            usedHeight + self.textView.textContainerInset.height * 2
        )
        let visibleHeight = clipView.bounds.height
        let targetY = self.textView.isFlipped ? max(0, documentHeight - visibleHeight) : 0
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetY))
        self.scrollView.reflectScrolledClipView(clipView)
    }

    private func registerUndo(previousText: String, previousSelection: NSRange) {
        self.textView.undoManager?.registerUndo(withTarget: self) { target in
            let currentText = target.textView.string
            let currentSelection = target.textView.selectedRange()
            target.registerUndo(previousText: currentText, previousSelection: currentSelection)
            target.isApplyingProgrammaticChange = true
            target.textView.string = previousText
            target.applyCurrentHighlighting(preserving: previousSelection)
            target.isApplyingProgrammaticChange = false
            target.onTextChange?(target.textView.string)
            target.onSelectionChange?(MarkdownEditorSelection(previousSelection))
        }
    }
}

private final class PlatformEditorTextView: NSTextView {
    override var undoManager: UndoManager? {
        super.undoManager ?? self.fallbackUndoManager
    }

    /// Standard Edit > Substitutions > Smart Links. Left as a no-op so the editor
    /// cannot start writing `.link` runs into a source buffer.
    override func toggleAutomaticLinkDetection(_: Any?) {}

    weak var owner: MarkdownEditorTextView?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z":
            return self.owner?.performUndoKeyCommand(with: event) ?? false
        case "b":
            return self.owner?.applyShortcut(prefix: "**", suffix: "**") ?? false
        case "i":
            return self.owner?.applyShortcut(prefix: "*", suffix: "*") ?? false
        case "k":
            return self.owner?.applyShortcut(prefix: "[", suffix: "](https://)", placeholder: "text") ?? false
        case "c" where event.modifierFlags.contains(.shift):
            return self.owner?.applyShortcut(prefix: "`", suffix: "`") ?? false
        case "x" where event.modifierFlags.contains(.shift):
            return self.owner?.toggleTaskShortcut() ?? false
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private let fallbackUndoManager = UndoManager()
}
#endif
