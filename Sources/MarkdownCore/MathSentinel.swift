import Foundation

/// 数学哨兵编解码。锚形如 `S<index>S`，其中 S = 保留标量 U+10FE00。
/// 替换前先把源码里已存在的 S 转义为 `S` + ESC(U+10FE01)，使「能存活的裸 S 锚」
/// 一定由本类注入，用户文本无法伪造或碰撞（spec §4.2、§11.7）。
public enum MathSentinel {
    public static let sentinel: Character = "\u{10FE00}"
    private static let escapeMark: Character = "\u{10FE01}"

    public struct Entry: Sendable, Equatable {
        public let latex: String
        public let display: Bool
    }

    /// 变换串↔原始源码的字节区间对应（单调、覆盖整条变换串）。
    /// 非锚段为仿射：`original = transformedStart 内的偏移 + originalStart`（同长，逐字节 1:1）。
    /// 锚段：变换串里的 `S<idx>S` 整体对应原始公式区间 `originalStart ..< originalEnd`。
    struct Segment: Equatable {
        let transformedStart: Int
        let transformedEnd: Int
        let originalStart: Int
        let originalEnd: Int
        let isAnchor: Bool
    }

    public struct SubstituteResult: Sendable {
        public let transformed: String
        public let table: [Entry]
        /// 按 transformedStart 升序、首尾相接、覆盖 `[0, transformed.utf8.count]` 的分段表。
        let segments: [Segment]

