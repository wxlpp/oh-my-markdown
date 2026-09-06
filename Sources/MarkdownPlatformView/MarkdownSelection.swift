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
func utf8StringIndex(in source: String, at byteOffset: Int) -> String.Index? {
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
        return plainFallback()
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
        return plainFallback()
    }

    // Continuous original-source span: first overlapped block's lowerBound to
    // last overlapped block's upperBound. Preserves original block separators.
    //
    // Known block-level limitation: if the first or last overlapped block has
    // `sourceRange == nil` (e.g. blocks injected via `setBlocks` without a
    // Markdown source), the *entire* selection — including any middle blocks that
    // do carry a sourceRange — falls back to rendered plain text (all-or-nothing,
    // determined by the boundary blocks). Per-block mixed restoration is deferred
    // to a future version.
    guard
        let lowerByte = parsedBlocks[lower].sourceRange?.lowerBound,
        let upperByte = parsedBlocks[upper].sourceRange?.upperBound,
        lowerByte <= upperByte,
        let startIndex = utf8StringIndex(in: originalSource, at: lowerByte),
        let endIndex = utf8StringIndex(in: originalSource, at: upperByte),
        startIndex <= endIndex else {
        return plainFallback()
    }
    return String(originalSource[startIndex ..< endIndex])
}
