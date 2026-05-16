import Foundation
import MathJaxSwift
import MarkdownRenderKit

/// `MathRendering` 实现：MathJax(JavaScriptCore) 把 LaTeX → SVG，再交 `SVGRasterizer` 光栅化。
///
/// 三态映射（spec §5.3）：
/// - 取消（`Task.isCancelled`）→ `.cancelled`（取消前后各设一个哨兵）
/// - LaTeX 语法错误 → MathJax 仍产出「错误 SVG」，算 **成功** → `.rendered`
/// - MathJax 实例化失败 / 转换抛错 / 光栅化抛错 → `.failed`
///
/// `_failed` 标志：MathJax 实例化是重操作（加载 JS bundle）；一旦失败标记为永久失败，
/// 后续不再重试（避免每次 render 都吃一次失败开销）。取消**不**置位 `_failed`，
/// 故取消一次不污染实例（契约 4）。
public final class MathJaxRenderer: MathRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var _mathjax: MathJax?
    private var _failed = false

    public init() {}

    /// 懒加载并缓存 `MathJax` 实例。实例化失败 → 永久 `_failed`，返回 nil。
    private func instance() -> MathJax? {
        lock.lock()
        defer { lock.unlock() }
        if _failed { return nil }
        if let m = _mathjax { return m }
        do {
            let m = try MathJax(preferredOutputFormat: .svg)
            _mathjax = m
            return m
        } catch {
            _failed = true
            return nil
        }
    }

    public func render(
        latex: String,
        display: Bool,
        pointSize: CGFloat,
        scale: CGFloat,
        color: PlatformColor
    ) async -> MathRenderOutcome {
        if Task.isCancelled { return .cancelled }
        guard let mathjax = instance() else { return .failed }

        let svg: String
        do {
            // container 默认 false → MathJax 产 inline SVG（根 width="<num>ex" + viewBox），
            // 正是 SVGRasterizer 的输入契约（契约 1 守住）。display 透传；加载全部 TeX 包。
            svg = try await mathjax.tex2svg(
                latex,
                conversionOptions: ConversionOptions(display: display),
                inputOptions: TeXInputProcessorOptions(loadPackages: TeXInputProcessorOptions.Packages.all),
                outputOptions: SVGOutputProcessorOptions())
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed
        }
        if Task.isCancelled { return .cancelled }

        do {
            let glyph = try SVGRasterizer.rasterize(
                svg: svg,
                hex: MathMetrics.colorHex(color),
                pointSize: pointSize,
                scale: scale)
            return .rendered(glyph)
        } catch {
            return .failed
        }
    }
}
