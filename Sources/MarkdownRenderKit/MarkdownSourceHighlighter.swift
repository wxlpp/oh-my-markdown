import Foundation
import MarkdownCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - MarkdownSourceHighlighter

/// Highlights Markdown source text for editable UITextView / NSTextView based editors.
///
/// This highlighter intentionally styles the source string itself instead of reusing the
/// rich read-only renderer. It keeps the editor model plain-text-first while still sharing
/// fonts, colors, and fenced code block syntax coloring with the rest of the package.
public struct MarkdownSourceHighlighter: Sendable {
    private struct CodeBlockMatch {
        let fullRange: NSRange
        let openingFenceRange: NSRange
        let bodyRange: NSRange
        let closingFenceRange: NSRange?
        let language: String?
        let languageRange: NSRange?
    }

    private struct FenceLineMatch {
        let marker: Character
        let count: Int
        let language: String?
        let languageRange: NSRange?
    }

    public init(style: RenderStyle = .default) {
        self.style = style
    }

    public var style: RenderStyle

    public func highlight(_ source: String) -> NSAttributedString {
        let text = source as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        let result = NSMutableAttributedString(string: source, attributes: baseAttributes())
        let codeBlocks = self.codeBlockMatches(in: source)

        for block in codeBlocks {
            self.applyCodeBlock(block, to: result, source: source)
        }

        self.applyLineHighlights(to: result, source: source, skipping: codeBlocks)
        self.applyInlineHighlights(to: result, source: source, skipping: codeBlocks)
        self.applyMathHighlights(to: result, source: source)

        // Preserve paragraph spacing while keeping editor typography compact.
        result.addAttribute(.paragraphStyle, value: self.paragraphStyle(), range: fullRange)
        return result
    }

    /// Expands an edited range to the minimum slice that should be re-highlighted.
    ///
    /// Outside fenced code blocks this returns the containing paragraph. When the edit
    /// occurs inside a fenced block, it expands to the entire block so language tokens
    /// remain consistent without rebuilding the whole document.
    public func expandedHighlightRange(in source: String, around editedRange: NSRange?) -> NSRange {
        let text = source as NSString
        guard text.length > 0 else {
            return NSRange(location: 0, length: 0)
        }
        guard let editedRange else {
            return NSRange(location: 0, length: text.length)
        }

        let clampedLocation = min(max(0, editedRange.location), text.length)
        let maxLength = text.length - clampedLocation
        let clampedLength = min(max(0, editedRange.length), maxLength)
        let clampedRange = NSRange(location: clampedLocation, length: clampedLength)
        let paragraphRange = text.paragraphRange(for: clampedRange)

        if
            let codeBlockRange = codeBlockMatches(in: source).first(where: {
                $0.fullRange.intersects(clampedRange) || $0.fullRange.intersects(paragraphRange)
            })?.fullRange {
            return codeBlockRange
        }

        return paragraphRange
    }

