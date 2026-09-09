import Foundation

/// Source-byte recognizer for the two global/preceding-line invalidation forms.
/// It shares the mandatory candidate scan; no Foundation UTF-16 regex bridge.
private struct InvalidationLines {
    var hasReference = false
    var hasBreak = false
    private var leadingSpaces = 0
    private var started = false
    private var referenceState = 0
    private var labelCount = 0
    private var labelEscaped = false
    private var marker: UInt8?
    private var markerCount = 0
    private var trailingSpace = false
    private var trailingTab = false
    private var validBreak = true

    mutating func feed(_ byte: UInt8) {
        if byte == 10 || byte == 13 { self.finishLine(); return }
        if !self.started {
            if byte == 32 { self.leadingSpaces += 1; return }
            self.started = true
            guard self.leadingSpaces <= 3 else { self.referenceState = -1; self.validBreak = false; return }
            self.referenceState = byte == 91 ? 1 : -1
            if byte == 61 || byte == 45 || byte == 42 || byte == 95 {
                self.marker = byte; self.markerCount = 1
            }
            return
        }
        if self.referenceState == 1 {
            if byte == 93, !self.labelEscaped { self.referenceState = self.labelCount > 0 ? 2 : -1 }
            else { self.labelCount += 1 }
            self.labelEscaped = byte == 92 && !self.labelEscaped
        } else if self.referenceState == 2 {
            self.hasReference = self.hasReference || byte == 58
            self.referenceState = -1
        }
        guard let marker, self.validBreak else { return }
        if byte == marker, !self.trailingTab, !(self.trailingSpace && (marker == 61 || marker == 45)) {
            self.markerCount += 1
        } else if byte == 32 { self.trailingSpace = true }
        else if byte == 9 { self.trailingTab = true }
        else { self.validBreak = false }
    }

    mutating func finishLine() {
        if let marker, self.validBreak, self.markerCount >= (marker == 61 ? 1 : 3) { self.hasBreak = true }
        self.leadingSpaces = 0; self.started = false; self.referenceState = 0; self.labelCount = 0
        self.labelEscaped = false
        self.marker = nil; self.markerCount = 0; self.trailingSpace = false; self.trailingTab = false; self.validBreak = true
    }
}

package struct FenceState: Equatable {
    package let marker: UInt8
    package let length: Int
    package let startByte: Int
}

package enum MathDelimiterState: Equatable { case closed, dollar, doubleDollar, paren, bracket }

package struct LineContext: Equatable {
    package let lineStart: Int
    package let containerStart: Int?
    package let endsInCarriageReturn: Bool
}

package struct IncrementalParseState: Equatable {
    package let safeUTF8Boundary: Int
    package let fence: FenceState?
    package let inlineCodeDelimiterLength: Int?
    package let math: MathDelimiterState
    package let lineContext: LineContext
    package let sourceUTF8Count: Int
    package let sourceOrigin: IncrementalSourceBuffer.Origin
    package let sourceWitness: IncrementalSourceBuffer.Witness?
    package let hasReferences: Bool
    package let requiresGlobalContext: Bool
    package let endsInNewline: Bool
    package let containsMathSyntax: Bool
    package let containsCodeSyntax: Bool
    package let containsReservedScalar: Bool
}

package enum FullParseReason: Equatable {
    case nonPrefixEdit, missingState, referenceDefinition, setextOrThematicBreak
    case htmlBlock, lazyContainer, splitCRLF, missingFinalNewline, inconsistentPrefix
}

package struct BlockLineage: Equatable {
    package let oldIndex: Int?
    package let newIndex: Int
    package let lineage: UInt64
}

package struct IncrementalParseResult: Equatable {
    package let document: MarkdownDocument
    package let state: IncrementalParseState
    package let fullParseReason: FullParseReason?
    package let invalidationStartByte: Int
    package let changedBlockRange: Range<Int>
    package let replacedPreviousRange: Range<Int>
    package let lineageChanges: [BlockLineage]
    /// Explicit diagnostic projection; production consumers use block anchors
    /// and the changed-range records without copying the stable prefix.
    package var lineageMapping: [BlockLineage] {
        var metrics = ParseWorkMetrics()
        var index = 0
        let result = self.document.blockStorage.materializedMap({ node in
            defer { index += 1 }
            if self.changedBlockRange.contains(index) {
                return self.lineageChanges[index - self.changedBlockRange.lowerBound]
            }
            let oldIndex = index < self.changedBlockRange.lowerBound ? index
                : index - self.changedBlockRange.upperBound + self.replacedPreviousRange.upperBound
            return BlockLineage(oldIndex: oldIndex, newIndex: index, lineage: node.lineage)
        }, metrics: &metrics)
        self.document.workRecorder?.recordFacade(metrics)
        return result
    }

    package let metrics: ParseWorkMetrics
}

