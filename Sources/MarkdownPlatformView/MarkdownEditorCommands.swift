import Foundation

// MARK: - MarkdownEditorSelection

public struct MarkdownEditorSelection: Equatable, Sendable {
    public init(location: Int, length: Int = 0) {
        self.location = location
        self.length = length
    }

    public init(_ range: NSRange) {
        self.location = range.location
        self.length = range.length
    }

    public var location: Int
    public var length: Int

    public var nsRange: NSRange {
        NSRange(location: self.location, length: self.length)
    }
}

// MARK: - MarkdownEditorOptions

public struct MarkdownEditorOptions: Equatable, Sendable {
    public init(
        isEditable: Bool = true,
        isScrollEnabled: Bool = true,
        autocorrectionDisabled: Bool = true,
        smartQuotesEnabled: Bool = false,
        smartDashesEnabled: Bool = false
    ) {
        self.isEditable = isEditable
        self.isScrollEnabled = isScrollEnabled
        self.autocorrectionDisabled = autocorrectionDisabled
        self.smartQuotesEnabled = smartQuotesEnabled
        self.smartDashesEnabled = smartDashesEnabled
    }

    public static let `default` = MarkdownEditorOptions()

    public var isEditable: Bool
    public var isScrollEnabled: Bool
    public var autocorrectionDisabled: Bool
    public var smartQuotesEnabled: Bool
    public var smartDashesEnabled: Bool
}

// MARK: - MarkdownEditorEditResult

public struct MarkdownEditorEditResult: Equatable, Sendable {
    public init(text: String, selectedRange: NSRange) {
        self.text = text
        self.selectedRange = selectedRange
    }

    public var text: String
    public var selectedRange: NSRange
}

// MARK: - MarkdownEditorCommands

public enum MarkdownEditorCommands {
    private struct LineContext {
        let lineRange: NSRange
        let contentRange: NSRange
        let line: String

        var fullLineLocalRange: NSRange {
            NSRange(location: 0, length: (self.line as NSString).length)
        }

        func substring(_ range: NSRange) -> String {
            (self.line as NSString).substring(with: range)
        }
    }

    public static func insertNewline(in text: String, selection: NSRange) -> MarkdownEditorEditResult? {
        guard selection.length == 0 else {
            return nil
        }
        let nsText = text as NSString
        let context = self.lineContext(in: nsText, selection: selection)
        guard selection.location == context.contentRange.upperBound else {
            return nil
        }

        if let match = unorderedListRegex.firstMatch(in: context.line, range: context.fullLineLocalRange) {
            return self.continueList(
                in: text,
                selection: selection,
                context: context,
                indent: context.substring(match.range(at: 1)),
                marker: context.substring(match.range(at: 2)),
                taskMarker: match.range(at: 3).location != NSNotFound ? context.substring(match.range(at: 3)) : nil,
                content: context.substring(match.range(at: 4))
            )
        }

        if let match = orderedListRegex.firstMatch(in: context.line, range: context.fullLineLocalRange) {
            let indent = context.substring(match.range(at: 1))
            let number = Int(context.substring(match.range(at: 2))) ?? 1
            let delimiter = context.substring(match.range(at: 3))
            let taskMarker = match.range(at: 4).location != NSNotFound ? context.substring(match.range(at: 4)) : nil
            let content = context.substring(match.range(at: 5))
            return self.continueList(
                in: text,
                selection: selection,
                context: context,
                indent: indent,
                marker: "\(number + 1)\(delimiter)",
                taskMarker: taskMarker,
                content: content
            )
        }

        return nil
    }

    public static func indentSelection(
        in text: String,
        selection: NSRange,
        indentUnit: String = "    "
    )
        -> MarkdownEditorEditResult
    {
        let nsText = text as NSString
        let selection = selection.clamped(to: nsText.length)
        let selectedLines = self.lineBlockRange(in: nsText, selection: selection)
        let lineStarts = self.lineStartOffsets(in: nsText, range: selectedLines)

        let output = NSMutableString(string: text)
        for start in lineStarts.reversed() {
            output.insert(indentUnit, at: start)
        }

        let indentLength = (indentUnit as NSString).length
        let insertedBeforeSelectionStart = lineStarts.count(where: { start in
            selection.length == 0 ? start <= selection.location : start < selection.location
        }) * indentLength
        let insertedBeforeSelectionEnd = lineStarts.count(where: { $0 < selection.upperBound }) * indentLength
        let newLocation = selection.location + insertedBeforeSelectionStart
        let newUpperBound = selection.upperBound + insertedBeforeSelectionEnd
        let newSelection = NSRange(
            location: newLocation,
            length: max(0, newUpperBound - newLocation)
        )
        return MarkdownEditorEditResult(text: output as String, selectedRange: newSelection)
    }

