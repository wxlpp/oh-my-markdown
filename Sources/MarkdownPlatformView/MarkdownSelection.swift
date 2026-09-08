import Foundation
import MarkdownCore
import MarkdownRenderKit

// MARK: - Copy: rendered selection → original Markdown source

/// Converts a UTF-8 byte offset into a `String.Index` without losing surrogate
/// pairs. Same correct form used by `MarkdownCore`'s internal `utf8Index(at:)`
/// (`String.Index(_:within:)` on the UTF-8 view), not a code-unit-by-code-unit
/// walk which would mis-handle multi-byte scalars.
///
/// Complexity: `String.UTF8View` is not random-access, so `utf8.index(_:offsetBy:)`
/// is O(byteOffset). On the copy path this is called exactly twice per copy
/// operation (once for lowerByte, once for upperByte) and is not a hot path —
/// the cost is intentionally accepted here; do not call in a loop or hot path.
private func utf8StringIndex(in source: String, at byteOffset: Int) -> String.Index? {
    guard byteOffset >= 0, byteOffset <= source.utf8.count else {
        return nil
    }
    let utf8 = source.utf8
    guard let scalarIndex = utf8.index(
        utf8.startIndex, offsetBy: byteOffset, limitedBy: utf8.endIndex
    ) else {
        return nil
    }
    return String.Index(scalarIndex, within: source)
}

/// Bug 4 — read-only copy must yield the *original Markdown source* the user
/// selected, not the rendered plain text (where math/image collapse to the
/// object-replacement char `\u{FFFC}` and tables lose their pipes).
///
/// Strategy (block-level granularity, first version): the rendered selection
/// `[selStart, selEnd)` is mapped to the set of blocks it overlaps via
/// `blockStarts` (the rendered char offset of each block's start, maintained in
/// `updateContent`/`applyDocument`). The returned string is the *continuous*
/// original-source substring from the first overlapped block's
/// `sourceRange.lowerBound` to the last overlapped block's
/// `sourceRange.upperBound` in `lastParsedSource` — the most faithful form
/// because it preserves the original inter-block text verbatim (`# `, `- `,
/// `$$…$$`, `![alt](url)`, `| a | b |`, blank-line separators, …).
///
/// Falls back to the rendered-plain-text substring when there is no usable
/// source mapping (e.g. blocks were set directly without a Markdown source),
/// so non-Markdown content still copies.
///
/// Known limitation: granularity is block-level. A selection touching any part
/// of a block expands to that block's full original source. Inline-precise
/// source extraction is intentionally out of scope for this first version; the
/// core guarantee — formulas/images/tables never lost — holds regardless.
func markdownSourceForRenderedSelection(
    renderedRange: NSRange,
    renderedPlainText: String,
    blockStarts: [Int],
    parsedBlocks: [ParsedBlockNode],
    renderedLength: Int,
    originalSource: String
)
    -> String {
    markdownSourceCopy(
        renderedRange: renderedRange, renderedPlainText: renderedPlainText, blockStarts: blockStarts,
        parsedBlocks: parsedBlocks, renderedLength: renderedLength, originalSource: originalSource,
        renderedFallback: nil
    ).text
}

