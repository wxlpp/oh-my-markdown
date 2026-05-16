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
public enum MathScanner {
    public static func scan(_ source: String) -> [MathSpan] {
        let bytes = Array(source.utf8)
        let codeMask = codeRegionMask(source: source, byteCount: bytes.count)
        var spans: [MathSpan] = []
        var i = 0

        func isEscaped(_ idx: Int) -> Bool {
            var backslashes = 0
            var k = idx - 1
            while k >= 0, bytes[k] == 0x5C { backslashes += 1; k -= 1 }
            return backslashes % 2 == 1
        }

        func makeSpan(open: Int, openLen: Int, close: Int, closeLen: Int, display: Bool) -> MathSpan {
            let latexStart = open + openLen
            let latexBytes = Array(bytes[latexStart ..< close])
            let latex = String(decoding: latexBytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return MathSpan(range: open ..< (close + closeLen), latex: latex, display: display)
        }

        // 在 [from, end) 内找未被 code 覆盖、未转义的字面定界符序列。
        func findClose(_ marker: [UInt8], from: Int) -> Int? {
            var k = from
            while k + marker.count <= bytes.count {
                if !codeMask[k], !isEscaped(k), Array(bytes[k ..< k + marker.count]) == marker {
                    return k
                }
                k += 1
            }
            return nil
        }

        while i < bytes.count {
            if codeMask[i] || isEscaped(i) { i += 1; continue }
            let b = bytes[i]

            // $$ … $$（块级，贪婪优先于 $）
            if b == 0x24, i + 1 < bytes.count, bytes[i + 1] == 0x24 {
                if let close = findClose([0x24, 0x24], from: i + 2) {
                    spans.append(makeSpan(open: i, openLen: 2, close: close, closeLen: 2, display: true))
                    i = close + 2; continue
                }
                i += 2; continue
            }
            // $ … $（行内，闭合符不能是 $$ 的一部分；公式非空）
            if b == 0x24 {
                if let close = findClose([0x24], from: i + 1), close > i + 1 {
                    spans.append(makeSpan(open: i, openLen: 1, close: close, closeLen: 1, display: false))
                    i = close + 1; continue
                }
                i += 1; continue
            }
            // \[ … \] （块级）
            if b == 0x5C, i + 1 < bytes.count, bytes[i + 1] == 0x5B {
                if let close = findCloseBackslash(close: 0x5D, bytes: bytes, codeMask: codeMask, from: i + 2) {
                    spans.append(makeSpan(open: i, openLen: 2, close: close, closeLen: 2, display: true))
                    i = close + 2; continue
                }
                i += 2; continue
            }
            // \( … \) （行内）
            if b == 0x5C, i + 1 < bytes.count, bytes[i + 1] == 0x28 {
                if let close = findCloseBackslash(close: 0x29, bytes: bytes, codeMask: codeMask, from: i + 2) {
                    spans.append(makeSpan(open: i, openLen: 2, close: close, closeLen: 2, display: false))
                    i = close + 2; continue
                }
                i += 2; continue
            }
            i += 1
        }
        return spans
    }

    /// 找 `\)` 或 `\]`：闭合是「反斜杠 + 指定字节」，反斜杠本身不能被转义。
    private static func findCloseBackslash(
        close: UInt8, bytes: [UInt8], codeMask: [Bool], from: Int
    ) -> Int? {
        var k = from
        while k + 1 < bytes.count {
            if !codeMask[k], bytes[k] == 0x5C, bytes[k + 1] == close {
                var backslashes = 0, p = k - 1
                while p >= 0, bytes[p] == 0x5C { backslashes += 1; p -= 1 }
                if backslashes % 2 == 0 { return k }
            }
            k += 1
        }
        return nil
    }

    /// 标出落在围栏代码块 / 缩进代码块 / 行内代码内的字节（true = 在代码内，数学定界符忽略）。
    private static func codeRegionMask(source: String, byteCount: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: byteCount)
        let ns = source as NSString
        var loc = 0
        // 围栏代码块（``` 或 ~~~，缩进 ≤3）。
        while loc < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let indent = line.prefix(while: { $0 == " " }).count
            let content = indent <= 3 ? String(line.dropFirst(indent)) : line
            if let f = content.first, f == "`" || f == "~", content.prefix(while: { $0 == f }).count >= 3 {
                let fenceCount = content.prefix(while: { $0 == f }).count
                let start = utf8Offset(ns, lineRange.location)
                var cursor = lineRange.upperBound
                var end = byteCount
                while cursor < ns.length {
                    let r = ns.lineRange(for: NSRange(location: cursor, length: 0))
                    let l = ns.substring(with: r).trimmingCharacters(in: .newlines)
                    let li = l.prefix(while: { $0 == " " }).count
                    let lc = li <= 3 ? String(l.dropFirst(li)) : l
                    if lc.allSatisfy({ $0 == f || $0 == " " }), lc.prefix(while: { $0 == f }).count >= fenceCount {
                        end = utf8Offset(ns, r.upperBound)
                        cursor = r.upperBound
                        break
                    }
                    cursor = r.upperBound
                    end = utf8Offset(ns, r.upperBound)
                }
                for x in start ..< min(end, byteCount) { mask[x] = true }
                loc = cursor
                continue
            }
            loc = lineRange.upperBound
        }
        // 缩进代码块（行首 ≥4 空格且非列表续行；保守：整行 4 空格起）。
        loc = 0
        while loc < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let raw = ns.substring(with: lineRange)
            let body = raw.trimmingCharacters(in: .newlines)
            if body.hasPrefix("    "), !body.trimmingCharacters(in: .whitespaces).isEmpty {
                let s = utf8Offset(ns, lineRange.location)
                let e = utf8Offset(ns, lineRange.upperBound)
                for x in s ..< min(e, byteCount) { mask[x] = true }
            }
            loc = lineRange.upperBound
        }
        // 行内代码 `…`（同一行内成对反引号，反引号串长度匹配）。
        let codeSpan = try! NSRegularExpression(pattern: "(`+)(?:(?!\\1).)*\\1")
        codeSpan.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let s = utf8Offset(ns, m.range.location)
            let e = utf8Offset(ns, m.range.location + m.range.length)
            for x in s ..< min(e, byteCount) { mask[x] = true }
        }
        return mask
    }

    private static func utf8Offset(_ ns: NSString, _ utf16Loc: Int) -> Int {
        let prefix = ns.substring(to: min(utf16Loc, ns.length))
        return prefix.utf8.count
    }
}
