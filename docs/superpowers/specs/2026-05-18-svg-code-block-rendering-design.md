# ```svg 代码块渲染 — 设计文档

- 日期：2026-05-18
- 状态：已通过 brainstorming（方案 B 已选定、设计已用户确认），待写实现计划
- 分支：`feat/latex-math-rendering`（与 LaTeX 数学渲染同一工作体；复用其 SVGRasterizer 与异步注入模板）
- 关联：`docs/superpowers/specs/2026-05-16-latex-math-rendering-design.md`

## 1. 目标与范围

当 fenced code block 的语言为 `svg` 时，将其 body（本身即一段完整 SVG 文档）渲染为图像，而非语法高亮代码文本。

**支持范围（已确认）**

- ` ```svg ... ``` ` 代码块在只读视图（`MarkdownText` / `MarkdownStreamingText`）中渲染为 SVG 图像
- 启用方式：独立 `SVGBlockRendering` 协议 + `.svgRenderer(_:)` SwiftUI 修饰符（与 `MathRendering`/`.mathRenderer` 并行、互不耦合），`MarkdownMath` 提供基于 SwiftDraw 的实现
- 尺寸：从 SVG 原生 `viewBox`/`width`/`height` 解析宽高比，适宽、保比例、**不超过原生尺寸**（与现有 `![](url)` 图片渲染同行为）
- `MarkdownEditor`：` ```svg ` 仍只做代码 token 高亮，不渲染
- 未注入 `svgRenderer` 或 SVG 解析失败：优雅降级为现有 ` ```svg ` 语法高亮代码块（不崩、不空）

**明确不在范围**

- IR 改动（复用既有 `BlockNode.codeBlock(language:body:)`）
- 颜色注入（SVG 自带配色，按作者原样渲染——与 math 路径相反，math 注入 textColor，本特性**不**注入）
- 其它语言代码块的任何渲染变化（仅 `language` trim 后小写 == `svg`）
- 行内 SVG / SVG 文件引用 / 富文本复制 SVG（复制语义沿用既有：` ```svg ` 块按其原始 markdown 源复制，见 Bug 4 已实现的「复制原始 markdown 源」）
- 重构已评审的 math 子系统（方案 B 明确：并行自包含，零风险于 math）

## 2. 关键约束（决定方案的硬事实）

1. **RenderKit 必须零第三方依赖**：`AttributedStringRenderer`/RenderKit 不能直接调 SwiftDraw，故 ` ```svg ` 渲染必须走「占位 + 注入缝异步回填」——与 math 同款约束（非选择，是架构约束）。
2. **SVG body 即完整 SVG**：无需 MathJax、无需 `currentColor` 注入、无 ex/pointSize 关联尺寸；按 SVG 自身 `viewBox`/`width`/`height` 适宽渲染。
3. **复用已验证模板**：math 的 协议/coordinator/修饰符/接线/SVG 光栅化 经 ~16 任务两阶段评审打磨、并经 4 个运行时 bug 修复（含双平台、点尺寸契约、流式失效、缓存身份守卫），现全绿。本特性**镜像**这些模板而非改动它们。
4. **点尺寸契约**：返回 `image.size` 必须是点单位（非像素），与 Bug 13/SVGRasterizer 现状一致（UIKit 天然点、AppKit 显式修正）。
5. **流式/缓存/失效纪律**：必须复用 math 已修复的全部纪律——LRU 上限、三态、负缓存、代际失效、串行化、单次合并 updateContent、异步回写补对称 layout 失效、representable 身份守卫——否则会重蹈 Bug 1/10/12。

## 3. 模块分层

```
MarkdownCore         无改动（复用 BlockNode.codeBlock）
MarkdownRenderKit    新增 SVGBlockRendering 协议+类型 + .markdownSVGBlockSource + renderCodeBlock 分支（零依赖，平台无关）
MarkdownPlatformView 新增 SVGBlockLoadCoordinator（镜像 MathLoadCoordinator）+ MarkdownLabelView 并行接线（零新依赖）
OhMyMarkdown          新增 .svgRenderer(_:) 修饰符 + EnvironmentValues.markdownSVGBlockRenderer（镜像 .mathRenderer）
MarkdownMath  [现有] 新增 SwiftDrawSVGBlockRenderer: SVGBlockRendering（复用现有 SVGRasterizer 的 SwiftDraw 光栅化）
```