    public static func outdentSelection(
        in text: String,
        selection: NSRange,
        indentUnit: String = "    "
    )
        -> MarkdownEditorEditResult
    {
        let nsText = text as NSString
        let selection = selection.clamped(to: nsText.length)
        let selectedLines = self.lineBlockRange(in: nsText, selection: selection)
        let lineStarts = self.lineStartOffsets(in: nsText, range: selectedLines)

        var output = text
        var removedBeforeSelectionStart = 0
        var removedBeforeSelectionEnd = 0

        for start in lineStarts.reversed() {
            let currentNSString = output as NSString
            let currentLineRange = currentNSString.lineRange(for: NSRange(location: start, length: 0))
            let contentRange = self.trimTrailingNewlines(in: currentNSString, range: currentLineRange)
            let local = NSRange(location: start, length: contentRange.length)
            let line = currentNSString.substring(with: local)
            let removed = self.removableIndentLength(in: line, preferredUnit: indentUnit)
            guard removed > 0 else {
                continue
            }

            let swiftRange = Range(NSRange(location: start, length: removed), in: output)!
            output.removeSubrange(swiftRange)

            if start < selection.location {
                removedBeforeSelectionStart += removed
            }
            if start < selection.upperBound {
                removedBeforeSelectionEnd += removed
            }
        }

        let newLocation = max(0, selection.location - removedBeforeSelectionStart)
        let newUpperBound = max(newLocation, selection.upperBound - removedBeforeSelectionEnd)
        let newLength = max(0, newUpperBound - newLocation)
        return MarkdownEditorEditResult(text: output, selectedRange: NSRange(location: newLocation, length: newLength))
    }

    public static func toggleTaskList(in text: String, selection: NSRange) -> MarkdownEditorEditResult? {
        let nsText = text as NSString
        let context = self.lineContext(in: nsText, selection: selection)

        if let existing = taskListRegex.firstMatch(in: context.line, range: context.fullLineLocalRange) {
            let marker = context.substring(existing.range(at: 1)).lowercased() == "x" ? " " : "x"
            return self.replacing(
                in: text,
                range: self.shifted(existing.range(at: 1), by: context.contentRange.location),
                with: marker,
                selection: selection,
                cursorDelta: 0
            )
        }

        if let match = unorderedListRegex.firstMatch(in: context.line, range: context.fullLineLocalRange) {
            let location = context.contentRange.location + match.range(at: 2).upperBound + 1
            return self.replacing(
                in: text,
                range: NSRange(location: location, length: 0),
                with: "[ ] ",
                selection: selection,
                cursorDelta: 4
            )
        }

        if let match = orderedListRegex.firstMatch(in: context.line, range: context.fullLineLocalRange) {
            let location = context.contentRange.location + match.range(at: 3).upperBound + 1
            return self.replacing(
                in: text,
                range: NSRange(location: location, length: 0),
                with: "[ ] ",
                selection: selection,
                cursorDelta: 4
            )
        }

        return nil
    }

    public static func wrapSelection(
        in text: String,
        selection: NSRange,
        prefix: String,
        suffix: String,
        placeholder: String = ""
    )
        -> MarkdownEditorEditResult?
    {
        guard let selectedTextRange = Range(selection, in: text) else {
            return nil
        }
        let selectedText = String(text[selectedTextRange])
        let insertedContent = selection.length == 0 ? placeholder : selectedText
        let replacement = prefix + insertedContent + suffix

        var output = text
        output.replaceSubrange(selectedTextRange, with: replacement)

        let prefixUTF16Len = (prefix as NSString).length
        let newSelection = if selection.length == 0 {
            NSRange(location: selection.location + prefixUTF16Len, length: (insertedContent as NSString).length)
        } else {
            NSRange(location: selection.location + prefixUTF16Len, length: selection.length)
        }
        return MarkdownEditorEditResult(text: output, selectedRange: newSelection)
    }

