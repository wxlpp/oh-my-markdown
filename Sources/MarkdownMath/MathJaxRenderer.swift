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
///
/// `@unchecked Sendable` 安全性依据：所有可变态（`_mathjax` / `_failed`）均由 `lock`
/// 保护；底层 `MathJax` 持单一 `JSContext`，本类通过把私有**串行**队列 `renderQueue`
/// 显式传给 `tex2svg(..., queue:)`，使所有 LaTeX→SVG 转换序列化经该串行队列进入，
/// 单 `JSContext` 永不被并发进入（消除评审 Critical C1）。
public final class MathJaxRenderer: MathRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var _mathjax: MathJax?
    private var _failed = false

    /// 私有**串行**队列：MathJaxSwift 的 `tex2svg(..., queue:)` 默认用 `.global()`
    /// （并发队列），其 `perform(on:)` 内部 `queue.async` 执行的 block 直接读写
    /// `MathJax` 的单一共享 `JSContext`。多公式并发 render 会让多个 block 同时进入
    /// 同一 `JSContext` → 数据竞争 / SVG 串味 / `context.exception` 误判 / 潜在崩溃
    /// （评审 Critical C1）。把本串行队列显式传入 `tex2svg`，所有转换排队串行进入
    /// 同一 `JSContext`，彻底序列化。不得改为 `.concurrent`。
    private let renderQueue = DispatchQueue(
        label: "com.markdownkit.mathjax.render",
        qos: .userInitiated)

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
            // queue: renderQueue —— 关键：显式覆盖默认的 `.global()` 并发队列，
            // 让本次转换排到私有串行队列。底层 `perform(on:)` 的 `queue.async` block
            // 会逐个串行进入共享 `JSContext`，多并发 render 在此自然排队（消除 C1）。
            svg = try await mathjax.tex2svg(
                latex,
                conversionOptions: ConversionOptions(display: display),
                inputOptions: TeXInputProcessorOptions(loadPackages: TeXInputProcessorOptions.Packages.all),
                outputOptions: SVGOutputProcessorOptions(),
                queue: renderQueue)
        } catch is CancellationError {
            // 死分支（当前）：MathJaxSwift 的 async 路径走 `withCheckedThrowingContinuation`
            // + `queue.async`，`tex2svg` 转换不可中断，不会抛 `CancellationError`；
            // 取消实际由本函数上下两处 `Task.isCancelled` 哨兵粗粒度处理（取消后仍跑
            // 完转换才返回 `.cancelled`，粗粒度优化属 Task 16）。保留此分支以防上游
            // 未来改用协作式取消（届时此处可直接生效，无需改 renderer）。
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
