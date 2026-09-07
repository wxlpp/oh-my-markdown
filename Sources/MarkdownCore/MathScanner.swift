import Foundation

/// 源码中一段数学区段（基于 UTF-8 字节偏移）。
public struct MathSpan: Sendable, Equatable {
    /// 含定界符的 UTF-8 字节区间。
    public let range: Range<Int>
    /// 去掉定界符后的公式串。
    public let latex: String
    /// true = 块级（`$$` / `\[\]`），false = 行内（`$` / `\(\)`）。
    public let display: Bool
}

/// 在原始 Markdown 源码上扫描数学区段。纯函数，不修改输入。
/// 跳过围栏代码块 / 缩进代码块 / 行内代码；`\$` 转义不作定界符；未配对当字面。
///
/// 行内 `$ … $` 采用 pandoc Markdown `tex_math_dollars` / remark-math 的定界符
/// 规则（**不是**贪婪「下一个 `$` 即配对」），以避免货币写法（`$5.00`、
/// `cost $5 vs $9`）被当行内数学定界符贪婪配对、与其后真实公式的开界 `$`
/// 误配而吞掉整段（含代码块、标题）。具体：
///   1. 开界 `$` 后必须紧跟非空白字节（空格/制表/换行/回车之外）；
///   2. 闭界 `$` 前一字节非空白，且其后一字节（若存在）非 ASCII 数字；
///   3. 行内 `$ … $` 不得跨段落空行（行边界 = `\n` / `\r\n` / `\r`）；
///   4. 公式非空（`close > openContentStart`）。
/// 找不到合规闭界 → 该开界 `$` 退为字面文本（`i += 1` 继续）。
/// `$$…$$` / `\(…\)` / `\[…\]` 规则、代码区掩码、转义、`$$` 块级优先、
/// 非空约束均不受此规则影响。
public enum MathScanner {
    package struct ScanResult {
        package let spans: [MathSpan]
        package let math: MathDelimiterState
        package let earliestOpenByte: Int?
        package let fence: FenceState?
        package let inlineCodeDelimiterLength: Int?
    }

    public static func scan(_ source: String) -> [MathSpan] {
        let work = ParseWorkAccumulator(cancellable: false)
        return try! self.scan(source, codeRegionsNeeded: true, work: work).spans
    }

    package static func scan(_ source: String, metrics: inout ParseWorkMetrics, codeRegionsNeeded: Bool = true, checkCancellation: @escaping ParseCancellationCheck = { try Task.checkCancellation() }) throws -> [MathSpan] {
        let work = ParseWorkAccumulator(metrics, cancellable: true, checkCancellation: checkCancellation)
        defer { metrics = work.metrics }
        return try self.scan(source, codeRegionsNeeded: codeRegionsNeeded, work: work).spans
    }

    private static func scan(_ source: String, codeRegionsNeeded: Bool, work: ParseWorkAccumulator) throws -> ScanResult {
        try work.check()
        let bytes = Array(source.utf8)
        try work.copy(bytes.count)
        return try self.scan(bytes, codeRegionsNeeded: codeRegionsNeeded, work: work)
    }

    package static func scan(bytes: [UInt8], metrics: inout ParseWorkMetrics, codeRegionsNeeded: Bool) throws -> [MathSpan] {
        let work = ParseWorkAccumulator(metrics, cancellable: true)
        defer { metrics = work.metrics }
        return try self.scan(bytes, codeRegionsNeeded: codeRegionsNeeded, work: work).spans
    }

    package static func analyze<Bytes: RandomAccessCollection>(bytes: Bytes, metrics: inout ParseWorkMetrics, codeRegionsNeeded: Bool) throws -> ScanResult where Bytes.Element == UInt8, Bytes.Index == Int {
        let work = ParseWorkAccumulator(metrics, cancellable: true)
        defer { metrics = work.metrics }
        return try self.scan(bytes, codeRegionsNeeded: codeRegionsNeeded, work: work)
    }

