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

/// Pre-Task-9 shape of source copy: the source span of every block the selection
/// overlaps, with no granularity reported and no recovery for blocks the parser
/// rebuilt. No shipping command calls it; it is kept because the migration parity
/// tests pin the legacy mapping deliberately. New code wants `markdownSourceCopy`.
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

/// Maps a rendered selection to the Markdown source it covers, and reports how
/// faithful the result is instead of silently widening a partial selection.
///
/// The selection's rendered offsets are mapped to the blocks it overlaps through
/// `blockStarts` (assigned only in `replaceSnapshot`), then to a single verbatim
/// byte span in `originalSource` between two *provable* boundaries. Copying one
/// span rather than joining per-block pieces is what keeps interior bytes —
/// indentation, list markers, blank-line separators — exactly as written.
///
/// A boundary is provable when the block owns a `sourceRange`, or, for a block
/// the parser rebuilt, from its `sourceAnchor` at the start and from the end of
/// the document at the end. Nothing else is: source can belong to no block at
/// all (a link reference definition renders nowhere), so index adjacency does
/// not imply byte adjacency, and a bracket to a neighbour's bound would hand
/// over bytes the reader never selected.
///
/// `renderedFallback` supplies the semantic rendered text used when no source
/// mapping exists; without it the raw plain substring is used, which still
/// contains object-replacement characters. `reconstructedSource` supplies
/// approximate syntax when no boundary is provable, and is always reported
/// `.renderedFallback`.
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
    // no source range, but they do carry `sourceAnchor`, which math backfill
    // preserves from the block they came from. That is the byte the start of the
    // selection needs, and using it avoids guessing: bracketing to the previous
    // block's end would swallow source that belongs to no block at all, such as
    // a link reference definition, which renders nowhere.
    //
    // Only the two boundary bytes are needed. Everything between them is copied
    // verbatim, so interior bytes — indentation, separator lines, list markers —
    // survive, where re-joining per-block pieces would destroy them.

    /// Start of the maximal run of source-less blocks containing `index`.
    func runStart(_ index: Int) -> Int {
        var start = index
        while start > 0, parsedBlocks[start - 1].sourceRange == nil {
            start -= 1
        }
        return start
    }
    /// A `sourceRange` starts at the block's *content column*, so an indented
    /// code block's range begins after its indent. Those bytes belong to the
    /// block and must come with it, or the copy stops parsing as code.
    func lineStart(before byte: Int) -> Int {
        let utf8 = Array(originalSource.utf8)
        var cursor = min(max(0, byte), utf8.count)
        while cursor > 0, utf8[cursor - 1] == 0x20 || utf8[cursor - 1] == 0x09 {
            cursor -= 1
        }
        return cursor
    }

    var lowerByte: Int?
    if let range = parsedBlocks[lower].sourceRange {
        lowerByte = lineStart(before: range.lowerBound)
    } else if runStart(lower) == lower, parsedBlocks[lower].documentOrdinal == nil {
        // `documentOrdinal` is non-nil only for programmatic nodes, whose anchor
        // is a placeholder rather than a real offset.
        lowerByte = lineStart(before: parsedBlocks[lower].sourceAnchor)
    }

    // The end is only provable when the last selected block owns a range, or when
    // the selection runs to the end of the document — a source-less block has no
    // recorded end, and the bytes after it may belong to no block.
    var trimTrailing = false
    var upperByte: Int?
    if let range = parsedBlocks[upper].sourceRange {
        upperByte = range.upperBound
    } else if upper == parsedBlocks.count - 1, parsedBlocks[upper].documentOrdinal == nil {
        upperByte = originalSource.utf8.count
        trimTrailing = true
    }

    if
        let lowerByte, let upperByte, lowerByte <= upperByte,
        let startIndex = utf8StringIndex(in: originalSource, at: lowerByte),
        let endIndex = utf8StringIndex(in: originalSource, at: upperByte),
        startIndex <= endIndex {
        var text = String(originalSource[startIndex ..< endIndex])
        if trimTrailing {
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

    // No boundary byte is provable: programmatic blocks, a source-less run that
    // starts before the selection, or a source-less block with more document
    // after it. Reconstructing the selected blocks returns only what they render,
    // never bytes belonging to something else, and is never called source.
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
