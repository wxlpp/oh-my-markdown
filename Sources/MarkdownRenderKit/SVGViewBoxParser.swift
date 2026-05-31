import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 在 SVG 字符串首 4KB 内提取 `<svg ... viewBox="x y w h" ...>` 的高宽比（`h / w`）。
/// 调用方在 AttributedStringRenderer 的 static-miss 分支用它给透明占位 attachment 算高度；
/// 失败（找不到、格式坏、宽为 0、`<svg ` 在首 4KB 外）一律返回 nil，调用方走默认 aspect。
///
/// Returns `h / w` for the `viewBox` of the outermost `<svg ...>` tag found within
/// the first 4 KB of `svg`. Returns nil on missing/malformed input or when width is 0.
/// Typical execution < 100µs; not memoised (callers invoke per cache miss).
public enum SVGViewBoxParser {
    /// 上限：超过此字节数后还没遇到 `<svg ` 起始即放弃，避免 pathological 长字符串扫描成本。
    private static let scanWindowBytes = 4096

    public static func parseAspect(from svg: String) -> CGFloat? {
        // 截首段，超过 scanWindowBytes 不再扫
        let scan = svg.prefix(self.scanWindowBytes)
        // 找 "<svg " 或 "<svg>" 起始
        guard let svgRange = scan.range(of: #"<svg(\s|>)"#, options: .regularExpression) else {
            return nil
        }
        // 找该 svg tag 内的 viewBox="..." attribute
        // 限定到 svgRange 之后的内容，止于第一个 ">"（tag 结束符）
        let afterSVG = scan[svgRange.upperBound...]
        guard let tagEnd = afterSVG.firstIndex(of: ">") else { return nil }
        let tagBody = afterSVG[..<tagEnd]
        guard let vbRange = tagBody.range(of: #"viewBox\s*=\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        // 抽出引号内 4 个数
        let vbAttr = tagBody[vbRange]
        guard let quoteStart = vbAttr.firstIndex(of: "\""),
              let quoteEnd = vbAttr.lastIndex(of: "\""),
              quoteStart < quoteEnd else {
            return nil
        }
        let inner = vbAttr[vbAttr.index(after: quoteStart)..<quoteEnd]
        let tokens = inner.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" })
        guard tokens.count == 4 else { return nil }
        let nums = tokens.compactMap { Double($0) }
        guard nums.count == 4 else { return nil }
        let w = nums[2], h = nums[3]
        guard w > 0 else { return nil }
        return CGFloat(h / w)
    }
}