extension IncrementalSourceBuffer {
    /// The caller must admit synchronous cmark work through ParseExecutor.
    package func parse(previous: IncrementalParseResult?, metrics initialMetrics: ParseWorkMetrics = .init(), afterCmark: () -> Void = {}) throws -> IncrementalParseResult {
        var metrics = initialMetrics
        let rejectedReason: FullParseReason? = if let previous, previous.state.sourceOrigin != self.origin {
            .nonPrefixEdit
        } else if let previous,
                  self.witness(at: previous.state.sourceUTF8Count) != previous.state.sourceWitness {
            .inconsistentPrefix
        } else { nil }
        let previous = rejectedReason == nil ? previous : nil
        var start = previous?.state.safeUTF8Boundary ?? 0
        var reason: FullParseReason? = previous == nil ? .missingState : nil
        if let previous, previous.document.blockStorage.count > 0 {
            let last = previous.document.blockStorage[previous.document.blockStorage.count - 1]
            switch last.block {
            case .htmlBlock:
                start = min(start, last.sourceRange?.lowerBound ?? 0); reason = .htmlBlock
            case .blockquote, .bulletList, .orderedList:
                start = min(start, last.sourceRange?.lowerBound ?? 0); reason = .lazyContainer
            default:
                if !previous.state.endsInNewline {
                    start = min(start, last.sourceRange?.lowerBound ?? 0); reason = .missingFinalNewline
                }
            }
            if previous.document.blockStorage.count >= 2 {
                let beforeTail = previous.document.blockStorage[previous.document.blockStorage.count - 2]
                if case .table = beforeTail.block {
                    start = min(start, beforeTail.sourceRange?.lowerBound ?? 0)
                }
            }
        }
        if let previous, start != 0 {
            // A trusted provenance witness does not validate a cached parser
            // offset. The tail must begin on a recorded line/scalar boundary.
            let preceding = start > 0 && start <= previous.state.sourceUTF8Count ? self.byte(at: start - 1) : nil
            metrics.scannerBytes = ParseWorkMetrics.saturatingAdd(metrics.scannerBytes, preceding == nil ? 0 : 1)
            if preceding != 10 && preceding != 13 {
                start = 0
                if reason == nil { reason = .missingState }
            }
        }
        var source = try self.materialize(from: start, metrics: &metrics)
        var hasGlobalMath = false
        var hasReserved = false
        var codeCandidate = false
        var spaces = 0
        var lineStart = start
        var invalidation = InvalidationLines()
        var scanned = 0
        do {
            defer { metrics.scannerBytes = ParseWorkMetrics.saturatingAdd(metrics.scannerBytes, scanned) }
            for byte in source.utf8 {
                if scanned & 1023 == 0 { try Task.checkCancellation() }
                scanned += 1
                hasGlobalMath = hasGlobalMath || byte == 36 || byte == 92
                hasReserved = hasReserved || byte == 0xF4
                spaces = byte == 32 ? spaces + 1 : 0
                codeCandidate = codeCandidate || byte == 96 || byte == 126 || spaces >= 4
                if byte == 10 || byte == 13 { lineStart = start + scanned }
                invalidation.feed(byte)
            }
        }
        invalidation.finishLine()
        let hasReferences = previous?.state.hasReferences == true || invalidation.hasReference
        let splitCRLF = previous.map {
            $0.state.lineContext.endsInCarriageReturn && self.byte(at: $0.state.sourceUTF8Count) == 10
        } ?? false
        if hasReferences || previous?.state.requiresGlobalContext == true || splitCRLF {
            if start != 0 { source = try self.materialize(from: 0, metrics: &metrics) }
            start = 0
            if hasReferences { reason = .referenceDefinition }
            else if splitCRLF { reason = .splitCRLF }
            else { reason = .missingState }
        } else if previous != nil, invalidation.hasBreak {
            reason = .setextOrThematicBreak
        }
        let raw: [ParsedBlockNode]
        let needsMath = hasGlobalMath || hasReserved || codeCandidate || (start == 0 && (previous?.state.containsMathSyntax == true || previous?.state.containsCodeSyntax == true || previous?.state.containsReservedScalar == true))
        var scan: MathScanner.ScanResult?
        if !needsMath {
            raw = try MarkdownDocument.parsePlainTail(source, metrics: &metrics, afterCmark: afterCmark)
        } else {
            let parsed = try MarkdownDocument.parseMathTail(
                source,
                codeRegionsNeeded: codeCandidate || (start == 0 && previous?.state.containsCodeSyntax == true),
                hasReserved: hasReserved || (start == 0 && previous?.state.containsReservedScalar == true),
                metrics: &metrics,
                afterCmark: afterCmark
            )
            raw = parsed.0
            scan = parsed.1
        }
        var prefixCount = 0
        if let previous, start > 0 {
            prefixCount = previous.document.blockStorage.count
            while prefixCount > 0 {
                try Task.checkCancellation()
                metrics.recordMetadata(MemoryLayout<ParsedBlockNode>.stride)
                let block = previous.document.blockStorage[prefixCount - 1]
                guard let range = block.sourceRange, range.lowerBound >= start else { break }
                prefixCount -= 1
            }
        }
        let shifted = try raw.map { node in
            try Task.checkCancellation()
            return ParsedBlockNode(
                block: node.block,
                sourceRange: node.sourceRange.map {
                    MarkdownSourceRange(lowerBound: $0.lowerBound + start, upperBound: $0.upperBound + start)
                },
                fingerprint: node.fingerprint,
                sourceAnchor: node.sourceAnchor + start,
                sourceAnchorEnd: node.sourceAnchorEnd.map { $0 + start },
                splitOrdinal: node.splitOrdinal,
                // Carried, not defaulted: it is the flag saying this node's
                // anchor is a placeholder, so dropping it would shift a
                // placeholder into a real-looking offset that then reads as a
                // provable copy boundary.
                documentOrdinal: node.documentOrdinal
            )
        }
        metrics.recordMetadata(raw.count * MemoryLayout<ParsedBlockNode>.stride + 88)
        let prefix = previous?.document.blockStorage.slice(0 ..< prefixCount, metrics: &metrics) ?? PersistentValues()
        var changedStart = prefixCount
        var changedEnd = prefixCount + shifted.count
        var replacedEnd = previous?.document.blockStorage.count ?? 0
        if let previous {
            while changedStart < min(changedEnd, replacedEnd),
                  try equivalentForSplice(previous.document.blockStorage[changedStart], shifted[changedStart - prefixCount], metrics: &metrics) {
                changedStart += 1
            }
            while changedEnd > changedStart, replacedEnd > changedStart,
                  try equivalentForSplice(previous.document.blockStorage[replacedEnd - 1], shifted[changedEnd - prefixCount - 1], metrics: &metrics) {
                changedEnd -= 1
                replacedEnd -= 1
            }
        }
        let changed = PersistentValues(shifted).slice(changedStart - prefixCount ..< changedEnd - prefixCount, metrics: &metrics)
        let retainedPrefix = previous?.document.blockStorage.slice(0 ..< changedStart, metrics: &metrics) ?? prefix
        let retainedSuffix = previous?.document.blockStorage.slice(replacedEnd ..< previous!.document.blockStorage.count, metrics: &metrics) ?? PersistentValues()
        let document = MarkdownDocument(blockStorage: retainedPrefix.appending(changed, metrics: &metrics).appending(retainedSuffix, metrics: &metrics), recorder: self.recorder)
        let lastBlock = document.blockStorage.count > 0 ? document.blockStorage[document.blockStorage.count - 1] : nil
        let canCloseAtBlank: Bool = switch lastBlock?.block {
        case .paragraph, .heading, .thematicBreak, .mathBlock, .table: true
        case .codeBlock: scan?.fence == nil
        default: false
        }
        let allStable = scan?.earliestOpenByte == nil && !hasReferences && source.hasSuffix("\n\n") && canCloseAtBlank
        var boundary = allStable ? self.utf8Count : (lastBlock?.sourceRange?.lowerBound ?? 0)
        // cmark's source range begins at the content column, not necessarily
        // the line start (notably for indented code). Reparse the indentation.
        if !allStable, boundary >= start {
            let bytes = source.utf8
            var cursor = bytes.index(bytes.startIndex, offsetBy: boundary - start)
            var inspected = 0
            defer { metrics.scannerBytes = ParseWorkMetrics.saturatingAdd(metrics.scannerBytes, inspected) }
            while cursor != bytes.startIndex {
                if inspected & 1023 == 0 { try Task.checkCancellation() }
                let before = bytes.index(before: cursor)
                inspected += 1
                if bytes[before] == 10 || bytes[before] == 13 { break }
                boundary -= 1
                cursor = before
            }
        }
        let globalContext = scan?.earliestOpenByte != nil
        let containerStart: Int? = switch lastBlock?.block {
        case .blockquote, .bulletList, .orderedList: lastBlock?.sourceRange?.lowerBound
        default: nil
        }
        let state = IncrementalParseState(
            safeUTF8Boundary: globalContext || hasReferences ? 0 : boundary,
            fence: scan?.fence.map { FenceState(marker: $0.marker, length: $0.length, startByte: $0.startByte + start) },
            inlineCodeDelimiterLength: scan?.inlineCodeDelimiterLength, math: scan?.math ?? .closed,
            lineContext: LineContext(lineStart: lineStart, containerStart: containerStart, endsInCarriageReturn: source.utf8.last == 13),
            sourceUTF8Count: self.utf8Count, sourceOrigin: self.origin, sourceWitness: self.witness(at: self.utf8Count), hasReferences: hasReferences,
            requiresGlobalContext: globalContext, endsInNewline: source.utf8.last == 10 || source.utf8.last == 13,
            containsMathSyntax: hasGlobalMath || previous?.state.containsMathSyntax == true,
            containsCodeSyntax: codeCandidate || previous?.state.containsCodeSyntax == true,
            containsReservedScalar: hasReserved || previous?.state.containsReservedScalar == true
        )
        let lineageChanges: [BlockLineage] = try (changedStart ..< changedEnd).map { index in
            try Task.checkCancellation()
            let node = document.blockStorage[index]
            let oldIndex = previous.flatMap { old -> Int? in
                guard index < old.document.blockStorage.count, old.document.blockStorage[index].lineage == node.lineage else { return nil }
                return index
            }
            return .init(oldIndex: oldIndex, newIndex: index, lineage: node.lineage)
        }
        metrics.recordMetadata(lineageChanges.count * MemoryLayout<BlockLineage>.stride)
        return IncrementalParseResult(
            document: document, state: state, fullParseReason: rejectedReason ?? reason, invalidationStartByte: start,
            changedBlockRange: changedStart ..< changedEnd, replacedPreviousRange: changedStart ..< replacedEnd,
            lineageChanges: lineageChanges, metrics: metrics
        )
    }
}