/// Same mapping, but it reports how faithful the result is instead of silently
/// widening a partial selection to whole blocks.
///
/// `renderedFallback` supplies the semantic rendered text used when no source
/// mapping exists; without it the raw plain substring is used, which still
/// contains object-replacement characters.
func markdownSourceCopy(
    renderedRange: NSRange,
    renderedPlainText: String,
    blockStarts: [Int],
    parsedBlocks: [ParsedBlockNode],
    renderedLength: Int,
    originalSource: String,
    renderedFallback: ((NSRange) -> String)?,
    reconstructedSource: ((NSRange) -> String)? = nil
)
    -> MarkdownCopyResult {
    func fallback() -> MarkdownCopyResult {
        MarkdownCopyResult(
            text: renderedFallback?(renderedRange) ?? plainFallback(), granularity: .renderedFallback
        )
    }
    func plainFallback() -> String {
        let ns = renderedPlainText as NSString
        let clamped = NSRange(
            location: min(renderedRange.location, ns.length),
            length: min(renderedRange.length, max(0, ns.length - renderedRange.location))
        )
        return ns.substring(with: clamped)
    }

    let selStart = renderedRange.location
    let selEnd = renderedRange.location + renderedRange.length
    guard selStart < selEnd, !blockStarts.isEmpty else {
        return fallback()
    }

    // Rendered span of block i is [blockStarts[i], blockStarts[i+1]) with the
    // last block running to renderedLength. A block is overlapped when its span
    // intersects [selStart, selEnd).
    var firstBlock: Int?
    var lastBlock: Int?
    for index in blockStarts.indices {
        let blockStart = blockStarts[index]
        let blockEnd = index + 1 < blockStarts.count ? blockStarts[index + 1] : renderedLength
        if blockStart < selEnd, selStart < blockEnd {
            if firstBlock == nil {
                firstBlock = index
            }
            lastBlock = index
        }
    }
    guard
        let lower = firstBlock,
        let upper = lastBlock,
        lower < parsedBlocks.count,
        upper < parsedBlocks.count else {
        return fallback()
    }

    /// A block's rendered content ends one character before the next block's
    /// start, the separator run the materializer inserts between blocks.
    func contentEnd(of index: Int) -> Int {
        index + 1 < blockStarts.count ? max(blockStarts[index], blockStarts[index + 1] - 1) : renderedLength
    }
    let coversEveryOverlappedBlock = selStart <= blockStarts[lower] && selEnd >= contentEnd(of: upper)

    // Blocks the parser produced by transforming the source — a block formula
    // lifted out of a paragraph, a paragraph rebuilt around inline math — carry
    // no source range. Their bytes are still recoverable at the *edges* of the
    // selection: consecutive blocks are contiguous in the source, so a run of
    // source-less blocks that starts exactly where the selection starts begins
    // where the previous block's range ended.
    //
    // Only the two boundary bytes are needed. Everything between them is copied
    // verbatim, which keeps the original inter-block bytes — indentation,
    // separator lines, list markers — that re-joining pieces would destroy.
    func upperBoundBefore(_ index: Int) -> Int {
        (0 ..< index).reversed().lazy.compactMap { parsedBlocks[$0].sourceRange?.upperBound }.first ?? 0
    }
    func lowerBoundAfter(_ index: Int) -> Int {
        ((index + 1) ..< parsedBlocks.count).lazy.compactMap { parsedBlocks[$0].sourceRange?.lowerBound }.first
            ?? originalSource.utf8.count
    }
    /// Start of the maximal run of source-less blocks containing `index`.
    func runStart(_ index: Int) -> Int {
        var start = index
        while start > 0, parsedBlocks[start - 1].sourceRange == nil {
            start -= 1
        }
        return start
    }
    func runEnd(_ index: Int) -> Int {
        var end = index
        while end + 1 < parsedBlocks.count, parsedBlocks[end + 1].sourceRange == nil {
            end += 1
        }
        return end
    }

    var trimmedLeading = false
    var trimmedTrailing = false
    var lowerByte: Int?
    if let range = parsedBlocks[lower].sourceRange {
        lowerByte = range.lowerBound
    } else if runStart(lower) == lower {
        // The run starts where the selection starts, so the gap before it is the
        // selection's own. A run reaching further back would drag in the bytes of
        // blocks the user did not select.
        lowerByte = upperBoundBefore(lower)
        trimmedLeading = true
    }
    var upperByte: Int?
    if let range = parsedBlocks[upper].sourceRange {
        upperByte = range.upperBound
    } else if runEnd(upper) == upper {
        upperByte = lowerBoundAfter(upper)
        trimmedTrailing = true
    }

    if
        let lowerByte, let upperByte, lowerByte <= upperByte,
        let startIndex = utf8StringIndex(in: originalSource, at: lowerByte),
        let endIndex = utf8StringIndex(in: originalSource, at: upperByte),
        startIndex <= endIndex {
        var text = String(originalSource[startIndex ..< endIndex])
        // Trim only an edge a bracket produced: a block's own range is already
        // exact, and its leading whitespace can be load-bearing — four spaces
        // are the difference between a code block and a paragraph.
        if trimmedLeading {
            text = String(text.drop(while: { $0.isWhitespace || $0.isNewline }))
        }
        if trimmedTrailing {
            while let last = text.last, last.isWhitespace || last.isNewline {
                text.removeLast()
            }
        }
        if !text.isEmpty {
            return MarkdownCopyResult(
                text: text, granularity: coversEveryOverlappedBlock ? .exact : .blockExpanded
            )
        }
    }

    // No byte range reaches the selection's edges: either there is no source at
    // all (programmatic blocks), or a source-less run continues past the
    // selection so bracketing it would copy blocks the user did not select. The
    // runs can still name their own syntax, but rendered text cannot be proven
    // to be source, so this is never reported as source.
    guard let reconstructedSource else { return fallback() }
    let pieces = (lower ... upper).map { block in
        reconstructedSource(NSRange(
            location: blockStarts[block], length: max(0, contentEnd(of: block) - blockStarts[block])
        ))
    }
    return MarkdownCopyResult(
        text: pieces.filter { !$0.isEmpty }.joined(separator: "\n\n"), granularity: .renderedFallback
    )
}

