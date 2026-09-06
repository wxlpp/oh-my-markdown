import Foundation
import MarkdownCore
import MarkdownRenderKit

#if canImport(UIKit)
import UIKit

// MARK: - Helper types for UITextInput

final class MarkdownTextPosition: UITextPosition {
    init(_ offset: Int) {
        self.offset = offset
    }

    let offset: Int
}

final class MarkdownTextRange: UITextRange {
    init(from: Int, to: Int) {
        self._start = MarkdownTextPosition(from)
        self._end = MarkdownTextPosition(to)
    }

    override var start: UITextPosition {
        self._start
    }

    override var end: UITextPosition {
        self._end
    }

    override var isEmpty: Bool {
        self._start.offset == self._end.offset
    }

    var nsRange: NSRange {
        NSRange(location: self._start.offset, length: self._end.offset - self._start.offset)
    }

    private let _start: MarkdownTextPosition
    private let _end: MarkdownTextPosition
}

final class MarkdownSelectionRect: UITextSelectionRect {
    init(_ rect: CGRect) {
        self._rect = rect
    }

    override var rect: CGRect {
        self._rect
    }

    override var writingDirection: NSWritingDirection {
        .leftToRight
    }

    override var containsStart: Bool {
        false
    }

    override var containsEnd: Bool {
        false
    }

    override var isVertical: Bool {
        false
    }

    private let _rect: CGRect
}

// MARK: - UITextInput

extension MarkdownLabelView: UITextInput {
    // MARK: UIKeyInput (required by UITextInput)

    public var hasText: Bool {
        self.documentLength > 0
    }

    // MARK: UITextInput delegate

    /// UITextInteraction sets this to receive selection-change notifications.
    public var inputDelegate: (any UITextInputDelegate)? {
        get { self._inputDelegate }
        set { self._inputDelegate = newValue }
    }

    public var selectedTextRange: UITextRange? {
        get {
            guard
                let sel = layoutManager.textSelections.first,
                let r = sel.textRanges.first else {
                return nil
            }
            return MarkdownTextRange(
                from: self.offsetOf(r.location),
                to: self.offsetOf(r.endLocation)
            )
        }
        set {
            self._inputDelegate?.selectionWillChange(self)
            guard
                let r = newValue as? MarkdownTextRange,
                let tr = makeTextRange(
                    from: r.nsRange.location,
                    to: NSMaxRange(r.nsRange)
                ) else {
                self.layoutManager.textSelections = []
                self._inputDelegate?.selectionDidChange(self)
                setNeedsDisplay()
                return
            }
            self.layoutManager.textSelections = [
                NSTextSelection(range: tr, affinity: .downstream, granularity: .character),
            ]
            self._inputDelegate?.selectionDidChange(self)
            setNeedsDisplay()
        }
    }

    public var markedTextRange: UITextRange? {
        nil
    }

