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
        let codeMask = self.codeRegionMask(source: source, byteCount: bytes.count)
        var spans: [MathSpan] = []
        var i = 0

        func isEscaped(_ idx: Int) -> Bool {
            var backslashes = 0
            var k = idx - 1
            while k >= 0, bytes[k] == 0x5C {
                backslashes += 1; k -= 1
            }
            return backslashes % 2 == 1
        }

        func makeSpan(open: Int, openLen: Int, close: Int, closeLen: Int, display: Bool) -> MathSpan {
            let latexStart = open + openLen
            let latexBytes = Array(bytes[latexStart ..< close])
            let latex = String(decoding: latexBytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return MathSpan(range: open ..< (close + closeLen), latex: latex, display: display)
        }

        /// 在 [from, end) 内找未被 code 覆盖、未转义的字面定界符序列。
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
                while p >= 0, bytes[p] == 0x5C {
                    backslashes += 1; p -= 1
                }
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
        // UTF-16 码元偏移 → UTF-8 字节前缀和表：u8[k] = source 前 k 个 UTF-16 码元的 UTF-8 字节数。
        // 索引必须是 UTF-16 码元偏移，且需对齐到字符边界（不可落在代理对中间）。
        let u8 = self.utf16ToUTF8PrefixSum(source: source, utf16Length: ns.length)
        @inline(__always) func u8at(_ utf16Loc: Int) -> Int {
            u8[min(max(utf16Loc, 0), ns.length)]
        }

        var loc = 0
        // 围栏代码块（``` 或 ~~~，缩进 ≤3）。
        while loc < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let indent = line.prefix(while: { $0 == " " }).count
            let content = indent <= 3 ? String(line.dropFirst(indent)) : line
            if let f = content.first, f == "`" || f == "~", content.prefix(while: { $0 == f }).count >= 3 {
                let fenceCount = content.prefix(while: { $0 == f }).count
                let start = u8at(lineRange.location)
                var cursor = lineRange.upperBound
                var end = byteCount
                while cursor < ns.length {
                    let r = ns.lineRange(for: NSRange(location: cursor, length: 0))
                    let l = ns.substring(with: r).trimmingCharacters(in: .newlines)
                    let li = l.prefix(while: { $0 == " " }).count
                    let lc = li <= 3 ? String(l.dropFirst(li)) : l
                    if lc.allSatisfy({ $0 == f || $0 == " " }), lc.prefix(while: { $0 == f }).count >= fenceCount {
                        end = u8at(r.upperBound)
                        cursor = r.upperBound
                        break
                    }
                    cursor = r.upperBound
                    end = u8at(r.upperBound)
                }
                for x in start ..< min(end, byteCount) {
                    mask[x] = true
                }
                loc = cursor
                continue
            }
            loc = lineRange.upperBound
        }
        // 缩进代码块（行首 ≥4 空格）。
        // 廉价启发：4 空格缩进行只有在「不处于列表上下文」时才算缩进代码块；
        // 列表续行（列表项内的缩进续行）不是 CommonMark 代码块，不能屏蔽其中的公式。
        // 列表上下文：遇到列表标记行（`^\s{0,3}([-+*]|\d{1,9}[.)])\s`）即开启，
        // 跨空行与缩进续行保持，直到出现一行 indent 0 的非空、非列表行才结束。
        loc = 0
        var listContext = false
        while loc < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let raw = ns.substring(with: lineRange)
            let body = raw.trimmingCharacters(in: .newlines)
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            let isBlank = trimmed.isEmpty
            let leadingSpaces = body.prefix(while: { $0 == " " }).count

            if self.isThematicBreak(body) {
                // 主题分隔线（`* * *` / `---` / `___`，缩进 ≤3）不是列表标记，
                // 不应开启/延续列表上下文，否则其后 4 空格块会被误当列表续行而非缩进代码块。
                if leadingSpaces == 0 { listContext = false }
            } else if self.isList(body) {
                listContext = true
            } else if !isBlank, leadingSpaces == 0 {
                // indent 0 的非空、非列表行 → 退出列表上下文。
                listContext = false
            }
            // 空行与缩进续行：保持当前 listContext 不变。

            if body.hasPrefix("    "), !isBlank, !listContext {
                let s = u8at(lineRange.location)
                let e = u8at(lineRange.upperBound)
                for x in s ..< min(e, byteCount) {
                    mask[x] = true
                }
            }
            loc = lineRange.upperBound
        }
        // 行内代码 `…`（同一行内成对反引号，反引号串长度匹配）。
        let codeSpan = try! NSRegularExpression(pattern: "(`+)(?:(?!\\1).)*\\1")
        codeSpan.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let s = u8at(m.range.location)
            let e = u8at(m.range.location + m.range.length)
            for x in s ..< min(e, byteCount) {
                mask[x] = true
            }
        }
        return mask
    }

    /// 该行是否是主题分隔线（CommonMark thematic break）：缩进 ≤3，去掉空白后
    /// 仅由同一种标记符（`*` / `-` / `_`）重复 ≥3 次构成（标记之间可夹空格）。
    /// 窄分类器，仅用于在列表上下文判定里把 `* * *` 这类行排除出列表标记，
    /// 不构建块解析器。
    private static func isThematicBreak(_ line: String) -> Bool {
        let scalars = Array(line.unicodeScalars)
        var idx = 0
        var leading = 0
        while idx < scalars.count, scalars[idx] == " ", leading < 4 {
            idx += 1; leading += 1
        }
        if leading > 3 { return false }
        guard idx < scalars.count else { return false }
        let marker = scalars[idx]
        guard marker == "*" || marker == "-" || marker == "_" else { return false }
        var markerCount = 0
        while idx < scalars.count {
            let c = scalars[idx]
            if c == marker { markerCount += 1 }
            else if c != " " && c != "\t" { return false }
            idx += 1
        }
        return markerCount >= 3
    }

    /// 该行是否是无序/有序列表标记行：`^\s{0,3}([-+*]|\d{1,9}[.)])\s`。
    private static func isList(_ line: String) -> Bool {
        let scalars = Array(line.unicodeScalars)
        var idx = 0
        var leading = 0
        while idx < scalars.count, scalars[idx] == " ", leading < 4 {
            idx += 1; leading += 1
        }
        if leading > 3 { return false }
        guard idx < scalars.count else { return false }
        let c = scalars[idx]
        if c == "-" || c == "+" || c == "*" {
            idx += 1
        } else if c >= "0", c <= "9" {
            var digits = 0
            while idx < scalars.count, scalars[idx] >= "0", scalars[idx] <= "9", digits < 9 {
                idx += 1; digits += 1
            }
            guard idx < scalars.count, scalars[idx] == "." || scalars[idx] == ")" else { return false }
            idx += 1
        } else {
            return false
        }
        // 标记后必须紧跟空白（空格/制表符），或为行尾（空列表项）。
        guard idx < scalars.count else { return true }
        let n = scalars[idx]
        return n == " " || n == "\t"
    }

    /// 构建 UTF-16 码元 → UTF-8 字节的前缀和表，长度为 utf16Length + 1，O(n) 一次遍历。
    /// 每个 Unicode 标量推进 `String(scalar).utf16.count` 个 UTF-16 索引并累加
    /// `String(scalar).utf8.count` 字节；表索引为 UTF-16 码元偏移、须字符对齐。
    private static func utf16ToUTF8PrefixSum(source: String, utf16Length: Int) -> [Int] {
        var table = [Int](repeating: 0, count: utf16Length + 1)
        var u16Index = 0
        var byteSum = 0
        for scalar in source.unicodeScalars {
            let u16 = String(scalar).utf16.count
            let u8 = String(scalar).utf8.count
            // 标量内部各 UTF-16 索引共享同一前缀字节数（边界处取该标量起始字节和）。
            for k in 0 ..< u16 where u16Index + k < table.count {
                table[u16Index + k] = byteSum
            }
            u16Index += u16
            byteSum += u8
        }
        if u16Index < table.count { table[u16Index] = byteSum }
        return table
    }
}