// MARK: - Copy: rendered selection → what the reader sees

/// Serializes a rendered selection into text a reader would recognise: no
/// object-replacement characters, attachments replaced by the semantic text the
/// materializer recorded for them, and layout-only characters dropped.
func renderedCopyText(from attributed: NSAttributedString, range: NSRange) -> String {
    let clamped = NSRange(
        location: min(max(0, range.location), attributed.length),
        length: max(0, min(range.length, attributed.length - min(max(0, range.location), attributed.length)))
    )
    guard clamped.length > 0 else { return "" }
    let plain = attributed.string as NSString
    var result = ""
    attributed.enumerateAttributes(in: clamped, options: []) { attributes, range, _ in
        if attributes[.markdownCopySkip] != nil { return }
        // A run carrying copy text occupies characters that read as nothing —
        // an attachment, or a placeholder standing in for a whole table — so it
        // contributes its text whole, never a slice of the placeholder.
        if let semantic = attributes[.markdownCopyText] as? String {
            result += semantic
            return
        }
        result += plain.substring(with: range)
    }
    return result
}

/// Markdown syntax for a rendered range whose block has no parser source range.
/// Approximate by construction — a run that recorded its own syntax contributes
/// it, everything else contributes rendered text, which has already lost its
/// delimiters. Never reported as source; the caller returns `.renderedFallback`.
func reconstructedSourceText(from attributed: NSAttributedString, range: NSRange) -> String {
    let clamped = NSRange(
        location: min(max(0, range.location), attributed.length),
        length: max(0, min(range.length, attributed.length - min(max(0, range.location), attributed.length)))
    )
    guard clamped.length > 0 else { return "" }
    let plain = attributed.string as NSString
    var result = ""
    attributed.enumerateAttributes(in: clamped, options: []) { attributes, range, _ in
        if attributes[.markdownCopySkip] != nil { return }
        if let source = attributes[.markdownCopySource] as? String {
            result += source
            return
        }
        if let semantic = attributes[.markdownCopyText] as? String {
            result += semantic
            return
        }
        result += plain.substring(with: range)
    }
    return result
}

// MARK: - View-facing copy API

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
extension MarkdownLabelView {
    public func renderedSelectionResult() -> MarkdownCopyResult? {
        guard let range = currentRenderedSelectionRange() else { return nil }
        return self.renderedSelectionResult(forRenderedRange: range)
    }

    func renderedSelectionResult(forRenderedRange range: NSRange) -> MarkdownCopyResult? {
        guard let attributed = renderedAttributedStringForCopy else { return nil }
        return MarkdownCopyResult(text: renderedCopyText(from: attributed, range: range), granularity: .exact)
    }

    public func markdownSourceSelectionResult() -> MarkdownCopyResult? {
        guard let range = currentRenderedSelectionRange() else { return nil }
        return self.markdownSourceSelectionResult(forRenderedRange: range)
    }

    func markdownSourceSelectionResult(forRenderedRange range: NSRange) -> MarkdownCopyResult? {
        guard let attributed = renderedAttributedStringForCopy else { return nil }
        return self.markdownSourceCopy(
            forRenderedRange: range, renderedPlainText: attributed.string,
            renderedFallback: { renderedCopyText(from: attributed, range: $0) },
            reconstructedSource: { reconstructedSourceText(from: attributed, range: $0) }
        )
    }
}
