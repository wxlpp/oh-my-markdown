import Foundation
import SwiftDraw
import MarkdownRenderKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// SwiftDraw 驱动的 ```svg 代码块渲染器。自包含实现（不复用 `SVGRasterizer`
/// —— 与 spec §9.1 「math 路径零回归」硬门保持一致）。不注入颜色：svg 代码
/// 块按作者原样保留配色。仅 fit-width 不放大（视图宽 ≥ 原生宽时保留原生
/// 尺寸），失败/退化场景统一返回 `.failed`，`Task.isCancelled` 返回 `.cancelled`。
public final class SwiftDrawSVGBlockRenderer: SVGBlockRendering, @unchecked Sendable {
    /// 单维度光栅化点尺寸上限。fit-width 仅约束宽度，target 高度由原生
    /// 纵横比派生 —— 极端 viewBox（如 `0 0 100 1000000`）下高度可膨胀到
    /// 任意大，光栅化会分配巨型位图（OOM/DoS 攻击向量）。4096pt 覆盖了
    /// 大屏 + Retina 的实际显示需求，超界统一 `.failed`（与 native ≤0、
    /// non-finite 等其他退化场景同款）。Copilot PR #5 R1 #1。
    private static let maxRasterPointDimension: CGFloat = 4096

    public init() {}

    public func render(svg: String, availableWidth: CGFloat, scale: CGFloat) async -> SVGBlockOutcome {
        if Task.isCancelled { return .cancelled }
        guard let data = svg.data(using: .utf8),
              let drawing = SwiftDraw.SVG(data: data) else {
            return .failed
        }
        let native = drawing.size
        guard native.width > 0, native.height > 0,
              native.width.isFinite, native.height.isFinite else {
            return .failed
        }

        let targetWidth: CGFloat
        if availableWidth.isFinite, availableWidth > 0 {
            // fit-width，不放大：视图宽 ≥ 原生宽时保留原生宽。
            targetWidth = min(native.width, availableWidth)
        } else {
            targetWidth = native.width
        }
        let targetHeight = targetWidth * native.height / native.width
        let target = CGSize(width: targetWidth, height: targetHeight)
        guard target.width > 1, target.height > 1,
              target.width.isFinite, target.height.isFinite else {
            return .failed
        }
        // OOM 防御：极端纵横比 SVG 会让 fit-width 后 target 高度任意膨胀；
        // 单维度点尺寸上限（不含 scale，缓冲 Retina 时已经够大）。
        guard target.width <= Self.maxRasterPointDimension,
              target.height <= Self.maxRasterPointDimension else {
            return .failed
        }
        if Task.isCancelled { return .cancelled }

        // SwiftDraw 平台 rasterize 标签差异：UIKit `rasterize(size:scale:)` 返回的
        // UIImage.size 天然是点；AppKit `rasterize(with:scale:)` 返回 NSImage.size
        // 等于 size×scale（像素），须显式回填点尺寸（与 SVGRasterizer 同款契约）。
        #if canImport(UIKit)
        let image = drawing.rasterize(size: target, scale: scale)
        #elseif canImport(AppKit)
        let image = drawing.rasterize(with: target, scale: scale)
        image.size = target
        #else
        return .failed
        #endif
        return .rendered(SVGBlockGlyph(image: image))
    }
}
