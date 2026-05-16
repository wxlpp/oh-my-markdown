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

    public struct SubstituteResult: Sendable {
        public let transformed: String
        public let table: [Entry]
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
            if ch == sentinel { out.append(sentinel); out.append(escapeMark) }
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
            if ch == sentinel {
                if let next = iter.next() {
                    if next == escapeMark { out.append(sentinel) }
                    else { out.append(sentinel); pending = next }
                } else { out.append(sentinel) }
            } else { out.append(ch) }
        }
        return out
    }

    /// 用 UTF-8 字节区间（来自 MathScanner）把公式替换成裸锚。
    public static func substitute(source: String, spans: [MathSpan]) -> SubstituteResult {
        let bytes = Array(source.utf8)
        var pieces: [String] = []
        var table: [Entry] = []
        var cursor = 0
        for span in spans {
            let pre = String(decoding: bytes[cursor ..< span.range.lowerBound], as: UTF8.self)
            pieces.append(escapeReservedScalar(pre))
            let idx = table.count
            table.append(Entry(latex: span.latex, display: span.display))
            pieces.append("\(sentinel)\(idx)\(sentinel)")
            cursor = span.range.upperBound
        }
        let tail = String(decoding: bytes[cursor ..< bytes.count], as: UTF8.self)
        pieces.append(escapeReservedScalar(tail))
        return SubstituteResult(transformed: pieces.joined(), table: table)
    }

    /// 在字符串里定位裸锚（S<digits>S，紧跟其后不是 escapeMark）。
    public static func anchorRanges(in s: String) -> [Anchor] {
        var anchors: [Anchor] = []
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == sentinel {
                let afterOpen = s.index(after: i)
                // 转义对 S ESC：跳过，不是锚。
                if afterOpen < s.endIndex, s[afterOpen] == escapeMark {
                    i = s.index(after: afterOpen); continue
                }
                var j = afterOpen
                var digits = ""
                while j < s.endIndex, s[j].isASCII, s[j].isNumber { digits.append(s[j]); j = s.index(after: j) }
                if !digits.isEmpty, j < s.endIndex, s[j] == sentinel, let idx = Int(digits) {
                    anchors.append(Anchor(index: idx, range: i ..< s.index(after: j)))
                    i = s.index(after: j); continue
                }
            }
            i = s.index(after: i)
        }
        return anchors
    }
}