    private static let headingRegex = try! NSRegularExpression(pattern: #"(?m)^(#{1,6})(\s+.*)$"#)
    private static let blockquoteRegex = try! NSRegularExpression(pattern: #"(?m)^(\s{0,3}> ?)(.*)$"#)
    private static let unorderedListRegex = try! NSRegularExpression(pattern: #"(?m)^(\s{0,3}[-+*]\s+)"#)
    private static let orderedListRegex = try! NSRegularExpression(pattern: #"(?m)^(\s{0,3}\d+[.)]\s+)"#)
    private static let taskListRegex = try! NSRegularExpression(pattern: #"(?m)(\[[ xX]\])"#)
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"(?<!`)`([^`\n]+)`(?!`)"#)
    private static let strongRegex = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let emphasisRegex =
        try! NSRegularExpression(pattern: #"(?<!\*)\*(?=\S)(.+?)(?<=\S)\*(?!\*)|(?<!_)_(?=\S)(.+?)(?<=\S)_(?!_)"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[[^\]]+\]\([^\)]+\)"#)

    private static func fenceLineMatch(in line: String) -> FenceLineMatch? {
        let trimmedNewline = line.trimmingCharacters(in: .newlines)
        let indentCount = trimmedNewline.prefix(while: { $0 == " " }).count
        guard indentCount <= 3 else {
            return nil
        }

        let content = String(trimmedNewline.dropFirst(indentCount))
        guard let marker = content.first, marker == "`" || marker == "~" else {
            return nil
        }

        let markerCount = content.prefix(while: { $0 == marker }).count
        guard markerCount >= 3 else {
            return nil
        }

        let suffix = String(content.dropFirst(markerCount)).trimmingCharacters(in: .whitespaces)
        let language = suffix.isEmpty ? nil : suffix
        let languageRange = language.flatMap { token in
            trimmedNewline.range(of: token).map { NSRange($0, in: trimmedNewline) }
        }

        return FenceLineMatch(marker: marker, count: markerCount, language: language, languageRange: languageRange)
    }

    private static func isClosingFenceLine(_ line: String, marker: Character, minimumCount: Int) -> Bool {
        let trimmedNewline = line.trimmingCharacters(in: .newlines)
        let indentCount = trimmedNewline.prefix(while: { $0 == " " }).count
        guard indentCount <= 3 else {
            return false
        }

        let content = String(trimmedNewline.dropFirst(indentCount))
        guard !content.isEmpty, content.allSatisfy({ $0 == marker || $0 == " " || $0 == "\t" }) else {
            return false
        }

        let markerCount = content.prefix(while: { $0 == marker }).count
        guard markerCount >= minimumCount else {
            return false
        }
        return String(content.dropFirst(markerCount)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: self.style.bodyFont,
            .foregroundColor: self.style.textColor,
        ]
    }

    private func paragraphStyle() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 0
        return paragraph.copy() as! NSParagraphStyle
    }

    private func applyCodeBlock(
        _ match: CodeBlockMatch,
        to result: NSMutableAttributedString,
        source: String
    ) {
        let fullRange = match.fullRange
        result.addAttributes(
            [
                .font: self.style.codeFont,
                .foregroundColor: self.style.codeTextColor,
                .backgroundColor: self.style.codeBackgroundColor,
            ],
            range: fullRange
        )

        let openingFenceRange = match.openingFenceRange
        let bodyRange = match.bodyRange

        if let languageRange = match.languageRange, languageRange.length > 0 {
            result.addAttributes(
                [
                    .foregroundColor: self.style.linkColor,
                    .font: self.style.codeFont.bold(),
                ],
                range: languageRange
            )
        }

        result.addAttribute(.foregroundColor, value: self.style.secondaryTextColor, range: openingFenceRange)
        if let closingFenceRange = match.closingFenceRange, closingFenceRange.length > 0 {
            result.addAttribute(.foregroundColor, value: self.style.secondaryTextColor, range: closingFenceRange)
        }

        guard bodyRange.length > 0 else {
            return
        }
        let body = (source as NSString).substring(with: bodyRange)
        let highlighted = SyntaxHighlighter.highlight(
            body,
            language: match.language,
            font: self.style.codeFont,
            defaultColor: self.style.codeTextColor
        )
        highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length), options: []) {
            attributes, range, _ in
            let adjusted = NSRange(location: bodyRange.location + range.location, length: range.length)
            result.addAttributes(attributes, range: adjusted)
            result.addAttribute(.backgroundColor, value: self.style.codeBackgroundColor, range: adjusted)
        }
    }

    private func applyLineHighlights(
        to result: NSMutableAttributedString,
        source: String,
        skipping codeBlocks: [CodeBlockMatch]
    ) {
        let fullRange = NSRange(location: 0, length: (source as NSString).length)

        self.applyRegex(Self.headingRegex, in: source, fullRange: fullRange, skipping: codeBlocks) { match in
            let level = min(match.range(at: 1).length, 6)
            result.addAttributes(
                [
                    .font: self.style.headingFont(level: level),
                    .foregroundColor: self.style.textColor,
                ],
                range: match.range
            )
            result.addAttribute(.foregroundColor, value: self.style.secondaryTextColor, range: match.range(at: 1))
        }

        self.applyRegex(Self.blockquoteRegex, in: source, fullRange: fullRange, skipping: codeBlocks) { match in
            result.addAttribute(.foregroundColor, value: self.style.quoteColor, range: match.range)
            result.addAttribute(.foregroundColor, value: self.style.quoteBarColor, range: match.range(at: 1))
        }

        self.applyRegex(Self.unorderedListRegex, in: source, fullRange: fullRange, skipping: codeBlocks) { match in
            result.addAttributes(
                [
                    .foregroundColor: self.style.secondaryTextColor,
                    .font: self.style.codeFont,
                ],
                range: match.range(at: 1)
            )
        }

        self.applyRegex(Self.orderedListRegex, in: source, fullRange: fullRange, skipping: codeBlocks) { match in
            result.addAttributes(
                [
                    .foregroundColor: self.style.secondaryTextColor,
                    .font: self.style.codeFont,
                ],
                range: match.range(at: 1)
            )
        }

        self.applyRegex(Self.taskListRegex, in: source, fullRange: fullRange, skipping: codeBlocks) { match in
            result.addAttributes(
                [
                    .foregroundColor: self.style.linkColor,
                    .font: self.style.codeFont.bold(),
                ],
                range: match.range(at: 1)
            )
        }
    }

    private func applyInlineHighlights(
        to result: NSMutableAttributedString,
        source: String,
        skipping codeBlocks: [CodeBlockMatch]
    ) {
        let fullRange = NSRange(location: 0, length: (source as NSString).length)

        self.applyRegex(Self.inlineCodeRegex, in: source, fullRange: fullRange, skipping: codeBlocks) { match in
            result.addAttributes(
                [
                    .font: self.style.codeFont,
                    .foregroundColor: self.style.inlineCodeTextColor,
                    .backgroundColor: self.style.inlineCodeBgColor,
                ],
                range: match.range
            )
        }

        self.applyRegex(Self.linkRegex, in: source, fullRange: fullRange, skipping: codeBlocks) { match in
            result.addAttribute(.foregroundColor, value: self.style.linkColor, range: match.range)
        }

        let strongMatches = Self.strongRegex.matches(in: source, range: fullRange)

        for match in strongMatches where codeBlocks.allSatisfy({ !$0.fullRange.intersects(match.range) }) {
            applyFontTransform(to: result, range: match.range) { $0.bold() }
        }

        self.applyRegex(Self.emphasisRegex, in: source, fullRange: fullRange, skipping: codeBlocks) { match in
            guard strongMatches.allSatisfy({ !$0.range.intersects(match.range) }) else {
                return
            }
            self.applyFontTransform(to: result, range: match.range) { $0.italic() }
        }
    }

    private func applyMathHighlights(to result: NSMutableAttributedString, source: String) {
        let ns = source as NSString
        let spans = MathScanner.scan(source)
        for span in spans {
            let lower = utf16Index(ns, utf8Offset: span.range.lowerBound)
            let upper = utf16Index(ns, utf8Offset: span.range.upperBound)
            guard lower >= 0, upper > lower, upper <= ns.length else { continue }
            result.addAttribute(.foregroundColor, value: self.style.mathTokenColor,
                                range: NSRange(location: lower, length: upper - lower))
        }
    }

    private func utf16Index(_ ns: NSString, utf8Offset: Int) -> Int {
        var u8 = 0
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            let s = String(utf16CodeUnits: [c], count: 1)
            let bytes = s.utf8.count
            if u8 >= utf8Offset { return i }
            u8 += bytes
            i += 1
        }
        return u8 >= utf8Offset ? i : -1
    }

    private func applyFontTransform(
        to result: NSMutableAttributedString,
        range: NSRange,
        transform: (PlatformFont) -> PlatformFont
    ) {
        guard range.length > 0 else {
            return
        }
        result.enumerateAttribute(.font, in: range, options: []) { value, effectiveRange, _ in
            let currentFont = (value as? PlatformFont) ?? self.style.bodyFont
            result.addAttribute(.font, value: transform(currentFont), range: effectiveRange)
        }
    }

    private func applyRegex(
        _ regex: NSRegularExpression,
        in source: String,
        fullRange: NSRange,
        skipping codeBlocks: [CodeBlockMatch],
        body: (NSTextCheckingResult) -> Void
    ) {
        regex.enumerateMatches(in: source, range: fullRange) { match, _, _ in
            guard let match else {
                return
            }
            guard codeBlocks.allSatisfy({ !$0.fullRange.intersects(match.range) }) else {
                return
            }
            body(match)
        }
    }

    private func codeBlockMatches(in source: String) -> [CodeBlockMatch] {
        let text = source as NSString
        var matches: [CodeBlockMatch] = []
        var searchLocation = 0

        while searchLocation < text.length {
            let lineRange = text.lineRange(for: NSRange(location: searchLocation, length: 0))
            let line = text.substring(with: lineRange)

            guard let openingFence = Self.fenceLineMatch(in: line) else {
                searchLocation = lineRange.upperBound
                continue
            }

            let openingFenceRange = lineRange
            let languageRange = openingFence.languageRange?.shifted(by: openingFenceRange.location)
            let bodyStart = openingFenceRange.upperBound
            var cursor = bodyStart
            var closingFenceRange: NSRange?

            while cursor < text.length {
                let candidateRange = text.lineRange(for: NSRange(location: cursor, length: 0))
                let candidateLine = text.substring(with: candidateRange)
                if
                    Self.isClosingFenceLine(
                        candidateLine,
                        marker: openingFence.marker,
                        minimumCount: openingFence.count
                    ) {
                    closingFenceRange = candidateRange
                    cursor = candidateRange.upperBound
                    break
                }
                cursor = candidateRange.upperBound
            }

            let fullUpperBound = closingFenceRange?.upperBound ?? text.length
            let bodyUpperBound = closingFenceRange?.location ?? text.length
            matches.append(
                CodeBlockMatch(
                    fullRange: NSRange(
                        location: openingFenceRange.location,
                        length: fullUpperBound - openingFenceRange.location
                    ),
                    openingFenceRange: openingFenceRange,
                    bodyRange: NSRange(location: bodyStart, length: max(0, bodyUpperBound - bodyStart)),
                    closingFenceRange: closingFenceRange,
                    language: openingFence.language,
                    languageRange: languageRange
                )
            )

            searchLocation = max(cursor, fullUpperBound)
        }

        return matches
    }
}

extension NSRange {
    fileprivate func intersects(_ other: NSRange) -> Bool {
        location < other.upperBound && other.location < upperBound
    }

    fileprivate func shifted(by offset: Int) -> NSRange {
        NSRange(location: location + offset, length: length)
    }
}
