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
/// the parser rebuilt, from its own `sourceAnchor` and `sourceAnchorEnd` — and
/// those bound the whole run of pieces one origin block became, so they are
/// usable only when the run starts and ends where the selection does. Nothing
/// else is: source can belong to no block at all (a link reference definition
/// renders nowhere), so index adjacency does not imply byte adjacency, and
/// neither a neighbour's bound nor the document's length is a proof.
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

    /// The pieces one rebuilt block was split into share its anchor and its end,
    /// so that pair identifies the origin block exactly. Grouping merely by
    /// "adjacent and source-less" would merge two neighbouring formulas and leave
    /// neither copyable, though each has both boundaries of its own.
    func sameOrigin(_ a: Int, _ b: Int) -> Bool {
        parsedBlocks[a].sourceRange == nil && parsedBlocks[b].sourceRange == nil
            && parsedBlocks[a].sourceAnchor == parsedBlocks[b].sourceAnchor
            && parsedBlocks[a].sourceAnchorEnd == parsedBlocks[b].sourceAnchorEnd
    }

    /// Start of the run of pieces `index` belongs to.
    func runStart(_ index: Int) -> Int {
        var start = index
        while start > 0, sameOrigin(start - 1, start) {
            start -= 1
        }
        return start
    }
    /// A `sourceRange` starts at the block's *content column*, so an indented
    /// code block's range begins after its indent. Those bytes belong to the
    /// block and must come with it, or the copy stops parsing as code.
    func lineStart(before byte: Int) -> Int {
        // Indices, not a copy of the source: the sibling helper above carries the
        // same warning about this file's cost model.
        let utf8 = originalSource.utf8
        var count = min(max(0, byte), utf8.count)
        var cursor = utf8.index(utf8.startIndex, offsetBy: count)
        while count > 0 {
            let previous = utf8.index(before: cursor)
            guard utf8[previous] == 0x20 || utf8[previous] == 0x09 else { break }
            cursor = previous
            count -= 1
        }
        return count
    }

    var lowerByte: Int?
    if let range = parsedBlocks[lower].sourceRange {
        lowerByte = lineStart(before: range.lowerBound)
    } else if runStart(lower) == lower, parsedBlocks[lower].splitOrdinal == 0,
              parsedBlocks[lower].documentOrdinal == nil {
        // `documentOrdinal` is non-nil only for programmatic nodes, whose anchor
        // is a placeholder rather than a real offset.
        lowerByte = lineStart(before: parsedBlocks[lower].sourceAnchor)
    }

    /// End of the run of pieces `index` belongs to.
    func runEnd(_ index: Int) -> Int {
        var end = index
        while end + 1 < parsedBlocks.count, sameOrigin(end, end + 1) {
            end += 1
        }
        return end
    }

    // The end comes from a real range, or from `sourceAnchorEnd`, which records
    // where the block a rebuilt block came from ended. Never from the document's
    // length: "the last selected block is the last block" does not mean its bytes
    // reach the end, and a trailing reference definition belongs to no block.
    // One anchor bounds the whole run, so it is only usable when the run ends
    // where the selection does.
    var upperByte: Int?
    if let range = parsedBlocks[upper].sourceRange {
        upperByte = range.upperBound
    } else if runEnd(upper) == upper, upper - runStart(upper) == parsedBlocks[upper].splitOrdinal,
              parsedBlocks[upper].documentOrdinal == nil {
        // What this conjunct proves is that the group *starts* at piece 0 — the
        // lower boundary's property, checked here too so a broken grouping fails
        // closed on both sides. It is not the end proof. That is `runEnd(upper)
        // == upper` plus the contiguity `equivalentForSplice` maintains by
        // comparing `sourceAnchorEnd`; `ParsedBlockNode` records no piece count,
        // so nothing stronger is expressible. Don't drop `runEnd` as redundant:
        // without it, a run missing its last piece hands over that piece's bytes.
        upperByte = parsedBlocks[upper].sourceAnchorEnd
    }

    if
        let lowerByte, let upperByte, lowerByte <= upperByte,
        let startIndex = utf8StringIndex(in: originalSource, at: lowerByte),
        let endIndex = utf8StringIndex(in: originalSource, at: upperByte),
        startIndex <= endIndex {
        let text = String(originalSource[startIndex ..< endIndex])
        if !text.isEmpty {
            return MarkdownCopyResult(
                text: text, granularity: coversEveryOverlappedBlock ? .exact : .blockExpanded
            )
        }
    }

    // No boundary byte is provable: programmatic blocks, or a run of rebuilt
    // pieces that starts before or ends after the selection. Reconstructing the
    // selected blocks returns only what they render, never bytes belonging to
    // something else, and is never called source.
    guard let reconstructedSource else { return fallback() }
    let pieces = (lower ... upper).compactMap { block -> String? in
        // Clamped to the selection, like the plain fallback: reconstructing a
        // whole block would paste an image URL for a three-character selection.
        let start = max(blockStarts[block], selStart)
        let end = min(contentEnd(of: block), selEnd)
        guard start < end else { return nil }
        return reconstructedSource(NSRange(location: start, length: end - start))
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
        // an attachment, or a placeholder standing in for a whole table — and is
        // always one character, so it contributes its text whole.
        if let semantic = attributes[.markdownCopyText] as? String {
            result += semantic
            return
        }
        result += plain.substring(with: range)
    }
    return result
}

func reconstructedSourceText(from attributed: NSAttributedString, range: NSRange) -> String {
    let clamped = NSRange(
        location: min(max(0, range.location), attributed.length),
        length: max(0, min(range.length, attributed.length - min(max(0, range.location), attributed.length)))
    )
    guard clamped.length > 0 else { return "" }
    let plain = attributed.string as NSString

    // A recorded syntax stands for a whole run, so the selection has to contain
    // that run whole. Measured: judging dictionary runs instead let a selection
    // clipped at the run's *start* paste an image's URL. The unit is the *key's* run, not an attribute-dictionary
    // run: the `🖼 ` marker carries `.markdownCopySkip` and splits an image's
    // syntax run in two, so judging each dictionary run on its own emitted the
    // image's URL for a selection that clipped the run's start — the second half
    // looked complete on its own. `enumerateAttribute` on the single key
    // coalesces the run, which is the unit the value stands for.
    var wholeRuns: [NSRange] = []
    attributed.enumerateAttribute(
        .markdownCopySource, in: NSRange(location: 0, length: attributed.length), options: []
    ) { value, range, _ in
        if value != nil, NSEqualRanges(NSIntersectionRange(range, clamped), range) { wholeRuns.append(range) }
    }

    var result = ""
    attributed.enumerateAttributes(in: clamped, options: []) { attributes, range, _ in
        // Before the skip check: the syntax replaces everything in its run,
        // including the `🖼 ` marker, which is where the run begins.
        if let run = wholeRuns.first(where: { NSLocationInRange(range.location, $0) }) {
            // Once per run, at its first character.
            if range.location == run.location, let source = attributes[.markdownCopySource] as? String {
                result += source
            }
            return
        }
        if attributes[.markdownCopySkip] != nil { return }
        // `.markdownCopyText` needs no such check: every run carrying it is one
        // character, so it cannot be clipped.
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

    /// Always `.exact` by construction: rendered copy has no notion of source, so
    /// it can always serialize precisely the selection.
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
