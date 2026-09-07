import Foundation
import MarkdownRenderKit
import SwiftDraw

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum SVGRasterizerError: Error { case parseFailed, invalidDimensions, rasterizeFailed }

// SVG 字符串 → 颜色注入 → ex 归一化 → SwiftDraw 光栅化 → RenderedMath。
//
// **输入契约**：仅支持 MathJax 默认 inline SVG 格式——根 `<svg>` 带数值
// `width="<num>ex"` 属性和 `viewBox`。Container/SVG-tag 模式（根 `width="100%"`、
// 无 `viewBox`）不受支持，会抛 `.parseFailed`（由 Task 14 配置侧保证不产生此类输出）。
//
// 两条硬约束：
// 1. 根 svg 元素 width/height 的 `<num>ex` 必须改写为 `<num>px` 再喂给 SwiftDraw。
//    **注意这条的理由已经变了**：原文写的是「SwiftDraw 不支持 `ex`，`SVG(data:)`
//    直接返回 nil」——那在 pin 着 `4d09d03` 的时候成立，自 SwiftDraw `0.29.0` 起
//    **不再成立**（它新增了 `.em` / `.ex`，见其 `DOM.swift`）。
//    归一化仍然必须做，但现在是为了**尺寸正确**而不是为了「能解析」：SwiftDraw 按
//    **1ex = 1pt** 解析，而 MathJax 的 `ex` 是相对于当前字体的 x-height，两者不等。
//    不归一化的话不再是「解析失败」，而是**静默渲出一个尺寸错误的公式**——从显式
//    失败退化成静默错误，比原来更难发现。

/// 2. 返回的 `image.size` 必须是「点」单位（目标文本空间渲染尺寸），不是像素。
///    SwiftDraw 的 rasterize API 分平台（标签/返回类型不同），点尺寸契约在两平台
///    分别成立：UIKit `rasterize(size:scale:)` 返回的 `UIImage.size` 天然是点；
///    AppKit `rasterize(with:scale:)` 返回 `.size == size * scale`（像素），须显式
///    把 `NSImage.size` 修正回点尺寸。详见 `rasterize(svg:hex:pointSize:scale:)`。
enum SVGRasterizer {
    static func injectColor(into svg: String, hex: String) -> String {
        svg.replacingOccurrences(of: "currentColor", with: hex)
    }

    static func parseVerticalAlignEx(_ svg: String) -> CGFloat {
        guard let r = svg.range(of: "vertical-align:") else { return 0 }
        let tail = svg[r.upperBound...]
        let token = tail.prefix(while: { $0 != ";" && $0 != "\"" })
            .trimmingCharacters(in: .whitespaces)
        let numeric = token.replacingOccurrences(of: "ex", with: "")
            .trimmingCharacters(in: .whitespaces)
        return CGFloat(Double(numeric) ?? 0)
    }

    static func parseHeightEx(_ svg: String) -> CGFloat {
        guard let r = svg.range(of: "height=\"") else { return 2 }
        let tail = svg[r.upperBound...]
        let token = tail.prefix(while: { $0 != "\"" })
        // Extract the leading numeric prefix (digits, optional leading dot, optional decimal point)
        // so that values like ".5ex" parse as 0.5 rather than falling back to 2.
        let numericPrefix = token.prefix(while: { $0.isNumber || $0 == "." })
        return CGFloat(Double(numericPrefix) ?? 2)
    }

    /// 把根 svg 元素 `width`/`height` 属性里的 `<num>ex` 改写为 `<num>px`。
    ///
    /// 仅作用于开头 `<svg ...>` 标签内 `width="…ex"` / `height="…ex"` 形式的尺寸属性：
    /// 把正则范围限定在第一个 `<svg ... >` 开标签子串内，且只匹配 `width=`/`height=`
    /// 属性后紧跟 `数字ex"` 的片段。path `d=` 数据 / 十六进制颜色不在根开标签的
    /// width/height 属性里，也不具备 `width="<num>ex"` 形态，故不会被误伤。
    static func normalizeUnits(_ svg: String) -> String {
        guard let openStart = svg.range(of: "<svg"),
              let openEnd = svg.range(of: ">", range: openStart.lowerBound ..< svg.endIndex)
        else { return svg }

        let tagRange = openStart.lowerBound ..< openEnd.upperBound
        let tag = String(svg[tagRange])

        let pattern = #"((?:width|height)\s*=\s*")(\d*\.?\d+)ex(")"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return svg }
        let nsTag = tag as NSString
        let rewrittenTag = regex.stringByReplacingMatches(
            in: tag,
            range: NSRange(location: 0, length: nsTag.length),
            withTemplate: "$1$2px$3"
        )
        return svg.replacingCharacters(in: tagRange, with: rewrittenTag)
    }

    static func rasterize(
        svg: String,
        hex: String,
        pointSize: CGFloat,
        scale: CGFloat
    ) throws -> RenderedMath {
        // ex→px 归一化只为喂 SwiftDraw 解析；高度/基线仍读原始 svg 的 ex 值。
        let colored = self.normalizeUnits(self.injectColor(into: svg, hex: hex))
        guard let data = colored.data(using: .utf8),
              let drawing = SwiftDraw.SVG(data: data) else {
            throw SVGRasterizerError.parseFailed
        }

        // 目标点尺寸：高度按原始 ex × 0.5 × pointSize（1ex ≈ 0.5em），宽高比来自解析后 viewBox。
        let heightPoints = max(1, parseHeightEx(svg) * 0.5 * pointSize)
        let aspect = drawing.size.height > 0 ? drawing.size.width / drawing.size.height : 1
        let targetPointSize = CGSize(width: heightPoints * aspect, height: heightPoints)

        let image = try rasterImage(drawing, pointSize: targetPointSize, scale: scale)
        return RenderedMath(image: image, baselineOffsetEx: self.parseVerticalAlignEx(svg))
    }

    /// Draw into privately allocated Core Graphics storage; no platform image escapes.
    static func rasterImage(_ drawing: SwiftDraw.SVG, pointSize: CGSize, scale: CGFloat) throws -> RenderedImage {
        let density = scale.isFinite && scale > 0 ? scale : 1
        let width = ceil(pointSize.width * density)
        let height = ceil(pointSize.height * density)
        guard width.isFinite, height.isFinite, width > 1, height > 1, width <= 4096, height <= 4096 else {
            throw SVGRasterizerError.invalidDimensions
        }
        guard let context = CGContext(
            data: nil,
            width: Int(width),
            height: Int(height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw SVGRasterizerError.rasterizeFailed }
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: width / pointSize.width, y: -height / pointSize.height)
        context.draw(drawing, in: CGRect(origin: .zero, size: pointSize))
        guard let image = context.makeImage() else { throw SVGRasterizerError.rasterizeFailed }
        return try RenderedImage(cgImage: image, pointSize: pointSize)
    }
}
