import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension NSAttributedString.Key {
    /// 未渲染数学占位标记，载荷为 "<display 0|1>\u{1F}<latex>"，对标 .markdownImageSource。
    /// 规范格式：Task 8/11 的编解码必须与此一致，此注释是唯一权威来源。
    public static let markdownMathSource = NSAttributedString.Key("MarkdownKit.mathSource")
}

// UIImage/NSImage are safe for concurrent read; @unchecked Sendable is intentional
// (same rationale as RenderStyle / AttributedStringRenderer in this module).
/// 渲染好的公式字形。
public struct MathRenderedGlyph: @unchecked Sendable {
    public init(image: PlatformImage, baselineOffsetEx: CGFloat) {
        self.image = image
        self.baselineOffsetEx = baselineOffsetEx
    }
    /// 已渲染位图。**契约**：`size` 必须是「点」单位（= 目标文本空间渲染尺寸），
    /// 不是像素——栅格密度由平台图像 scale/backing 编码，绝不体现在 `size` 上。
    /// `AttributedStringRenderer` 直接把 `image.size` 用作 `NSTextAttachment.bounds`；
    /// 若返回像素尺寸，行内公式会在 Retina 上放大 scale 倍。MarkdownMath 的 SVGRasterizer 须遵守。
    public let image: PlatformImage
    /// 由 SVG vertical-align 解析得到的基线偏移（ex 单位，正值=下移）。
    public let baselineOffsetEx: CGFloat
}

/// 渲染结果三态（spec §5.3）：消除 nil 无法区分取消与硬失败的歧义。
public enum MathRenderOutcome: Sendable {
    case rendered(MathRenderedGlyph)
    case failed
    case cancelled
}

/// 数学缓存键。`pointSize` 已是「有效字号」（文本字号 × mathScale）。
public struct MathCacheKey: Hashable, Sendable {
    public init(latex: String, display: Bool, pointSize: CGFloat,
                colorHex: String, rasterScale: CGFloat, rendererGeneration: Int) {
        self.latex = latex
        self.display = display
        self.pointSize = pointSize
        self.colorHex = colorHex
        self.rasterScale = rasterScale
        self.rendererGeneration = rendererGeneration
    }
    public let latex: String
    public let display: Bool
    public let pointSize: CGFloat
    public let colorHex: String
    public let rasterScale: CGFloat
    public let rendererGeneration: Int
}

/// 注入协议：MarkdownMath 提供实现，RenderKit 不依赖任何 MathJax。
///
/// 约束为 `AnyObject`（类约束）：注入身份比较须稳定——值类型经
/// `as AnyObject` 装箱每次产生新对象，会让 MarkdownKit 的身份 guard
/// （`isSameMathRenderer`，见 MarkdownText/MarkdownStreamingText）恒为
/// false，SwiftUI 每次刷新都重新赋值 renderer、bump 代际清缓存。
/// 唯一实现 `MathJaxRenderer` 本就是 `final class`，此约束与现实一致、零破坏。
public protocol MathRendering: AnyObject, Sendable {
    /// pointSize 已是有效字号（文本字号 × mathScale）；scale 为屏幕光栅化 scale。
    func render(latex: String, display: Bool, pointSize: CGFloat,
                scale: CGFloat, color: PlatformColor) async -> MathRenderOutcome
}

/// 有效字号契约（spec §5.1）：键计算与 render 调用都必须用这一个公式、同一处算出。
public enum MathMetrics {
    public static func effectivePointSize(textPointSize: CGFloat, mathScale: CGFloat) -> CGFloat {
        textPointSize * mathScale
    }

    /// 颜色转稳定 6 位 hex `#RRGGBB`，用于缓存键和 SVG currentColor 注入。
    ///
    /// 返回 6 位（不含 alpha），原因：
    /// - SVG 注入侧 SwiftDraw 仅支持 `#RGB`/`#RRGGBB`，8 位 `#RRGGBBAA` 会被误解析
    ///   为单一整数，导致 alpha 字节落入 blue 通道，公式渲染成蓝色（Bug 2）。
    /// - 数学字形颜色的 alpha 恒≈1.0（body 文本色），仅 RGB 不同会撞键，属良性复用。
    public static func colorHex(_ color: PlatformColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif canImport(AppKit)
        (color.usingColorSpace(.sRGB) ?? color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        func h(_ v: CGFloat) -> String { String(format: "%02X", min(255, max(0, Int((v * 255).rounded())))) }
        return "#\(h(r))\(h(g))\(h(b))"
    }
}