    private static let unorderedListRegex = try! NSRegularExpression(
        pattern: #"^(\s*)([-+*])\s+(\[[ xX]\]\s+)?(.*)$"#
    )
    private static let orderedListRegex = try! NSRegularExpression(
        pattern: #"^(\s*)(\d+)([.)])\s+(\[[ xX]\]\s+)?(.*)$"#
    )
    private static let taskListRegex = try! NSRegularExpression(
        pattern: #"\[([ xX])\]"#
    )

    private static func continueList(
        in text: String,
        selection: NSRange,
        context: LineContext,
        indent: String,
        marker: String,
        taskMarker: String?,
        content: String
    )
        -> MarkdownEditorEditResult
    {
        let trimmedContent = content.trimmingCharacters(in: .whitespaces)
        if trimmedContent.isEmpty {
            let hadLineTerminator = context.lineRange.length > context.contentRange.length
            let replacement = hadLineTerminator ? indent : indent + "\n"
            let newCursor = context.lineRange.location + (replacement as NSString).length
            return self.replacing(
                in: text,
                range: context.contentRange,
                with: replacement,
                selection: selection,
                forcedSelection: NSRange(location: newCursor, length: 0)
            )
        }

        let continuedTaskMarker = taskMarker == nil ? "" : "[ ] "
        let insertion = "\n\(indent)\(marker) \(continuedTaskMarker)"
        return self.replacing(
            in: text,
            range: selection,
            with: insertion,
            selection: selection,
            forcedSelection: NSRange(location: selection.location + (insertion as NSString).length, length: 0)
        )
    }

    private static func replacing(
        in text: String,
        range: NSRange,
        with replacement: String,
        selection: NSRange,
        cursorDelta: Int = 0,
        forcedSelection: NSRange? = nil
    )
        -> MarkdownEditorEditResult
    {
        guard let swiftRange = Range(range, in: text) else {
            return MarkdownEditorEditResult(text: text, selectedRange: selection)
        }
        var output = text
        output.replaceSubrange(swiftRange, with: replacement)

        let newSelection = forcedSelection ?? NSRange(
            location: selection.location + replacement.count - range.length + cursorDelta,
            length: selection.length
        )
        return MarkdownEditorEditResult(text: output, selectedRange: newSelection)
    }

    private static func lineContext(in text: NSString, selection: NSRange) -> LineContext {
        let safeLocation = min(max(0, selection.location), text.length)
        let lineRange = text.lineRange(for: NSRange(location: safeLocation, length: 0))
        let contentRange = self.trimTrailingNewlines(in: text, range: lineRange)
        let line = text.substring(with: contentRange)
        return LineContext(lineRange: lineRange, contentRange: contentRange, line: line)
    }

    private static func lineBlockRange(in text: NSString, selection: NSRange) -> NSRange {
        let safeSelection = selection.clamped(to: text.length)
        let start = safeSelection.location
        let end = safeSelection.upperBound
        let firstLine = text.lineRange(for: NSRange(location: start, length: 0))
        if end == start {
            return firstLine
        }
        let lastLocation = max(0, end - 1)
        let lastLine = text.lineRange(for: NSRange(location: lastLocation, length: 0))
        return NSUnionRange(firstLine, lastLine)
    }

    private static func lineStartOffsets(in text: NSString, range: NSRange) -> [Int] {
        var offsets: [Int] = []
        var current = range.location
        while current < range.upperBound {
            offsets.append(current)
            let line = text.lineRange(for: NSRange(location: current, length: 0))
            let next = line.upperBound
            if next <= current {
                break
            }
            current = next
        }
        if offsets.isEmpty {
            offsets.append(range.location)
        }
        return offsets
    }

    private static func removableIndentLength(in line: String, preferredUnit: String) -> Int {
        if line.hasPrefix(preferredUnit) {
            return preferredUnit.count
        }
        if line.hasPrefix("\t") {
            return 1
        }
        let spaces = line.prefix(while: { $0 == " " }).count
        return min(spaces, preferredUnit.count)
    }

    private static func trimTrailingNewlines(in text: NSString, range: NSRange) -> NSRange {
        var result = range
        while result.length > 0 {
            let scalar = text.character(at: result.location + result.length - 1)
            if scalar == 10 || scalar == 13 {
                result.length -= 1
            } else {
                break
            }
        }
        return result
    }

    private static func shifted(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }
}
