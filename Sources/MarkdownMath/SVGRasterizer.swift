import Foundation
import SwiftDraw
import MarkdownRenderKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum SVGRasterizerError: Error { case parseFailed, rasterizeFailed }

/// SVG 字符串 → 颜色注入 → ex 归一化 → SwiftDraw 光栅化 → MathRenderedGlyph。
///
/// 两条硬约束：
/// 1. SwiftDraw 不支持 CSS `ex` 单位（`SVG(data:)` 直接返回 nil），喂给 SwiftDraw
///    前必须把根 svg 元素 width/height 的 `<num>ex` 改写为 `<num>px`。
/// 2. 返回的 `image.size` 必须是「点」单位（目标文本空间渲染尺寸），不是像素。
///    macOS `SwiftDraw.rasterize(with:scale:)` 返回 `.size == size * scale`（像素），
///    须显式把 `NSImage.size` 修正回点尺寸。
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
        let numeric = token.replacingOccurrences(of: "ex", with: "")
        return CGFloat(Double(numeric) ?? 2)
    }

    /// 把根 svg 元素 `width`/`height` 属性里的 `<num>ex` 改写为 `<num>px`。
    ///
    /// 仅作用于开头 `<svg ...>` 标签内 `width="…ex"` / `height="…ex"` 形式的尺寸属性：
    /// 把正则范围限定在第一个 `<svg ... >` 开标签子串内，且只匹配 `width=`/`height=`
    /// 属性后紧跟 `数字ex"` 的片段。path `d=` 数据 / 十六进制颜色不在根开标签的
    /// width/height 属性里，也不具备 `width="<num>ex"` 形态，故不会被误伤。
    static func normalizeUnits(_ svg: String) -> String {
        guard let openStart = svg.range(of: "<svg"),
              let openEnd = svg.range(of: ">", range: openStart.lowerBound..<svg.endIndex)
        else { return svg }

        let tagRange = openStart.lowerBound..<openEnd.upperBound
        let tag = String(svg[tagRange])

        let pattern = #"((?:width|height)\s*=\s*")(\d+\.?\d*)ex(")"#
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
    ) throws -> MathRenderedGlyph {
        // ex→px 归一化只为喂 SwiftDraw 解析；高度/基线仍读原始 svg 的 ex 值。
        let colored = normalizeUnits(injectColor(into: svg, hex: hex))
        guard let data = colored.data(using: .utf8),
              let drawing = SwiftDraw.SVG(data: data) else {
            throw SVGRasterizerError.parseFailed
        }

        // 目标点尺寸：高度按原始 ex × 0.5 × pointSize（1ex ≈ 0.5em），宽高比来自解析后 viewBox。
        let heightPoints = max(1, parseHeightEx(svg) * 0.5 * pointSize)
        let aspect = drawing.size.height > 0 ? drawing.size.width / drawing.size.height : 1
        let targetPointSize = CGSize(width: heightPoints * aspect, height: heightPoints)

        let image = drawing.rasterize(with: targetPointSize, scale: scale)

        // 点尺寸契约：
        // - macOS：SwiftDraw 返回的 NSImage `.size == targetPointSize * scale`（像素），
        //   显式设回点尺寸；scale× 的位图仍保留为 backing representation。
        // - UIKit：rasterize(size:scale:) 已用 UIGraphicsImageRenderer 的 scale 编码
        //   栅格密度，`.size` 已是点尺寸，无需修正。
        #if canImport(AppKit) && !canImport(UIKit)
        image.size = targetPointSize
        #endif

        guard image.size.width > 1, image.size.height > 1 else {
            throw SVGRasterizerError.rasterizeFailed
        }
        return MathRenderedGlyph(image: image, baselineOffsetEx: parseVerticalAlignEx(svg))
    }
}
