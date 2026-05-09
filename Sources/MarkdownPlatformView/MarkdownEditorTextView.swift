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

        public func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText: String
        )
            -> Bool
        {
            guard !self.isApplyingProgrammaticChange else {
                return true
            }
            if
                replacementText == "\n",
                let edit = MarkdownEditorCommands.insertNewline(in: text, selection: range)
            {
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

        private func applyCurrentHighlighting(preserving selection: NSRange? = nil) {
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

        private func scrollSelectionToVisible(_ selection: NSRange) {
            let textLength = (text as NSString).length
            guard textLength > 0 else {
                return
            }

            if selection.upperBound >= textLength {
                self.scrollToDocumentEnd()
                DispatchQueue.main.async { [weak self] in
                    self?.scrollToDocumentEnd()
                }
                return
            }

            let location = min(selection.location, textLength - 1)
            let length = max(1, min(selection.length, textLength - location))
            scrollRangeToVisible(NSRange(location: location, length: length))
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
                ) else
            {
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

        public func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        )
            -> Bool
        {
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
                )
            {
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
                ) else
            {
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
                ) else
            {
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
            self.scrollView.hasVerticalScroller = self.editorOptions.isScrollEnabled
        }

        private func applyCurrentHighlighting(preserving selection: NSRange? = nil) {
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

        private func scrollSelectionToVisible(_ selection: NSRange) {
            let textLength = (textView.string as NSString).length
            guard textLength > 0 else {
                return
            }

            if selection.upperBound >= textLength {
                self.scrollToDocumentEnd()
                DispatchQueue.main.async { [weak self] in
                    self?.scrollToDocumentEnd()
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
