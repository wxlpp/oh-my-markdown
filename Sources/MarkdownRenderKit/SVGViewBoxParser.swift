import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 在 SVG 字符串首 4KB 内提取 `<svg ... viewBox="x y w h" ...>` 的原生尺寸 / 高宽比。
/// 调用方在 AttributedStringRenderer 的 static-miss 分支用 `parseSize` 给透明占位
/// attachment 算尺寸（与 SwiftDraw fit-without-upscale 公式对齐避免 layout shift），
/// `parseAspect` 为兼容 / aspect-only 场景保留。失败一律返回 nil。
///
/// Parses the outermost `<svg ... viewBox="x y w h" ...>` tag found within the first
/// 4 KB of `svg`. `parseSize` returns the native viewBox dimensions; `parseAspect`
/// returns `h / w` derived from the same parse. Both return nil on missing/malformed
/// input or when width or height is non-positive. Typical execution < 100µs.
public enum SVGViewBoxParser {
    /// 上限：超过此字节数后还没遇到 `<svg ` 起始即放弃，避免 pathological 长字符串扫描成本。
    private static let scanWindowBytes = 4096

    /// 解析 viewBox 的 `(width, height)` 原生尺寸（point 单位语义）。
    /// 调用方需自己决定 fit/scale 策略——常用模式是 fit-without-upscale：
    /// `target = (min(native.width, availableWidth), 按 native aspect 派生 height)`。
    /// w 或 h ≤ 0 返回 nil（无法绘制 + 防 division by zero）。
    public static func parseSize(from svg: String) -> CGSize? {
        let scan = svg.prefix(self.scanWindowBytes)
        // 找 "<svg " 或 "<svg>" 起始
        guard let svgRange = scan.range(of: #"<svg(\s|>)"#, options: .regularExpression) else {
            return nil
        }
        // 找该 svg tag 内的 viewBox="..." attribute，限定到 svgRange 之后到 tag 结束符 ">"
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
        let inner = vbAttr[vbAttr.index(after: quoteStart) ..< quoteEnd]
        let tokens = inner.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" })
        guard tokens.count == 4 else { return nil }
        let nums = tokens.compactMap { Double($0) }
        guard nums.count == 4 else { return nil }
        let w = nums[2], h = nums[3]
        guard w > 0, h > 0 else { return nil } // 防 division by zero + 不可绘制
        return CGSize(width: w, height: h)
    }

    /// 解析 viewBox 的高宽比 `h / w`。等价于 `parseSize(from:).map { $0.height / $0.width }`。
    /// 仅对历史调用者保留——新代码应优先用 `parseSize` 拿完整尺寸做精确 fit。
    public static func parseAspect(from svg: String) -> CGFloat? {
        self.parseSize(from: svg).map { CGFloat($0.height / $0.width) }
    }
}
