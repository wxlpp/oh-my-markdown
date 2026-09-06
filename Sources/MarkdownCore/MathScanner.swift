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
            /// 无分配逐元素比较：marker 长仅 1 或 2，逐字节推进时若用
            /// `Array(bytes[k..<k+marker.count]) == marker` 每步都堆分配一个小
            /// 数组（热循环按字节推进，O(n) 次分配）。改为内联逐元素比较，
            /// 语义与 `Array(...) == marker` 逐字节完全等价（含
            /// `k + marker.count <= bytes.count` 边界不变）。
            /// No-allocation element-wise compare, equivalent to Array==.
            func matchesMarker(at start: Int) -> Bool {
                for j in 0 ..< marker.count where bytes[start + j] != marker[j] {
                    return false
                }
                return true
            }
            var k = from
            while k + marker.count <= bytes.count {
                // 硬边界：闭合搜索一旦扫进代码区即放弃（该 open 视为字面）。
                // 否则会越过 fenced/indented 代码块去匹配其**之后**的闭合符，
                // 使数学 span 吞掉整个代码块（随后 MathSentinel 把它从源码
                // 移除）——与引发整段 saga 的根因同类（定界符吞结构内容）。
                // 仅当扫描跨过代码区找 close 时触发，单调更保守，绝不放宽。
                // Hard boundary: a math delimiter pair must not span a code region.
                if codeMask[k] {
                    return nil
                }
                if !isEscaped(k), matchesMarker(at: k) {
                    return k
                }
                k += 1
            }
            return nil
        }

        /// pandoc / remark-math 行内 `$ … $` 定界符判定用字节级 helper。
        /// 空白 = 空格(0x20) / 制表(0x09) / 换行(0x0A) / 回车(0x0D)。
        @inline(__always) func isASCIIWhitespace(_ b: UInt8) -> Bool {
            b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
        }
        @inline(__always) func isASCIIDigit(_ b: UInt8) -> Bool {
            b >= 0x30 && b <= 0x39
        }

        /// 为行内 `$` 找合规闭界 `$`（pandoc / remark-math 规则）。
        /// `openContentStart` = 开界 `$` 之后第一个内容字节的索引（== 开界 i+1）。
        /// 合规闭界 `$` 需满足：非代码、非转义；不是 `$$` 的一部分（其后一字节
        /// 非 `$`，避免吃掉块级定界符的半个 `$`）；前一字节非空白；其后一字节
        /// （若存在）非 ASCII 数字（抗 `$5 ... $9` 货币）；`close > openContentStart`
        /// （公式非空）。搜索过程中若先遇到段落空行边界（一个行边界
        /// `\n` / `\r\n` / `\r` 后跟零个或多个 空格/制表 再跟行边界）仍未找到
        /// 合规闭界 → 返回 nil（行内不跨空行，阻断「吞代码块 + 标题」灾难性
        /// 跨块）。CRLF / CR 与 LF 同等对待。
        func findInlineDollarClose(openContentStart: Int) -> Int? {
            var k = openContentStart
            while k < bytes.count {
                let b = bytes[k]
                // 硬边界：行内 `$ … $` 闭合搜索一旦扫进代码区即放弃（开界 `$`
                // 视为字面）。否则会越过 fenced/indented 代码块去匹配其**之后**
                // 的闭合 `$`，使行内数学 span 吞掉整个代码块（随后 MathSentinel
                // 把它从源码移除）——与引发整段 saga 的根因同类（定界符吞结构
                // 内容），语义与 `findClose`/`findCloseBackslash` 一致。仅在扫描
                // 跨过代码区找 close 时触发，单调更保守，绝不放宽。
                // Hard boundary: a math delimiter pair must not span a code region.
                if codeMask[k] {
                    return nil
                }
                // 段落空行边界检测：行边界（`\n` / `\r\n` / `\r`，含其前的同行
                // 尾随空白）后到下一个行边界之间只有 空格/制表 → 视为空行，
                // 行内公式不得跨越。CRLF/CR 与 LF 同等对待（与本文件「空白
                // 含 0x0D」契约一致；CRLF 是 Windows / 部分 LLM 输出的常态）。
                if b == 0x0A || b == 0x0D {
                    var p = k + 1
                    if b == 0x0D, p < bytes.count, bytes[p] == 0x0A { p += 1 } // 跨过 \r\n 的 \n
                    while p < bytes.count, bytes[p] == 0x20 || bytes[p] == 0x09 {
                        p += 1
                    }
                    if p < bytes.count, bytes[p] == 0x0A || bytes[p] == 0x0D { return nil }
                }
                if b == 0x24, !codeMask[k], !isEscaped(k) {
                    let nextIsDollar = k + 1 < bytes.count && bytes[k + 1] == 0x24
                    let prevNotWhitespace = k - 1 >= 0 && !isASCIIWhitespace(bytes[k - 1])
                    let afterNotDigit = k + 1 >= bytes.count || !isASCIIDigit(bytes[k + 1])
                    if !nextIsDollar, prevNotWhitespace, afterNotDigit, k > openContentStart {
                        return k
                    }
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
            // $ … $（行内）：pandoc / remark-math 规则——开界 $ 后非空白，
            // 闭界 $ 前非空白且其后非数字，行内不跨段落空行（详见类型 doc）。
            // 抗货币 $（$5.00 / cost $5 vs $9）被贪婪误配吞整段。
            if b == 0x24 {
                let openContentStart = i + 1
                let openValid = openContentStart < bytes.count
                    && !isASCIIWhitespace(bytes[openContentStart])
                if openValid, let close = findInlineDollarClose(openContentStart: openContentStart) {
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
            // 硬边界：`\(…\)` / `\[…\]` 闭合搜索一旦扫进代码区即放弃（该 open
            // 视为字面）。否则会越过 fenced/indented 代码块去匹配其**之后**的
            // `\)` / `\]`，使数学 span 吞掉整个代码块（随后 MathSentinel 把它
            // 从源码移除）——与引发整段 saga 的根因同类（定界符吞结构内容），
            // 语义与 `findClose`/`findInlineDollarClose` 一致。仅在扫描跨过
            // 代码区找 close 时触发，单调更保守，绝不放宽。
            // Hard boundary: a math delimiter pair must not span a code region.
            if codeMask[k] {
                return nil
            }
            if bytes[k] == 0x5C, bytes[k + 1] == close {
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

    /// 供增量边界判定复用同一套代码区规则。
    /// 返回 UTF-8 字节索引的 `[Bool]`，长度 == `Array(source.utf8).count`，
    /// 与 `MathSpan.range`（UTF-8 字节偏移）索引对齐。
    public static func codeRegionMask(source: String) -> [Bool] {
        self.codeRegionMask(source: source, byteCount: Array(source.utf8).count)
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
