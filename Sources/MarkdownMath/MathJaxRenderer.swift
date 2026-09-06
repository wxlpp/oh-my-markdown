import Foundation
import MarkdownRenderKit
import MathJaxSwift

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
        qos: .userInitiated
    )

    public init() {}

    /// 共享的 TeX 输入配置（spec §5.3 配套，Task 14b 修复）。
    ///
    /// 评审复现的缺陷根因经实证并非 `loadPackages` 包冲突，而是 MathJaxSwift 上游
    /// `TeXInputProcessorOptions.defaultDigits` 这条**畸形正则**：
    /// `"^(?:[0-9]+(?:{,}[0-9]{3})*(?:.[0-9]*)?|.[0-9]+)"`——MathJax 官方默认数字
    /// 模式应是 `/^(?:[0-9]+(?:\{,\}[0-9]{3})*(?:\.[0-9]*)?|\.[0-9]+)/`（`\{,\}`
    /// 为千分位分组字面量、`\.` 为字面小数点），上游转写时丢了反斜杠转义，导致
    /// `{,}` 成空/非法量词、`.` 变通配。MathJax 数字解析器命中含数字的下标/上标
    /// （如 `\sum_{i=1}^n`、`x_{1}`、`\lim_{x\to 0}` 里的 `0/1`）时会错误吞掉花括号
    /// → 真实产出 `merror`「Extra open brace or missing close brace」→ `render`
    /// 归 `.failed`。故此处显式覆盖为 MathJax 规范数字正则。
    /// TODO(upstream): MathJaxSwift `defaultDigits` 转义丢失（缺 `\{ \} \.`）；上游修复后可移除本 `digits:` 覆盖。建议提 issue/PR 跟踪。
    ///
    /// `loadPackages` 同时从 `.all`（34 包全载）收敛为最小且无冲突的
    /// `[base, ams, noundefined]`：实证矩阵表明该集合配合修正后的 `digits`，10 个
    /// 核心公式（含矩阵环境，需 `ams`）全部 `.rendered`。`noundefined` **必须保留**
    /// —— 它让未定义控制序列（如 `\thisCommandDoesNotExist`）渲染成错误占位 SVG
    /// 而非抛 `Undefined control sequence`，正是 spec §5.3「LaTeX 语法错误仍产错误
    /// SVG 算成功」契约（既有测试 `invalidStillRenders` 依赖此行为）；去掉它会令
    /// 该测试回归。保持 `.all` 仅徒增加载体积而无功能收益。仅此一处配置集中点。
    /// 已知限制：未载 physics/mhchem/braket/cancel/color 等包，`\ce{}`/`\braket`/`\cancel`/`\color` 等非核心命令会被 noundefined 渲染成红色错误占位 SVG（非 .failed，用户可见）。spec §1/§8 scope 为核心数学，属预期取舍。
    ///
    /// 计算属性（每次 render 新建一份，与修复前内联构造同语义）：
    /// `TeXInputProcessorOptions` 是上游非 `Sendable` 引用类型，不能作 `static let`。
    /// 注：JS 侧 `tex2svg` 每次调用都 `new TeX(opts)` 并重编译 `digits` 正则（MathJaxSwift 架构固有，见上游 svg.js），与本属性是否缓存无关——缓存仅省一次 JSONEncoder 编码（微秒级），不值得为此破坏不变量/持有非 Sendable 实例字段。
    private var texInputOptions: TeXInputProcessorOptions {
        TeXInputProcessorOptions(
            loadPackages: [
                TeXInputProcessorOptions.Packages.base,
                TeXInputProcessorOptions.Packages.ams,
                TeXInputProcessorOptions.Packages.noundefined,
            ],
            digits: #"^(?:[0-9]+(?:\{,\}[0-9]{3})*(?:\.[0-9]*)?|\.[0-9]+)"#
        )
    }

    /// 懒加载并缓存 `MathJax` 实例。实例化失败 → 永久 `_failed`，返回 nil。
    private func instance() -> MathJax? {
        self.lock.lock()
        defer { lock.unlock() }
        if self._failed { return nil }
        if let m = _mathjax { return m }
        do {
            let m = try MathJax(preferredOutputFormat: .svg)
            self._mathjax = m
            return m
        } catch {
            self._failed = true
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
            // 正是 SVGRasterizer 的输入契约（契约 1 守住）。display 透传；TeX 输入配置
            // 见 `texInputOptions`（Task 14b：修正畸形 digits 正则 + loadPackages 收敛）。
            // queue: renderQueue —— 关键：显式覆盖默认的 `.global()` 并发队列，
            // 让本次转换排到私有串行队列。底层 `perform(on:)` 的 `queue.async` block
            // 会逐个串行进入共享 `JSContext`，多并发 render 在此自然排队（消除 C1）。
            svg = try await mathjax.tex2svg(
                latex,
                conversionOptions: ConversionOptions(display: display),
                inputOptions: self.texInputOptions,
                outputOptions: SVGOutputProcessorOptions(),
                queue: self.renderQueue
            )
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
                scale: scale
            )
            return .rendered(glyph)
        } catch {
            return .failed
        }
    }
}