        /// 把变换串里的 UTF-8 字节偏移映射回原始源码的 UTF-8 字节偏移（单调非降）。
        /// 仿射段内 1:1 平移；落在锚内部时夹到该公式原始区间的对应端
        /// （`atUpperBound == false` → 取原始下界；`true` → 取原始上界），
        /// 使「跨锚的块区间」在原始空间仍完整覆盖公式源码字节。
        func originalByteOffset(forTransformed offset: Int, atUpperBound: Bool) -> Int {
            guard let last = segments.last else { return offset }
            if offset <= 0 { return self.segments.first?.originalStart ?? 0 }
            if offset >= last.transformedEnd { return last.originalEnd }
            // 单调分段上的二分：找包含该 transformed 偏移的段。
            var lo = 0
            var hi = self.segments.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if offset < self.segments[mid].transformedEnd { hi = mid }
                else { lo = mid + 1 }
            }
            let seg = self.segments[lo]
            if seg.isAnchor {
                return atUpperBound ? seg.originalEnd : seg.originalStart
            }
            // 仿射段：同长，逐字节平移。
            return seg.originalStart + (offset - seg.transformedStart)
        }
    }

    public struct Anchor: Sendable, Equatable {
        public let index: Int
        public let range: Range<String.Index>
    }

    /// 把源码中已存在的 sentinel 转义：S → S ESC。
    /// ESC 仅由本类在 S 之后注入；unescape 不依赖此前提——用户文本中孤立的 ESC 原样透传。
    public static func escapeReservedScalar(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            out.unicodeScalars.append(scalar)
            if scalar.value == 0x10FE00 { out.unicodeScalars.append("\u{10FE01}") }
        }
        return out
    }

    /// 还原 escapeReservedScalar：S ESC → S。
    public static func unescapeReservedScalar(_ s: String) -> String {
        let work = ParseWorkAccumulator(cancellable: false)
        return try! self.decodeText(s, tableCount: 0, work: work).map {
            if case .literal(let value) = $0 { return value }; return ""
        }.joined()
    }

    package enum DecodedPiece { case literal(String), entry(Int) }
    private struct DecodeEvent {
        let range: Range<Int>
        let entry: Int? // nil removes only an inserted ESC scalar
    }

    package static func decodeText(_ source: String, tableCount: Int, work: ParseWorkAccumulator) throws -> [DecodedPiece] {
        if let result = try source.utf8.withContiguousStorageIfAvailable({ bytes in
            try self.decodeText(source, bytes: bytes, tableCount: tableCount, work: work)
        }) { return result }
        let bytes = Array(source.utf8)
        try work.copy(bytes.count)
        return try bytes.withUnsafeBufferPointer { try self.decodeText(source, bytes: $0, tableCount: tableCount, work: work) }
    }

    private static func decodeText(
        _ source: String,
        bytes: UnsafeBufferPointer<UInt8>,
        tableCount: Int,
        work: ParseWorkAccumulator
    ) throws -> [DecodedPiece] {
        var events: [DecodeEvent] = []
        var index = 0
        func marker(at offset: Int, last: UInt8) -> Bool {
            offset + 4 <= bytes.count && bytes[offset] == 0xF4 && bytes[offset + 1] == 0x8F
                && bytes[offset + 2] == 0xB8 && bytes[offset + 3] == last
        }
        while index < bytes.count {
            try work.map()
            guard marker(at: index, last: 0x80) else { index += 1; continue }
            if marker(at: index + 4, last: 0x81) {
                try work.arrayGrowth(events)
                events.append(DecodeEvent(range: index + 4 ..< index + 8, entry: nil))
                try work.metadata(MemoryLayout<DecodeEvent>.stride)
                try work.map(7)
                index += 8
                continue
            }
            var cursor = index + 4
            var number = 0
            var overflow = false
            while cursor < bytes.count, bytes[cursor] >= 48, bytes[cursor] <= 57 {
                try work.map()
                let (product, multiplied) = number.multipliedReportingOverflow(by: 10)
                let (sum, added) = product.addingReportingOverflow(Int(bytes[cursor] - 48))
                overflow = overflow || multiplied || added
                number = sum
                cursor += 1
            }
            if cursor > index + 4, !overflow, number < tableCount, marker(at: cursor, last: 0x80) {
                try work.arrayGrowth(events)
                events.append(DecodeEvent(range: index ..< cursor + 4, entry: number))
                try work.metadata(MemoryLayout<DecodeEvent>.stride)
                try work.map(7)
                index = cursor + 4
            } else { index += 1 }
        }
        guard !events.isEmpty else { return [.literal(source)] }
        work.decodedEventCount = ParseWorkMetrics.saturatingAdd(work.decodedEventCount, events.count)
        var pieces: [DecodedPiece] = []
        var ranges: [Range<Int>] = []
        pieces.reserveCapacity(ParseWorkMetrics.saturatingAdd(ParseWorkMetrics.saturatingMultiply(events.count, 2), 1))
        ranges.reserveCapacity(events.count + 1)
        var cursor = 0
        func flush() throws {
            guard !ranges.isEmpty else { return }
            var count = 0
            for range in ranges {
                count += range.count; try work.metadata(MemoryLayout<Range<Int>>.stride)
            }
            let literal = try String(unsafeUninitializedCapacity: count) { output in
                var target = 0
                for range in ranges {
                    for index in range {
                        output[target] = bytes[index]; target += 1; try work.copy(1)
                    }
                }
                return target
            }
            try work.arrayGrowth(pieces)
            pieces.append(.literal(literal))
            try work.metadata(MemoryLayout<DecodedPiece>.stride)
            ranges.removeAll(keepingCapacity: true)
        }
        for event in events {
            try work.check()
            if cursor < event.range.lowerBound { try work.arrayGrowth(ranges); ranges.append(cursor ..< event.range.lowerBound) }
            if let entry = event.entry {
                try flush()
                try work.arrayGrowth(pieces)
                pieces.append(.entry(entry))
                try work.metadata(MemoryLayout<DecodedPiece>.stride)
            }
            cursor = event.range.upperBound
        }
        if cursor < bytes.count { try work.arrayGrowth(ranges); ranges.append(cursor ..< bytes.count) }
        try flush()
        return pieces
    }

    /// 用 UTF-8 字节区间（来自 MathScanner）把公式替换成裸锚。
    /// 同时产出 transformed↔original 的字节分段映射（`segments`），
    /// 由与拼接 `pieces` 完全相同的边界推导，保证与变换串逐字节一致。
    public static func substitute(source: String, spans: [MathSpan]) -> SubstituteResult {
        let work = ParseWorkAccumulator(cancellable: false)
        return try! self.substitute(source: source, bytes: Array(source.utf8), spans: spans, work: work)
    }

    package static func substitute(source: String, spans: [MathSpan], metrics: inout ParseWorkMetrics) throws -> SubstituteResult {
        let bytes = Array(source.utf8)
        metrics.materializationBytes = ParseWorkMetrics.saturatingAdd(metrics.materializationBytes, bytes.count)
        return try self.substitute(source: source, bytes: bytes, spans: spans, metrics: &metrics)
    }

    package static func substitute<Bytes: RandomAccessCollection>(source: String, bytes: Bytes, spans: [MathSpan], hasReserved: Bool = true, metrics: inout ParseWorkMetrics) throws -> SubstituteResult where Bytes.Element == UInt8, Bytes.Index == Int {
        let work = ParseWorkAccumulator(metrics, cancellable: true)
        defer { metrics = work.metrics }
        return try self.substitute(source: source, bytes: bytes, spans: spans, hasReserved: hasReserved, work: work)
    }

    private static func substitute<Bytes: RandomAccessCollection>(source: String, bytes: Bytes, spans: [MathSpan], hasReserved: Bool = true, work: ParseWorkAccumulator) throws -> SubstituteResult where Bytes.Element == UInt8, Bytes.Index == Int {
        try work.check()
        let reserved: [UInt8] = [0xF4, 0x8F, 0xB8, 0x80]
        let escaped: [UInt8] = [0xF4, 0x8F, 0xB8, 0x81]
        var table: [Entry] = []
        var segments: [Segment] = []
        var replacements: [(Range<Int>, [UInt8])] = []
        table.reserveCapacity(spans.count)
        replacements.reserveCapacity(spans.count)
        var cursor = 0
        var spanIndex = 0
        var capacity = bytes.count
        while cursor < bytes.count {
            if !hasReserved {
                guard spanIndex < spans.count else { break }
                cursor = spans[spanIndex].range.lowerBound
            }
            try work.scan()
            if spanIndex < spans.count, spans[spanIndex].range.lowerBound == cursor {
                let span = spans[spanIndex]
                let anchor = Array("\(sentinel)\(table.count)\(self.sentinel)".utf8)
                guard span.range.lowerBound >= 0, span.range.upperBound <= bytes.count else { throw IncrementalSourceBuffer.BufferError.invalidBoundary }
                let (nextCapacity, overflow) = capacity.addingReportingOverflow(anchor.count - span.range.count)
                guard !overflow else { throw IncrementalSourceBuffer.BufferError.sizeOverflow }
                capacity = nextCapacity
                try work.arrayGrowth(replacements)
                try work.arrayGrowth(table)
                replacements.append((span.range, anchor))
                table.append(Entry(latex: span.latex, display: span.display))
                try work.copy(2 * anchor.count) // interpolated String and its UTF-8 Array
                try work.metadata(MemoryLayout<Entry>.stride + MemoryLayout<(Range<Int>, [UInt8])>.stride)
                cursor = span.range.upperBound
                spanIndex += 1
            } else if cursor + 4 <= bytes.count, bytes[cursor ..< cursor + 4].elementsEqual(reserved) {
                let (nextCapacity, overflow) = capacity.addingReportingOverflow(4)
                guard !overflow else { throw IncrementalSourceBuffer.BufferError.sizeOverflow }
                capacity = nextCapacity
                try work.arrayGrowth(replacements)
                replacements.append((cursor ..< cursor + 4, reserved + escaped))
                try work.copy(8)
                try work.metadata(MemoryLayout<(Range<Int>, [UInt8])>.stride)
                cursor += 4
            } else { cursor += 1 }
        }
        guard !replacements.isEmpty else {
            return SubstituteResult(transformed: source, table: [], segments: [])
        }
        segments.reserveCapacity(ParseWorkMetrics.saturatingAdd(ParseWorkMetrics.saturatingMultiply(replacements.count, 2), 1))
        let transformed = try String(unsafeUninitializedCapacity: capacity) { output in
            var original = 0
            var written = 0
            func appendText(until end: Int) throws {
                guard original < end else { return }
                let originalStart = original
                let transformedStart = written
                while original < end {
                    output[written] = bytes[original]
                    written += 1; original += 1
                    try work.copy(1)
                }
                try work.arrayGrowth(segments)
                segments.append(Segment(
                    transformedStart: transformedStart,
                    transformedEnd: written,
                    originalStart: originalStart,
                    originalEnd: original,
                    isAnchor: false
                ))
                try work.metadata(MemoryLayout<Segment>.stride)
            }
            for (range, replacement) in replacements {
                try work.check()
                try appendText(until: range.lowerBound)
                let transformedStart = written
                for byte in replacement {
                    output[written] = byte
                    written += 1
                    try work.copy(1)
                }
                try work.arrayGrowth(segments)
                segments.append(Segment(
                    transformedStart: transformedStart,
                    transformedEnd: written,
                    originalStart: range.lowerBound,
                    originalEnd: range.upperBound,
                    isAnchor: true
                ))
                try work.metadata(MemoryLayout<Segment>.stride)
                original = range.upperBound
            }
            try appendText(until: bytes.count)
            return written
        }
        return SubstituteResult(transformed: transformed, table: table, segments: segments)
    }

    /// 在字符串里定位裸锚（S<digits>S，紧跟其后不是 escapeMark）。
    public static func anchorRanges(in s: String) -> [Anchor] {
        var anchors: [Anchor] = []
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == self.sentinel {
                let afterOpen = s.index(after: i)
                // 转义对 S ESC：跳过，不是锚。
                if afterOpen < s.endIndex, s[afterOpen] == self.escapeMark {
                    i = s.index(after: afterOpen); continue
                }
                var j = afterOpen
                var digits = ""
                while j < s.endIndex, s[j].isASCII, s[j].isNumber {
                    digits.append(s[j]); j = s.index(after: j)
                }
                if !digits.isEmpty, j < s.endIndex, s[j] == self.sentinel, let idx = Int(digits) {
                    anchors.append(Anchor(index: idx, range: i ..< s.index(after: j)))
                    i = s.index(after: j); continue
                }
            }
            i = s.index(after: i)
        }
        return anchors
    }
}