    public var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil } set {}
    }

    public var beginningOfDocument: UITextPosition {
        MarkdownTextPosition(0)
    }

    public var endOfDocument: UITextPosition {
        MarkdownTextPosition(self.documentLength)
    }

    public var tokenizer: UITextInputTokenizer {
        UITextInputStringTokenizer(textInput: self)
    }

    public func insertText(_ text: String) { /* read-only */ }
    public func deleteBackward() { /* read-only */ }

    public func text(in range: UITextRange) -> String? {
        guard
            let r = range as? MarkdownTextRange,
            let str = contentStorage.attributedString?.string,
            NSMaxRange(r.nsRange) <= (str as NSString).length else {
            return nil
        }
        return (str as NSString).substring(with: r.nsRange)
    }

    public func replace(_ range: UITextRange, withText text: String) {}

    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    public func unmarkText() {}

    public func textRange(
        from fromPosition: UITextPosition,
        to toPosition: UITextPosition
    )
        -> UITextRange? {
        guard
            let a = fromPosition as? MarkdownTextPosition,
            let b = toPosition as? MarkdownTextPosition else {
            return nil
        }
        return MarkdownTextRange(from: min(a.offset, b.offset), to: max(a.offset, b.offset))
    }

    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let p = position as? MarkdownTextPosition else {
            return nil
        }
        return MarkdownTextPosition(max(0, min(p.offset + offset, self.documentLength)))
    }

    public func position(
        from position: UITextPosition,
        in direction: UITextLayoutDirection,
        offset: Int
    )
        -> UITextPosition? {
        let d = (direction == .right || direction == .down) ? offset : -offset
        return self.position(from: position, offset: d)
    }

    public func compare(
        _ position: UITextPosition,
        to other: UITextPosition
    )
        -> ComparisonResult {
        guard
            let a = position as? MarkdownTextPosition,
            let b = other as? MarkdownTextPosition else {
            return .orderedSame
        }
        if a.offset < b.offset {
            return .orderedAscending
        }
        if a.offset > b.offset {
            return .orderedDescending
        }
        return .orderedSame
    }

    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard
            let a = from as? MarkdownTextPosition,
            let b = toPosition as? MarkdownTextPosition else {
            return 0
        }
        return b.offset - a.offset
    }

    public func position(
        within range: UITextRange,
        farthestIn direction: UITextLayoutDirection
    )
        -> UITextPosition? {
        guard let r = range as? MarkdownTextRange else {
            return nil
        }
        return (direction == .left || direction == .up) ? r.start : r.end
    }

    public func characterRange(
        byExtending position: UITextPosition,
        in direction: UITextLayoutDirection
    )
        -> UITextRange? {
        guard let p = position as? MarkdownTextPosition else {
            return nil
        }
        switch direction {
        case .left, .up: return MarkdownTextRange(from: max(0, p.offset - 1), to: p.offset)
        default: return MarkdownTextRange(from: p.offset, to: min(self.documentLength, p.offset + 1))
        }
    }

    public func baseWritingDirection(
        for position: UITextPosition,
        in direction: UITextStorageDirection
    )
        -> NSWritingDirection {
        .natural
    }

    public func setBaseWritingDirection(
        _ writingDirection: NSWritingDirection,
        for range: UITextRange
    ) {}

    /// Geometry
    public func firstRect(for range: UITextRange) -> CGRect {
        guard
            let r = range as? MarkdownTextRange,
            let tr = makeTextRange(
                from: r.nsRange.location,
                to: NSMaxRange(r.nsRange)
            ) else {
            return .null
        }
        var result = CGRect.null
        self.layoutManager.enumerateTextSegments(in: tr, type: .standard, options: []) { _, frame, _, _ in
            result = frame
            return false
        }
        return result == .null ? .null : convert(result, to: nil)
    }

    public func caretRect(for position: UITextPosition) -> CGRect {
        guard
            let p = position as? MarkdownTextPosition,
            let loc = locationAt(p.offset) else {
            return .null
        }
        let zr = NSTextRange(location: loc)
        var result = CGRect.null
        self.layoutManager.enumerateTextSegments(in: zr, type: .selection, options: []) { _, frame, _, _ in
            result = CGRect(x: frame.minX, y: frame.minY, width: 2, height: frame.height)
            return false
        }
        return result
    }

    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard
            let r = range as? MarkdownTextRange,
            let tr = makeTextRange(
                from: r.nsRange.location,
                to: NSMaxRange(r.nsRange)
            ) else {
            return []
        }
        var rects: [MarkdownSelectionRect] = []
        self.layoutManager.enumerateTextSegments(in: tr, type: .highlight, options: []) { _, frame, _, _ in
            rects.append(MarkdownSelectionRect(frame))
            return true
        }
        return rects
    }

    /// Hit testing
    public func closestPosition(to point: CGPoint) -> UITextPosition? {
        let sels = self.layoutManager.textSelectionNavigation.textSelections(
            interactingAt: point,
            inContainerAt: self.contentStorage.documentRange.location,
            anchors: [],
            modifiers: [],
            selecting: false,
            bounds: CGRect(origin: .zero, size: self.textContainer.size)
        )
        guard let loc = sels.first?.textRanges.first?.location else {
            return self.beginningOfDocument
        }
        return MarkdownTextPosition(self.offsetOf(loc))
    }

    public func closestPosition(
        to point: CGPoint,
        within range: UITextRange
    )
        -> UITextPosition? {
        self.closestPosition(to: point)
    }

    public func characterRange(at point: CGPoint) -> UITextRange? {
        guard
            let pos = closestPosition(to: point) as? MarkdownTextPosition,
            pos.offset < documentLength else {
            return nil
        }
        return MarkdownTextRange(from: pos.offset, to: pos.offset + 1)
    }
}
#endif