核心层（Core/RenderKit）保持零 SwiftDraw/第三方依赖；仅 `MarkdownMath` 实现侧依赖 SwiftDraw。未引入 `MarkdownMath` 时全库编译通过，` ```svg ` 优雅降级为代码块。

## 4. MarkdownRenderKit：协议、类型、渲染分支

新增文件 `Sources/MarkdownRenderKit/SVGBlockRendering.swift`：

```swift
extension NSAttributedString.Key {
    /// 未渲染 SVG 代码块占位标记，载荷为 SVG body 源串，对标 .markdownMathSource。
    public static let markdownSVGBlockSource = NSAttributedString.Key("OhMyMarkdown.svgBlockSource")
}

public struct SVGBlockGlyph: Sendable {
    public init(image: PlatformImage) { self.image = image }
    public let image: PlatformImage   // 点尺寸（适宽后实际渲染尺寸）
}

public enum SVGBlockOutcome: Sendable {
    case rendered(SVGBlockGlyph)
    case failed
    case cancelled
}

public struct SVGBlockCacheKey: Hashable, Sendable {
    public init(svg: String, availableWidth: CGFloat, rasterScale: CGFloat, rendererGeneration: Int)
    public let svg: String
    public let availableWidth: CGFloat   // 适宽依赖可用宽度 → 入键（宽度变即重渲染）
    public let rasterScale: CGFloat
    public let rendererGeneration: Int
}

public protocol SVGBlockRendering: Sendable {
    /// availableWidth 为可用排版宽度（点）；scale 为屏幕光栅化 scale。
    /// 实现按 SVG 原生宽高比适宽（不放大超过原生），返回点尺寸图像。
    func render(svg: String, availableWidth: CGFloat,
                scale: CGFloat) async -> SVGBlockOutcome
}
```

`AttributedStringRenderer`：
- 新增 `public var svgBlockCache: [SVGBlockCacheKey: SVGBlockGlyph] = [:]`、`public var svgRasterScale: CGFloat = 1`、`public var svgRendererGeneration: Int = 0`（镜像 math 三件套，平台层填充）。
- `renderCodeBlock(language:body:)` 内：当 `language?.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() == "svg"` 时分流到 `renderSVGBlock(svg:)`；否则保持现有代码块渲染（语法高亮）完全不变。
- `renderSVGBlock(svg:)`：构 `SVGBlockCacheKey(svg:svg, availableWidth:self.availableWidth, rasterScale:self.svgRasterScale, rendererGeneration:self.svgRendererGeneration)`；命中 `svgBlockCache` → 居中 `NSTextAttachment`（`bounds.size = glyph.image.size`，独立成段、`alignment=.center`，无基线偏移——块级图非行内，`bounds.origin.y=0`）；未命中 → **保持现有 ` ```svg ` 语法高亮代码块渲染**，并在该代码块 range 上附 `.markdownSVGBlockSource = svg`（供平台层异步触发；降级态本身就是可读的高亮代码，天然是「未渲染/降级」的合理呈现）。
- 不注入颜色（不调用任何 colorHex/currentColor 逻辑）。

> 设计说明：占位态直接复用现有代码块高亮（而非 math 那种「等宽淡色 latex」），因为 ` ```svg ` 的合理降级**就是**显示其源码高亮；这也使「未注入 renderer」与「渲染中」与「渲染失败」三态都自然回落到「显示 SVG 源码块」，UX 一致且无需额外占位样式。

## 5. MarkdownPlatformView：SVGBlockLoadCoordinator + 接线

新增 `Sources/MarkdownPlatformView/SVGBlockLoadCoordinator.swift`：**直接镜像** `MathLoadCoordinator` 的最终（经 Bug 10/审）形态——`public actor`，成员 `renderer:(any SVGBlockRendering)?`、`generation`、`positive:[SVGBlockCacheKey:SVGBlockGlyph]`（LRU，`positiveCap=256`，`lruOrder`）、`negative:Set`（`negativeCap=1024`，溢出 removeAll）、`inFlight:Set`、`tasks:[SVGBlockCacheKey:Task<Void,Never>]`；方法 `setRenderer`（generation++ 清正/负/inFlight/tasks/lruOrder）、`invalidateForScaleChange`、`glyph(for:)`（命中 touchLRU）、`isNegativeCached`、`@discardableResult loadIfNeeded(...)`（nil renderer early-out；positive/negative/inFlight 去重；派发 Task 调 `renderer.render` → `finish`）、`finish`（.rendered→positive+evict、.failed→negative+cap、.cancelled→不缓存）、`awaitGlyph(for:)`（await 该 key 任务后 glyph）、`drain()`（测试用）。语义逐条对齐 math（含 Bug 10 的 LRU/负缓存上限、Bug 11 的 awaitGlyph per-key）。

`MarkdownLabelView`（iOS `#if canImport(UIKit)` + AppKit）：
- 新增 `private let _svgBlockCoordinator = SVGBlockLoadCoordinator()`、`public var svgBlockRenderer:(any SVGBlockRendering)? { didSet { Task { await _svgBlockCoordinator.setRenderer(svgBlockRenderer) } } }`（didSet 加与 mathRenderer 同款 eventual-consistency 注释）。
- 新增 `triggerSVGBlockLoads(in:)`，紧随既有 `triggerMathLoads` 调用点（4 处：iOS/AppKit × 全量/增量），**镜像 Bug 11 修复后的 triggerMathLoads 最终形态**：同步枚举 `.markdownSVGBlockSource` 收集请求 → 单个 `Task` 读一次 `generation` 构键 → `loadIfNeeded` 全部 → `awaitGlyph` 全部 → 一次合并 `await MainActor.run { _cachedRenderer?.svgRasterScale/svgRendererGeneration/svgBlockCache[key] 回写 + updateContent() }`（仅 resolved 非空时一次 updateContent）；scale 取值与 math 同（iOS `window?.screen.scale`、AppKit `window?.backingScaleFactor`）。回写经既有 `resetLayout()`（Bug 1 修复后已含对称 layout 失效，svg 块同样剧烈改变高度，复用该已修路径即正确）。
- 异步回写复用 `resetLayout()` 既有（Bug 1 已修）失效纪律；不另改 resetLayout。

