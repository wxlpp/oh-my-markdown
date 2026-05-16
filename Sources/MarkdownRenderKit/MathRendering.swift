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
public protocol MathRendering: Sendable {
    /// pointSize 已是有效字号（文本字号 × mathScale）；scale 为屏幕光栅化 scale。
    func render(latex: String, display: Bool, pointSize: CGFloat,
                scale: CGFloat, color: PlatformColor) async -> MathRenderOutcome
}

/// 有效字号契约（spec §5.1）：键计算与 render 调用都必须用这一个公式、同一处算出。
public enum MathMetrics {
    public static func effectivePointSize(textPointSize: CGFloat, mathScale: CGFloat) -> CGFloat {
        textPointSize * mathScale
    }

    /// 颜色转稳定 hex（含 alpha），用于缓存键。
    public static func colorHex(_ color: PlatformColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif canImport(AppKit)
        (color.usingColorSpace(.sRGB) ?? color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        func h(_ v: CGFloat) -> String { String(format: "%02X", min(255, max(0, Int((v * 255).rounded())))) }
        return "#\(h(r))\(h(g))\(h(b))\(h(a))"
    }
}
