import Foundation
import MarkdownRenderKit
import SwiftDraw

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// SwiftDraw 驱动的 ```svg 代码块渲染器。自包含实现（不复用 `SVGRasterizer`
/// —— 与 spec §9.1 「math 路径零回归」硬门保持一致）。不注入颜色：svg 代码
/// 块按作者原样保留配色。仅 fit-width 不放大（视图宽 ≥ 原生宽时保留原生
/// 尺寸），失败/退化场景统一返回 `.failed`，`Task.isCancelled` 返回 `.cancelled`。
public actor SwiftDrawSVGBlockRenderer: SVGBlockRendering, BuiltInRenderedResourceProducer {
    package nonisolated let builtInConfigurationID: MarkdownConfigurationID = .semantic(
        namespace: "SwiftDraw0.29.fit-width.no-upscale.rgba8.png.max4096.invalid-scale1", version: 1
    )
    /// 单维度光栅化**像素**尺寸上限（point × scale）。fit-width 仅约束
    /// 宽度，target 高度由原生纵横比派生 —— 极端 viewBox（如
    /// `0 0 100 1000000`）下高度可膨胀到任意大；同时 Retina scale 会再
    /// 放大像素总量（4096pt × scale 3 = 12288px 单维度，~600MB 位图）。
    /// 故上限按**像素维度**算（point × scale ≤ 4096px），既覆盖大屏
    /// Retina 实际显示需求，又把最坏单图内存夹到 ~67MB（4096²×4B）。
    /// 超界统一 `.failed`（与 native ≤0、non-finite 等其他退化场景同款）。
    /// Copilot PR #5 R1 #1 + codex adversarial review #2。
    private static let maxRasterPixelDimension: CGFloat = 4096

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

        let targetWidth: CGFloat = if availableWidth.isFinite, availableWidth > 0 {
            // fit-width，不放大：视图宽 ≥ 原生宽时保留原生宽。
            min(native.width, availableWidth)
        } else {
            native.width
        }
        let targetHeight = targetWidth * native.height / native.width
        let target = CGSize(width: targetWidth, height: targetHeight)
        guard target.width > 1, target.height > 1,
              target.width.isFinite, target.height.isFinite else {
            return .failed
        }
        // OOM 防御：极端纵横比 SVG 会让 fit-width 后 target 高度任意膨胀；
        // 同时 Retina scale 再放大像素量。按**像素维度**（point × scale）
        // 设上限：scale ≤0 / non-finite 时按 1 兜底，避免被恶意 scale 绕过。
        let effectiveScale: CGFloat = if scale.isFinite, scale > 0 { scale } else { 1 }
        guard target.width * effectiveScale <= Self.maxRasterPixelDimension,
              target.height * effectiveScale <= Self.maxRasterPixelDimension else {
            return .failed
        }
        if Task.isCancelled { return .cancelled }

        do {
            let image = try SVGRasterizer.rasterImage(drawing, pointSize: target, scale: effectiveScale)
            return Task.isCancelled ? .cancelled : .rendered(RenderedSVG(image: image))
        } catch { return Task.isCancelled ? .cancelled : .transientFailure }
    }
}