## 6. OhMyMarkdown：.svgRenderer(_:) 修饰符

新增 `Sources/OhMyMarkdown/SVGBlockRendererModifier.swift`（镜像 `MathRendererModifier`）：私有 `EnvironmentKey` + `public var EnvironmentValues.markdownSVGBlockRenderer:(any SVGBlockRendering)?` + `public func View.svgRenderer(_:) -> some View`。`MarkdownText`/`MarkdownStreamingText` 的 representable（iOS+AppKit）读 `@Environment(\.markdownSVGBlockRenderer)` 并在 update 中赋 `view.svgBlockRenderer`——**带与 Bug 12 同款的 `lastSVGBlockRenderer` 身份守卫**（`isSameSVGBlockRenderer` 引用身份比较），避免每次 SwiftUI 刷新触发 `setRenderer` 清空缓存。`MarkdownEditor` 不接（编辑器不渲染）。

## 7. MarkdownMath：SwiftDrawSVGBlockRenderer

新增 `Sources/MarkdownMath/SwiftDrawSVGBlockRenderer.swift`：`public final class SwiftDrawSVGBlockRenderer: SVGBlockRendering, @unchecked Sendable`。`render(svg:availableWidth:scale:)`：`Task.isCancelled` 哨兵 → 复用 `SVGRasterizer` 的 SwiftDraw 解析与 `ex→px` 归一（**不调 injectColor**——SVG 自带配色）→ 从 `drawing.size`（SwiftDraw 解析出的 viewBox/尺寸）算原生宽高比，目标点尺寸 = 宽 `min(原生宽, availableWidth)`、按比例算高（`availableWidth<=0` 或非有限时用原生尺寸）→ SwiftDraw 光栅化（按平台 `rasterize(size:scale:)`(UIKit) / `rasterize(with:scale:)`(AppKit) + AppKit `image.size=点尺寸` 修正，**复用 Bug-iOS 修复后的 SVGRasterizer 平台分支写法**）→ 退化（尺寸≤1）`.failed`，否则 `.rendered`；解析失败 `.failed`；取消 `.cancelled`。

> 复用点：`SVGRasterizer` 已有 `normalizeUnits`(ex→px)、SwiftDraw 解析、平台 rasterize 分支、点尺寸修正。本类新增的仅是「适宽按 availableWidth 而非 pointSize 定目标尺寸」「不注入颜色」。考虑把 SVGRasterizer 中可复用部分（解析+normalize+平台 rasterize+点尺寸修正）提取为内部共享函数，math 与 svg-block 两路各自传不同的「目标尺寸计算策略」——若提取不破坏既有 SVGRasterizer 测试/契约则做（DRY）；否则各自实现、SVGRasterizer 既有不动（不冒险回归已修复的 math 路径），二者择其一在实现计划阶段据实定。

## 8. 测试