    private static func scan<Bytes: RandomAccessCollection>(_ bytes: Bytes, codeRegionsNeeded: Bool, work: ParseWorkAccumulator) throws -> ScanResult where Bytes.Element == UInt8, Bytes.Index == Int {
        try work.check()
        let code = codeRegionsNeeded ? try self.codeRegions(bytes, work: work) : ([], nil, nil)
        let regions = code.0
        var spans: [MathSpan] = []
        var earliestOpen: Int?
        var math: MathDelimiterState = .closed
        var regionIndex = 0
        var index = 0
        var closedByBlockBoundary = false
        func isCode(_ offset: Int) -> Bool {
            var lower = 0
            var upper = regions.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if regions[middle].upperBound <= offset { lower = middle + 1 }
                else { upper = middle }
            }
            return lower < regions.count && regions[lower].contains(offset)
        }
        func escaped(_ offset: Int) throws -> Bool {
            var cursor = offset
            var count = 0
            while cursor > 0, bytes[cursor - 1] == 92 {
                try work.scan()
                cursor -= 1; count += 1
            }
            return count % 2 == 1
        }
        func whitespace(_ byte: UInt8) -> Bool {
            byte == 32 || byte == 9 || byte == 10 || byte == 13
        }
        func close(_ marker: [UInt8], from start: Int, inlineDollar: Bool = false) throws -> Int? {
            closedByBlockBoundary = false
            var cursor = start
            while cursor <= bytes.count - marker.count {
                try work.scan()
                if isCode(cursor) { closedByBlockBoundary = true; return nil }
                if inlineDollar, bytes[cursor] == 10 || bytes[cursor] == 13 {
                    var next = cursor + 1
                    if bytes[cursor] == 13, next < bytes.count, bytes[next] == 10 { next += 1 }
                    while next < bytes.count, bytes[next] == 32 || bytes[next] == 9 {
                        try work.scan(); next += 1
                    }
                    if next < bytes.count, bytes[next] == 10 || bytes[next] == 13 { closedByBlockBoundary = true; return nil }
                }
                let matches = bytes[cursor] == marker[0]
                    && (marker.count == 1 || bytes[cursor + 1] == marker[1])
                if matches, try !escaped(cursor) {
                    if inlineDollar {
                        let nextDollar = cursor + 1 < bytes.count && bytes[cursor + 1] == 36
                        let afterDigit = cursor + 1 < bytes.count && (48 ... 57).contains(bytes[cursor + 1])
                        if cursor > start, !whitespace(bytes[cursor - 1]), !nextDollar, !afterDigit { return cursor }
                    } else { return cursor }
                }
                cursor += 1
            }
            return nil
        }
        func span(open: Int, openLength: Int, close: Int, closeLength: Int, display: Bool) throws -> MathSpan {
            let range = open + openLength ..< close
            let decoded = String(decoding: bytes[range], as: UTF8.self)
            try work.copy(range.count)
            let latex: String
            if decoded.unicodeScalars.first.map(CharacterSet.whitespacesAndNewlines.contains) == true
                || decoded.unicodeScalars.last.map(CharacterSet.whitespacesAndNewlines.contains) == true {
                try work.scan(range.count)
                latex = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                try work.copy(latex.utf8.count)
            } else { latex = decoded }
            try work.metadata(MemoryLayout<MathSpan>.stride)
            return MathSpan(range: open ..< close + closeLength, latex: latex, display: display)
        }
        while index < bytes.count {
            try work.scan()
            while regionIndex < regions.count, regions[regionIndex].upperBound <= index {
                regionIndex += 1
            }
            if regionIndex < regions.count, regions[regionIndex].contains(index) {
                index = regions[regionIndex].upperBound
                continue
            }
            if try escaped(index) { index += 1; continue }
            let byte = bytes[index]
            closedByBlockBoundary = false
            if byte == 36, index + 1 < bytes.count, bytes[index + 1] == 36 {
                if let end = try close([36, 36], from: index + 2) {
                    try spans.append(span(open: index, openLength: 2, close: end, closeLength: 2, display: true))
                    index = end + 2; continue
                }
                if earliestOpen == nil, !closedByBlockBoundary { earliestOpen = index; math = .doubleDollar }
                index += 2; continue
            }
            if byte == 36, index + 1 < bytes.count, !whitespace(bytes[index + 1]),
               let end = try close([36], from: index + 1, inlineDollar: true) {
                try spans.append(span(open: index, openLength: 1, close: end, closeLength: 1, display: false))
                index = end + 1; continue
            }
            if byte == 36, earliestOpen == nil, !closedByBlockBoundary,
               index + 1 == bytes.count || !whitespace(bytes[index + 1]) {
                earliestOpen = index; math = .dollar
            }
            if byte == 92, index + 1 < bytes.count, bytes[index + 1] == 40 || bytes[index + 1] == 91 {
                let display = bytes[index + 1] == 91
                if let end = try close([92, display ? 93 : 41], from: index + 2) {
                    try spans.append(span(open: index, openLength: 2, close: end, closeLength: 2, display: display))
                    index = end + 2; continue
                }
                if earliestOpen == nil, !closedByBlockBoundary { earliestOpen = index; math = display ? .bracket : .paren }
                index += 2; continue
            }
            index += 1
        }
        return ScanResult(spans: spans, math: math, earliestOpenByte: earliestOpen, fence: code.1, inlineCodeDelimiterLength: code.2)
    }

    public static func codeRegionMask(source: String) -> [Bool] {
        let work = ParseWorkAccumulator(cancellable: false)
        let bytes = Array(source.utf8)
        let regions = try! self.codeRegions(bytes, work: work).0
        var mask = [Bool](repeating: false, count: bytes.count)
        for range in regions {
            for index in range {
                mask[index] = true
            }
        }
        return mask
    }

    /// Byte-based regions avoid NSString bridging, UTF-16 prefix arrays and
    /// a source-sized Bool mask in the admitted production parse.
    private static func codeRegions<Bytes: RandomAccessCollection>(_ bytes: Bytes, work: ParseWorkAccumulator) throws -> ([Range<Int>], FenceState?, Int?) where Bytes.Element == UInt8, Bytes.Index == Int {
        var regions: [Range<Int>] = []
        var position = 0
        var fence: (UInt8, Int, Int)?
        var listContext = false
        var inlineDelimiter: Int?
        func appendRegion(_ range: Range<Int>) throws {
            guard !range.isEmpty else { return }
            if let last = regions.last, last.upperBound == range.lowerBound {
                regions[regions.count - 1] = last.lowerBound ..< range.upperBound
            } else {
                regions.append(range)
                try work.metadata(MemoryLayout<Range<Int>>.stride)
            }
        }
        while position < bytes.count {
            try work.check()
            let start = position
            var end = position
            var hasBacktick = false
            while end < bytes.count, bytes[end] != 10, bytes[end] != 13 {
                try work.scan()
                hasBacktick = hasBacktick || bytes[end] == 96
                end += 1
            }
            var next = end
            if next < bytes.count {
                try work.scan(); next += 1
                if bytes[end] == 13, next < bytes.count, bytes[next] == 10 { try work.scan(); next += 1 }
            }
            position = next
            var content = start
            while content < end, bytes[content] == 32 {
                try work.scan(); content += 1
            }
            let indent = content - start
            if content == end { inlineDelimiter = nil }
            if let active = fence {
                try appendRegion(start ..< next)
                if indent <= 3 {
                    var markerEnd = content
                    while markerEnd < end, bytes[markerEnd] == active.0 {
                        try work.scan(); markerEnd += 1
                    }
                    if markerEnd - content >= active.1 {
                        var trailing = markerEnd
                        while trailing < end, bytes[trailing] == 32 || bytes[trailing] == 9 {
                            try work.scan(); trailing += 1
                        }
                        if trailing == end { fence = nil }
                    }
                }
                continue
            }
            if indent <= 3, content < end, bytes[content] == 96 || bytes[content] == 126 {
                let marker = bytes[content]
                var markerEnd = content
                while markerEnd < end, bytes[markerEnd] == marker {
                    try work.scan(); markerEnd += 1
                }
                if markerEnd - content >= 3 {
                    fence = (marker, markerEnd - content, start)
                    try appendRegion(start ..< next)
                    continue
                }
            }
            var isList = false
            var thematic = false
            if indent <= 3, content < end {
                let marker = bytes[content]
                if marker == 45 || marker == 42 || marker == 95 {
                    var cursor = content
                    var count = 0
                    while cursor < end, bytes[cursor] == marker || bytes[cursor] == 32 || bytes[cursor] == 9 {
                        try work.scan()
                        if bytes[cursor] == marker { count += 1 }
                        cursor += 1
                    }
                    thematic = cursor == end && count >= 3
                }
                var markerEnd = content
                if marker == 45 || marker == 43 || marker == 42 { markerEnd += 1 }
                else {
                    while markerEnd < end, markerEnd - content < 9, (48 ... 57).contains(bytes[markerEnd]) {
                        try work.scan(); markerEnd += 1
                    }
                    if markerEnd > content, markerEnd < end, bytes[markerEnd] == 46 || bytes[markerEnd] == 41 { markerEnd += 1 }
                    else { markerEnd = content }
                }
                isList = markerEnd > content && (markerEnd == end || bytes[markerEnd] == 32 || bytes[markerEnd] == 9)
            }
            if thematic { if indent == 0 { listContext = false } }
            else if isList { listContext = true }
            else if content < end, indent == 0 { listContext = false }
            if indent >= 4, content < end, !listContext {
                try appendRegion(start ..< next)
                continue
            }
            guard hasBacktick else { continue }
            var cursor = start
            while cursor < end {
                try work.scan()
                guard bytes[cursor] == 96 else { cursor += 1; continue }
                let open = cursor
                while cursor < end, bytes[cursor] == 96 {
                    try work.scan(); cursor += 1
                }
                let length = cursor - open
                var close = cursor
                var found = false
                while close < end {
                    try work.scan()
                    if bytes[close] == 96 {
                        var runEnd = close
                        while runEnd < end, bytes[runEnd] == 96 {
                            try work.scan(); runEnd += 1
                        }
                        if runEnd - close >= length {
                            try appendRegion(open ..< close + length)
                            cursor = close + length
                            found = true
                            inlineDelimiter = nil
                            break
                        }
                        close = runEnd
                    } else { close += 1 }
                }
                if !found { inlineDelimiter = length; cursor = open + length }
            }
        }
        return (regions, fence.map { FenceState(marker: $0.0, length: $0.1, startByte: $0.2) }, inlineDelimiter)
    }
}
