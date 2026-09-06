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