private func equivalentForSplice(_ old: ParsedBlockNode, _ new: ParsedBlockNode, metrics: inout ParseWorkMetrics) throws -> Bool {
    try Task.checkCancellation()
    metrics.recordMetadata(MemoryLayout<ParsedBlockNode>.stride)
    // `sourceAnchorEnd` has to be compared here and nowhere else: `lineage` is a
    // fixed-size identity key that deliberately hashes no end, and `==` ignores
    // it, so this guard is the only thing that stops a splice keeping a node
    // whose origin block's end has since moved. Source copy reads it as a
    // boundary proof, and a stale one truncates the bytes it hands over.
    guard old.sourceRange == new.sourceRange, old.fingerprint == new.fingerprint,
          old.sourceAnchorEnd == new.sourceAnchorEnd, old.lineage == new.lineage else { return false }
    let work = ParseWorkAccumulator(metrics, cancellable: true)
    defer { metrics = work.metrics }
    try accountComparison(new.block, work: work)
    return old.block == new.block
}

/// Charge the logical immutable inputs to opaque synthesized equality. Swift
/// can short-circuit shared buffers; the deterministic count remains conservative.
private func accountComparison(_ block: BlockNode, work: ParseWorkAccumulator) throws {
    try work.metadata(MemoryLayout<BlockNode>.stride)
    switch block {
    case .paragraph(let nodes), .heading(_, let nodes): try accountComparison(nodes, work: work)
    case .codeBlock(let language, let body): try work.map((language?.utf8.count ?? 0) + body.utf8.count)
    case .htmlBlock(let value), .mathBlock(let value): try work.map(value.utf8.count)
    case .blockquote(let blocks): for block in blocks {
            try accountComparison(block, work: work)
        }
    case .bulletList(let items), .orderedList(_, let items):
        for item in items {
            try work.metadata(MemoryLayout<ListItem>.stride); for block in item.blocks {
                try accountComparison(block, work: work)
            }
        }
    case .table(let columns, let head, let rows):
        try work.metadata(columns.count * MemoryLayout<ColumnAlignment>.stride)
        for cell in head {
            try accountComparison(cell.content, work: work)
        }
        for row in rows {
            for cell in row {
                try accountComparison(cell.content, work: work)
            }
        }
    case .thematicBreak: break
    }
}

private func accountComparison(_ nodes: [InlineNode], work: ParseWorkAccumulator) throws {
    for node in nodes {
        try work.metadata(MemoryLayout<InlineNode>.stride)
        switch node {
        case .text(let value), .inlineCode(let value), .html(let value), .math(let value): try work.map(value.utf8.count)
        case .emphasis(let children), .strong(let children), .strikethrough(let children): try accountComparison(children, work: work)
        case .link(let destination, let title, let children):
            try work.map(destination.utf8.count + (title?.utf8.count ?? 0))
            try accountComparison(children, work: work)
        case .image(let source, let alt):
            try work.map(source.utf8.count + alt.utf8.count)
        case .softBreak, .lineBreak: break
        }
    }
}
