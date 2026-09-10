import Foundation
import MarkdownCore
import MarkdownRenderKit

func firstChangedMarkdownBlockIndex(
    prevParsedBlocks: [ParsedBlockNode],
    newParsedBlocks: [ParsedBlockNode],
    prevBlocks: [BlockNode],
    newBlocks: [BlockNode]
)
    -> Int {
    let sharedCount = min(prevBlocks.count, newBlocks.count)
    for index in 0 ..< sharedCount {
        let prevParsed = index < prevParsedBlocks.count ? prevParsedBlocks[index] : nil
        let newParsed = index < newParsedBlocks.count ? newParsedBlocks[index] : nil
        if
            markdownBlocksMatch(
                prevParsed: prevParsed,
                newParsed: newParsed,
                prevBlock: prevBlocks[index],
                newBlock: newBlocks[index]
            ) == false {
            return index
        }
    }
    return sharedCount
}

private func markdownBlocksMatch(
    prevParsed: ParsedBlockNode?,
    newParsed: ParsedBlockNode?,
    prevBlock: BlockNode,
    newBlock: BlockNode
)
    -> Bool {
    if
        let prevFingerprint = prevParsed?.fingerprint,
        let newFingerprint = newParsed?.fingerprint {
        return prevFingerprint == newFingerprint
    }
    return prevBlock == newBlock
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
extension MarkdownLabelView {
    /// Restore only selections whose characters survive the splice. TextKit's
    /// previous locations must not be kept across a replacement transaction.
    func restoreSelection(_ selection: NSRange?, after edit: MaterializedEdit?) {
        self.layoutManager.textSelections = []
        guard var selection else { return }
        if let edit, edit.contentChangeRange.length != 0 || edit.contentLengthDelta != 0 {
            let end = NSMaxRange(selection)
            if end <= edit.contentChangeRange.location {
                // Entirely before the edit.
            } else if selection.location >= NSMaxRange(edit.contentChangeRange) {
                selection.location += edit.contentLengthDelta
            } else { return }
        }
        let length = self.contentStorage.textStorage?.length ?? 0
        guard selection.location < length else { return }
        selection.length = min(selection.length, length - selection.location)
        let start = self.contentStorage.documentRange.location
        guard let lower = self.contentStorage.location(start, offsetBy: selection.location),
              let upper = self.contentStorage.location(start, offsetBy: NSMaxRange(selection)),
              let range = NSTextRange(location: lower, end: upper) else { return }
        self.layoutManager.textSelections = [NSTextSelection(range: range, affinity: .downstream, granularity: .character)]
    }
}
