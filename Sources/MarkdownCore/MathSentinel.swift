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
    public struct Segment: Sendable, Equatable {
        public let transformedStart: Int
        public let transformedEnd: Int
        public let originalStart: Int
        public let originalEnd: Int
        public let isAnchor: Bool
    }

    public struct SubstituteResult: Sendable {
        public let transformed: String
        public let table: [Entry]
        /// 按 transformedStart 升序、首尾相接、覆盖 `[0, transformed.utf8.count]` 的分段表。
        public let segments: [Segment]

        /// 把变换串里的 UTF-8 字节偏移映射回原始源码的 UTF-8 字节偏移（单调非降）。
        /// 仿射段内 1:1 平移；落在锚内部时夹到该公式原始区间的对应端
        /// （`atUpperBound == false` → 取原始下界；`true` → 取原始上界），
        /// 使「跨锚的块区间」在原始空间仍完整覆盖公式源码字节。
        public func originalByteOffset(forTransformed offset: Int, atUpperBound: Bool) -> Int {
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
        out.reserveCapacity(s.count)
        for ch in s {
            if ch == self.sentinel { out.append(self.sentinel); out.append(self.escapeMark) }
            else { out.append(ch) }
        }
        return out
    }

    /// 还原 escapeReservedScalar：S ESC → S。
    public static func unescapeReservedScalar(_ s: String) -> String {
        var out = ""
        var iter = s.makeIterator()
        var pending: Character?
        while let ch = pending ?? iter.next() {
            pending = nil
            if ch == self.sentinel {
                if let next = iter.next() {
                    if next == self.escapeMark { out.append(self.sentinel) }
                    else { out.append(self.sentinel); pending = next }
                } else { out.append(self.sentinel) }
            } else { out.append(ch) }
        }
        return out
    }

    /// 用 UTF-8 字节区间（来自 MathScanner）把公式替换成裸锚。
    /// 同时产出 transformed↔original 的字节分段映射（`segments`），
    /// 由与拼接 `pieces` 完全相同的边界推导，保证与变换串逐字节一致。
    public static func substitute(source: String, spans: [MathSpan]) -> SubstituteResult {
        let bytes = Array(source.utf8)
        var pieces: [String] = []
        var table: [Entry] = []
        var segments: [Segment] = []
        var cursor = 0 // 原始字节游标
        var xf = 0 // 变换串字节游标

        /// 把一段原始文本 escape 后的产物拆成「仿射段序列」：
        /// escapeReservedScalar 仅把每个 U+10FE00（原始 4 字节）替换为
        /// U+10FE00 U+10FE01（变换 8 字节），其余标量逐字节透传。
        /// 因此在每个被转义的 sentinel 标量处切一刀，段内即为同长平移。
        func appendText(originalStart: Int, originalEnd: Int) {
            guard originalStart < originalEnd else { return }
            let text = String(decoding: bytes[originalStart ..< originalEnd], as: UTF8.self)
            let escaped = self.escapeReservedScalar(text)
            pieces.append(escaped)
            var oRun = originalStart // 当前仿射段原始起点
            var origCursor = originalStart
            for scalar in text.unicodeScalars {
                let w = String(scalar).utf8.count
                if scalar == self.sentinel.unicodeScalars.first! {
                    // 收尾当前仿射段（不含此 sentinel）。
                    if origCursor > oRun {
                        let len = origCursor - oRun
                        segments.append(Segment(
                            transformedStart: xf,
                            transformedEnd: xf + len,
                            originalStart: oRun,
                            originalEnd: oRun + len,
                            isAnchor: false
                        ))
                        xf += len
                    }
                    // sentinel 自身：原始 4 字节 → 变换 8 字节（S + ESC）。
                    // 视作一个仿射段映射到该 sentinel 原始 4 字节（端点夹到 [oStart,oEnd]）。
                    segments.append(Segment(
                        transformedStart: xf,
                        transformedEnd: xf + 2 * w,
                        originalStart: origCursor,
                        originalEnd: origCursor + w,
                        isAnchor: true
                    ))
                    xf += 2 * w
                    origCursor += w
                    oRun = origCursor
                } else {
                    origCursor += w
                }
            }
            if origCursor > oRun {
                let len = origCursor - oRun
                segments.append(Segment(
                    transformedStart: xf,
                    transformedEnd: xf + len,
                    originalStart: oRun,
                    originalEnd: oRun + len,
                    isAnchor: false
                ))
                xf += len
            }
        }

        for span in spans {
            appendText(originalStart: cursor, originalEnd: span.range.lowerBound)
            let idx = table.count
            table.append(Entry(latex: span.latex, display: span.display))
            let anchor = "\(sentinel)\(idx)\(sentinel)"
            pieces.append(anchor)
            let anchorBytes = anchor.utf8.count
            segments.append(Segment(
                transformedStart: xf,
                transformedEnd: xf + anchorBytes,
                originalStart: span.range.lowerBound,
                originalEnd: span.range.upperBound,
                isAnchor: true
            ))
            xf += anchorBytes
            cursor = span.range.upperBound
        }
        appendText(originalStart: cursor, originalEnd: bytes.count)
        return SubstituteResult(transformed: pieces.joined(), table: table, segments: segments)
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
