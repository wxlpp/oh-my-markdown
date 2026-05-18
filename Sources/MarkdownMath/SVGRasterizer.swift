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
/// **输入契约**：仅支持 MathJax 默认 inline SVG 格式——根 `<svg>` 带数值
/// `width="<num>ex"` 属性和 `viewBox`。Container/SVG-tag 模式（根 `width="100%"`、
/// 无 `viewBox`）不受支持，会抛 `.parseFailed`（由 Task 14 配置侧保证不产生此类输出）。
///
/// 两条硬约束：
/// 1. SwiftDraw 不支持 CSS `ex` 单位（`SVG(data:)` 直接返回 nil），喂给 SwiftDraw
///    前必须把根 svg 元素 width/height 的 `<num>ex` 改写为 `<num>px`。
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
              let openEnd = svg.range(of: ">", range: openStart.lowerBound..<svg.endIndex)
        else { return svg }

        let tagRange = openStart.lowerBound..<openEnd.upperBound
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

        // SwiftDraw 的 rasterize API 按平台拆分，签名/标签/返回类型均不同：
        // - UIKit  `UIImage+SVG.swift`:  func rasterize(size: CGSize, scale: CGFloat = 0) -> UIImage
        // - AppKit `NSImage+SVG.swift`:  func rasterize(with size: CGSize? = nil, scale: CGFloat = 0) -> NSImage
        // 必须按平台选用正确的参数标签，否则 iOS SDK 下（只有 UIKit 重载）编译失败：
        //   error: incorrect argument label in call (have 'with:scale:', expected 'size:scale:')
        //
        // 点尺寸契约（image.size 必须是「点」）：
        // - UIKit：rasterize(size:scale:) → sized(size).rasterize(scale:)；内部
        //   makeBounds(size:scale:1) 用固定 scale 1（点空间），UIGraphicsImageRendererFormat.scale
        //   单独编码栅格密度，UIGraphicsImageRenderer(size:) 即点尺寸 → 返回 UIImage.size
        //   天然等于 targetPointSize（点），无需修正（与 Task 13 结论一致）。
        // - AppKit：rasterize(with:scale:) 把返回 NSImage.size 设为 size×scale（像素），
        //   须显式改回点尺寸以满足点尺寸契约；Retina 清晰度由 AppKit 按设备 rect
        //   矢量重画保证，scale: 在 macOS 路径实为冗余（仅影响被覆盖的中间 .size）。
        #if canImport(UIKit)
        let image = drawing.rasterize(size: targetPointSize, scale: scale)
        #elseif canImport(AppKit)
        let image = drawing.rasterize(with: targetPointSize, scale: scale)
        image.size = targetPointSize
        #endif

        guard image.size.width > 1, image.size.height > 1 else {
            throw SVGRasterizerError.rasterizeFailed
        }
        return MathRenderedGlyph(image: image, baselineOffsetEx: parseVerticalAlignEx(svg))
    }
}