- **RenderKit**（macOS 可跑，零依赖）：`language=="svg"`（含大小写/空白）→ 未命中出**语法高亮代码块 + `.markdownSVGBlockSource` 属性**（非裸占位）；命中 `svgBlockCache` → 居中 `NSTextAttachment`、`bounds.size==image.size`、`origin.y==0`、独立段 `alignment=.center`；非 `svg` 语言代码块渲染**零变化**（回归既有 codeBlock 高亮）；`SVGBlockCacheKey` 任一维度（svg/availableWidth/rasterScale/generation）不同则不等。
- **SVGBlockLoadCoordinator**（macOS）：镜像 MathLoadCoordinator 测试矩阵——nil renderer 不派发；.rendered 进正缓存+不重复派发；.failed 负缓存+不重复；.cancelled 不缓存可重试；setRenderer generation++ 且清缓存；LRU 超 cap 逐出；invalidateForScaleChange 清缓存且 generation 不变；awaitGlyph per-key（无需 drain 即得字形）。
- **OhMyMarkdown env**（macOS）：`markdownSVGBlockRenderer` 默认 nil、设后可取回；representable 身份守卫——同实例不重复 setRenderer（钉 Bug-12 同款，真守卫）。
- **视图接线**（非 GUI）：渲染含 ` ```svg ` 文档 → `.markdownSVGBlockSource` 占位属性可枚举 → 驱动 coordinator + 回写 `svgBlockCache` → 二次渲染出 attachment（镜像 MathViewWiringTests）。
- **MarkdownMath gated**（macOS，`MarkdownMathTests`）：真实 SVG（含 viewBox）→ `.rendered`，`image.size` 为点量级（非 pixel×scale）且宽 ≤ availableWidth、保比例、不超原生；非法 SVG → `.failed`；取消 → `.cancelled`；不注入颜色（彩色 SVG 像素保留作者颜色，非被改写）。
- **降级**：未注入 svgRenderer → ` ```svg ` 仍是语法高亮代码块（不空不崩）；SwiftDraw 解析失败 → 降级代码块。
- **不回归**：既有全量 + LaTeX 特性 + Bug1/2/3/4 守卫全绿；iOS `xcodebuild` BUILD SUCCEEDED（双平台）。

## 9. 风险与已知限制

1. **DRY 与回归权衡**：复用 `SVGRasterizer` 内部（解析/normalize/平台 rasterize/点尺寸）能减重复，但提取共享函数有改动已修复 math 路径的回归风险。决策准则：仅当提取后 `SVGRasterizerUnitTests`（含点尺寸契约、ex→px、像素守卫）与 math 全链零回归才提取；否则并行实现、SVGRasterizer 既有逐字不动。计划阶段据实定，实现期以「math 路径零回归」为硬门。
2. **适宽尺寸的 SVG 解析依赖**：原生宽高来自 SwiftDraw 解析的 `drawing.size`（viewBox 或 width/height）。若 SVG 无 viewBox 且 width/height 为百分比（如 `width="100%"`，类似 Task 14 评审发现的 container 模式问题）→ SwiftDraw 可能解析失败或尺寸异常 → `.failed` 降级为代码块（可接受、不崩）。普通带 viewBox 的 SVG 正常。
3. **流式**：未闭合 ` ```svg ` 是不完整 fenced block，swift-markdown 不会产出 codeBlock 或产出部分——按现有 codeBlock 解析行为，闭合后才成 ` ```svg ` 块并触发渲染；中途显示源码（可接受，与 math 中途半截一致思路）。
4. **复制**：` ```svg ` 块复制沿用 Bug 4 已实现的「复制原始 markdown 源」——复制出 ` ```svg\n<源>\n``` ` 原文（块级 sourceRange 已覆盖 codeBlock），无需本特性额外处理。
5. **安全**：SwiftDraw 静态渲染，无 JS 执行、无外部资源加载，渲染不可信 SVG 不引入脚本/SSRF 面（仅 CG 绘制）。

## 10. 验收标准

- ` ```svg <带 viewBox 的合法 SVG> ``` ` 经 `.svgRenderer(SwiftDrawSVGBlockRenderer())` 在 MarkdownText 渲染为居中图像，适宽、保比例、不超原生
- 彩色 SVG 按作者配色渲染（未被注入/改色）
- 未注入 svgRenderer 或非法 SVG → 显示 ` ```svg ` 语法高亮代码块（不空不崩）
- 非 `svg` 语言代码块渲染与现状完全一致（零回归）
- `MarkdownEditor` 中 ` ```svg ` 仍是源码 token 高亮、不渲染
- 流式追加含 ` ```svg ` 不崩、闭合后渲染、无 Bug-1 类重叠（复用已修 resetLayout 失效）
- 切换/重设 svgRenderer 或视图反复刷新不清缓存抖动（Bug-12 同款身份守卫）
- 复制含 ` ```svg ` 的选区 → 得 ` ```svg ` 原始 markdown 源（Bug 4 已覆盖）
- 全库（含 LaTeX + Bug1/2/3/4 守卫）零回归；macOS 全量绿 + iOS xcodebuild BUILD SUCCEEDED
- 核心层（Core/RenderKit）零 SwiftDraw 依赖；未引入 MarkdownMath 时全库编译通过且 ` ```svg ` 降级为代码块
