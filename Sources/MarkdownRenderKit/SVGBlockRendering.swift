import Foundation

/// Wrapper-owned identity isolates custom producer cache namespaces by default.
public struct SVGRendererConfiguration: Sendable {
    package let renderer: any SVGBlockRendering
    public let configurationID: MarkdownConfigurationID

    public init(renderer: any SVGBlockRendering, configurationID: MarkdownConfigurationID = .uniqueInstance()) {
        self.renderer = renderer
        self.configurationID = configurationID
    }
}
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension NSAttributedString.Key {
    /// 未渲染 SVG 代码块占位标记，载荷为 SVG body 源串，对标 .markdownMathSource。
    /// Marks an un-rendered ```svg code block; payload is the SVG body source string.
    public static let markdownSVGBlockSource = NSAttributedString.Key("MarkdownKit.svgBlockSource")
}

/// UIImage/NSImage are safe for concurrent read; @unchecked Sendable is intentional
/// (same rationale as MathRenderedGlyph in this module).
/// 已渲染的 SVG 块位图。`image.size` **必须**是点单位（与 MathRenderedGlyph 同契约）。
/// Rendered SVG block bitmap. `image.size` MUST be in points (same contract as MathRenderedGlyph).
public struct SVGBlockGlyph: @unchecked Sendable {
    public init(image: PlatformImage) {
        self.image = image
    }

    public let image: PlatformImage
}

/// 三态结果（对标 MathRenderOutcome）。Tri-state outcome (mirrors MathRenderOutcome).
public enum SVGBlockOutcome: Sendable {
    case rendered(SVGBlockGlyph)
    case failed
    case cancelled
}

/// SVG 块渲染缓存键。Hashable 保证四个维度全部参与等价判断。
/// Cache key for an SVG block render. All four dimensions contribute to equality.
public struct SVGBlockCacheKey: Hashable, Sendable {
    public init(svg: String, availableWidth: CGFloat, rasterScale: CGFloat, rendererGeneration: Int) {
        self.svg = svg
        self.availableWidth = availableWidth
        self.rasterScale = rasterScale
        self.rendererGeneration = rendererGeneration
    }

    public let svg: String
    public let availableWidth: CGFloat
    public let rasterScale: CGFloat
    public let rendererGeneration: Int
}

/// 注入式 SVG 块渲染器。约束 `AnyObject`：注入身份比较须稳定，值类型经
/// `as AnyObject` 装箱不稳（PR #4 round-1 已在 MathRendering 验证）。
/// Injected SVG block renderer; class-constrained so injection identity is stable
/// (value types box unstably via `as AnyObject` — proven on MathRendering in PR #4 r1).
public protocol SVGBlockRendering: AnyObject, Sendable {
    func render(svg: String, availableWidth: CGFloat, scale: CGFloat) async -> SVGBlockOutcome
}
