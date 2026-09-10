# 跨 view 共享 cache + static/streaming 占位区分设计

- 日期：2026-05-31
- 范围：SVG 代码块 + Math 公式两条异步渲染路径——cache 跨 MarkdownLabelView 共享、未渲染期按"调用方式"区分占位形态
- 状态：已与用户确认，待转 plan

## 1. 背景与目标

OhMyMarkdown 当前 SVG 与 Math 的异步渲染管道由两个 actor 协调器（`SVGBlockLoadCoordinator` / `MathLoadCoordinator`）负责，每个 `MarkdownLabelView` 实例**各持一份**（私有 `let`）。下游 caller（oh-my-exam）在题库 cover 翻题时通过 `.id(item.id)` 强制重建 `MarkdownText`，view 重建 → 协调器随之重建 → cache 清空 → 同一份 SVG 复访仍重新渲染 → 用户看到 200–300ms 闪烁（代码块源串→图）。

同时 AttributedStringRenderer 在 cache-miss 分支统一显示「高亮代码块源串 + `.markdownSVGBlockSource` marker」，对**流式聊天**（用户在看着源码到达）合适，但对**静态题目**（题面是一次性渲染的最终状态）不合适——展示中间的 `\`\`\`svg ... \`\`\`` 源串就是闪。

oh-my-exam 已经在 app 端用 `.opacity` fade-in（220ms 等渲染器落定再淡入）兜了一手（PR #7 `bdca384`）。但这是补丁——MK 原生支持后即可删。

**目标**：

1. **A. coordinator 内部单例化**：`SVGBlockLoadCoordinator.shared` / `MathLoadCoordinator.shared`，`MarkdownLabelView` 默认引用 shared。多 view（含 `.id` 重建后的新 view）共享 LRU/dedup/in-flight 状态，复访同一份 SVG/公式从 cache 同步出图。`init()` 仍 public，tests 可拿独立实例。
2. **B. mode 区分**：`MarkdownLabelView` 跟踪 `renderMode: PlaceholderMode = .static`，`setMarkdown` 翻 `.static`、`appendMarkdown` 翻 `.streaming`。`AttributedStringRenderer` 多收一个 `placeholderMode` 参数，cache-miss 分支按 mode 选：
   - `.streaming` → 当前的高亮源码（用户看着 chunk 到达）
   - `.static` → 透明 attachment（占据空间但不显文字），marker 仍打，平台层照样 dispatch 渲染
3. **C. viewBox 预热**：static-miss 透明 attachment 的高度按 SVG `viewBox` 解析得 aspect 估算，math 按 `displayMode + pointSize` 估算。glyph 到达时几乎无 layout shift。

**目标受益**：

- oh-my-exam 翻题不再闪。app 端 `QuestionMarkdownView` 的 fade-in 与 `hasAsyncContent` 启发式整体删除。
- 同 SVG/公式跨 view 复访零延迟（cache 命中同步出图）。
- 流式聊天行为完全不变（mode = `.streaming` 走原路径）。

**非目标（YAGNI）**：

- 不引入 env-injectable coordinator（用户已确认 shared 单例足够；多项目若需隔离可走 `init()`）。
- 不动 `SVGBlockCacheKey` / `MathCacheKey` 四维结构（svg/latex, width/pointSize, scale, generation）。
- 不动 `setRenderer` didSet 既有契约（PR #5 R8 那一长串行为不变）。
- 不动 streaming-mode 行为（appendMarkdown 路径完全保留）。
- 不为 renderer.failed 加 fallback icon（既有"降级降级"语义保持——streaming 仍源串、static 仍空白）。
- 不缓存 viewBox 解析结果（每次 miss 解析一次，~100µs 噪声级）。

## 2. 架构与组件

### 2.1 A 块：内部共享 coordinator

```swift
// MarkdownPlatformView/SVGBlockLoadCoordinator.swift
extension SVGBlockLoadCoordinator {
    /// 进程级共享实例。所有 MarkdownLabelView 默认引用，cache 跨 view。
    /// 已存 LRU 256 / negative 1024（actor 隔离），同 process 全部 markdown
    /// 视图共用一份；renderer 切换（setRenderer 调用）会清整体 cache + 代际自增——
    /// 在 OhMyMarkdown 的 SwiftUI 注入约定下，所有 view 用同一 renderer 实例时
    /// 这条不构成问题。tests 通过 `init()` 取独立实例。
    public static let shared = SVGBlockLoadCoordinator()
}

// MathLoadCoordinator 同上
```

`MarkdownLabelView`：

```swift
// 原：
// private let _svgBlockCoordinator = SVGBlockLoadCoordinator()
// private let _mathCoordinator = MathLoadCoordinator()
// 改：
private let _svgBlockCoordinator: SVGBlockLoadCoordinator = .shared
private let _mathCoordinator: MathLoadCoordinator = .shared
```

不引入 env injection、不引入 `.svgCoordinator(_:)` modifier。doc-comment 写明：「所有 view 默认共享；多 renderer 隔离需走 init() + 自封装层」。

### 2.2 B 块：mode 区分

新增 placeholder mode 枚举：

```swift
// MarkdownRenderKit/PlaceholderMode.swift（新增文件）
public enum PlaceholderMode: Sendable {
    /// 静态完整渲染（setMarkdown 路径）：未命中时显示空白占位。
    case `static`
    /// 流式追加（appendMarkdown 路径）：未命中时显示高亮源码（用户在看着源到达）。
    case streaming
}
```

`AttributedStringRenderer`：增加 `placeholderMode` 字段（init 时传入，默认 `.static`）。`renderSVGBlock` / `renderMathBlock` 的 cache-miss 分支按 mode 选两条已有/新增代码路径。

`MarkdownLabelView`：

```swift
private var renderMode: PlaceholderMode = .static

public func setMarkdown(_ source: String) {
    self.renderMode = .static
    // 既有的 parse + buildAttributedString(...) 调用，传入 mode
    ...
}

public func appendMarkdown(_ chunk: String) {
    self.renderMode = .streaming
    ...
}

// 重渲染时（含 setRenderer didSet 路径）：用当前 self.renderMode 构造 renderer
```

### 2.3 C 块：viewBox / pointSize 预热高度

新增 `SVGViewBoxParser`：

```swift
// MarkdownRenderKit/SVGViewBoxParser.swift（新增文件）
public enum SVGViewBoxParser {
    /// 解析 SVG 字符串首 4KB 内的 `<svg ... viewBox="x y w h" ...>` 标签，
    /// 返回 `h/w` 比例（aspect ratio）。失败返回 nil。
    /// 典型耗时 < 100µs，不缓存（renderSVGBlock miss 分支同步调用）。
    public static func parseAspect(from svg: String) -> CGFloat?
}
```

`AttributedStringRenderer.renderSVGBlock` static-miss 分支：

```swift
let aspect = SVGViewBoxParser.parseAspect(from: svg) ?? 0.6   // 4:6 portrait-ish 兜底
let height = self.availableWidth * aspect
let attachment = TransparentAttachment(size: CGSize(width: self.availableWidth, height: height))
// 同时仍打 .markdownSVGBlockSource marker，平台层照样 dispatch
```

`AttributedStringRenderer.renderMathBlock` static-miss 分支：

```swift
let height = display ? pointSize * 2.0 : pointSize * 1.2
let attachment = TransparentAttachment(size: CGSize(width: self.availableWidth, height: height))
// 同时打 .markdownMathSource marker
```

`TransparentAttachment`：`NSTextAttachment` 子类（或工厂函数），`image = nil`，`bounds = (origin: .zero, size:)`，TextKit 自动留白。

## 3. 数据流

```
[caller]
  ↓ .markdownText("...") 评估 → updateUIView 检测 source 全新 → setMarkdown 路径
[MarkdownLabelView.setMarkdown(source)]
  ① renderMode = .static
  ② parse markdown → BlockNodes
  ③ AttributedStringRenderer(mode: .static, ...).render(blocks) → NSAttributedString
       └─ renderSVGBlock 命中 → centered attachment + image
       └─ renderSVGBlock 未命中 → TransparentAttachment(width × aspect)
                                    + .markdownSVGBlockSource marker
       └─ renderMathBlock 同形
  ④ apply 到 layoutManager
  ⑤ triggerSVGBlockLoads / triggerMathLoads（既有路径，调用 .shared.loadIfNeeded）
                                         ↓
                              renderer.render(...)（async）
                                         ↓
                              coordinator.finish → positive cache 写入
                                         ↓
                              通知 view 重渲染（既有机制：setNeedsLayout + 重 attribute）
                                         ↓
                              AttributedStringRenderer 第二趟（mode 不变）
                                         ↓
                              renderSVGBlock 现在 hit → 真实 image attachment
                                         ↓
                              layout 微调（aspect 估算精确 ≈ 0 shift）

[caller]
  ↓ source 续追加（updateUIView 检测到 hasPrefix）
[MarkdownLabelView.appendMarkdown(delta)]
  ① renderMode = .streaming
  ② parse delta，AttributedStringRenderer(mode: .streaming) render delta
       └─ 未命中 → 现有 renderHighlightedCodeBlock + marker（不变）
  ③ append；triggerLoads(delta range)
  （流式行为完全保留）
```

**Mode 切换语义**：snapshot at render time。既渲染过的 attachments 不重排；既派发未回写的占位也不强制 re-skin。后续 `setMarkdown` / `appendMarkdown` 的渲染按当时 mode 走。

**初始 mode**：构造时 `.static`（默认；零内容场景）。

**viewBox 解析时机**：仅在 static-miss 分支同步调用一次；hit 分支不进 parse。

## 4. 错误处理与边界

| 场景 | 行为 |
|---|---|
| SVG 无 viewBox attribute | aspect 回退 0.6，glyph 到达时有少量 layout shift |
| SVG viewBox 格式坏 / 不是 4 个数 | parser 返回 nil → 同上回退 |
| viewBox parser 性能上限 | 只搜 SVG 字符串首 4096 个 UTF-8 字节，找不到 `<svg ` 起始即视为无 viewBox |
| Math `pointSize` 缺省 | 用 `RenderStyle.bodyFont.pointSize` 兜底（始终非 nil） |
| Renderer 为 nil（disabled） | 既有：marker 不 dispatch；static-mode 透明占位持续，streaming 仍源串 |
| Renderer.failed（负缓存） | 同上：static 空白持续 / streaming 源串持续 |
| `setRenderer` / `invalidateForScaleChange` 清缓存 | 既有 hit → miss；下一帧 render 走当前 mode 占位；renderers 重派发 |
| Mode 切换时既有未渲染 attachments | 不 re-skin（snapshot at render time，§3） |
| 同份 SVG 在多 view 出现 | shared coordinator dedup；第一个 dispatch，余者 await 同结果 |
| 同份 SVG 在同 view 出现多次 | 同上（coordinator 是 key-级 dedup） |

## 5. 测试

### 5.1 新增单元测试

- `SVGViewBoxParserTests`：
  - 有 viewBox（width/height 整数、小数）
  - 无 viewBox
  - viewBox 数量不对（3 个或 5 个）
  - viewBox 包含非数字 token
  - `<svg ` 不在首部（前面有 XML 声明 + DOCTYPE 之类）
  - SVG 体积超过 4KB 但 viewBox 在首部 4KB 内 → 解析成功
  - SVG 体积超过 4KB 且 viewBox 在 4KB 外 → 返回 nil（性能上限契约）
- `TransparentAttachmentTests`（或并入 `AttributedStringRendererTests`）：
  - bounds.size 等于声明 size
  - image == nil 不崩
- `AttributedStringRendererStaticModeTests`：
  - static-miss SVG → emit transparent attachment + `.markdownSVGBlockSource` marker
  - static-miss Math（inline & display）→ emit transparent attachment + `.markdownMathSource` marker
  - streaming-miss SVG → 保持现有 `renderHighlightedCodeBlock` 行为（回归契约）
  - cache-hit 分支两 mode 下完全一致（emit attachment with image）
- `MarkdownLabelViewRenderModeTests`：
  - 初始 mode == `.static`
  - `setMarkdown(_:)` 后 mode == `.static`
  - `appendMarkdown(_:)` 后 mode == `.streaming`
  - `setMarkdown → setMarkdown` 仍 `.static`
  - `setMarkdown → appendMarkdown` 切到 `.streaming`，之后既有 attachments 不 re-skin（snapshot 契约）
- `SharedCoordinatorIntegrationTests`：
  - 注入计数 mock renderer 到 `SVGBlockLoadCoordinator.shared`
  - 两个 MarkdownLabelView 串行渲染同 SVG → renderer 只被调一次（cache 共享证据）
  - 与 `init()` 创建的独立 coordinator 隔离（两个独立实例各自渲染各自的）

### 5.2 回归

- 所有现存 `SVGBlock*Tests` / `Math*Tests` / `MarkdownRenderKitTests` / `MarkdownEditorProxyTests` / 等等全部仍绿
- 既有使用 `init()` 的测试不动（contract 保留：`init()` public、行为不变）
- Example app 应仍能 build + run（若 Example 用 `@State` 每 view 一份 renderer，cache 会在 view 间互清——这是已记录约束，不为 Example 优化）

### 5.3 命令

沿用 OhMyMarkdown 现状（仓 Tests/ 下用 Swift Testing 框架）：

- `swift build -Xswiftc -warnings-as-errors`（零警告通过）
- `swift test`
- 可选 `#Preview` 视觉抽查 light + dark（如本切片涉及 visible UI 变更）

## 6. 与下游 oh-my-exam 的整合

本 spec 落地后，oh-my-exam 端需要的 follow-up（不在 OhMyMarkdown 仓内，单独 PR 处理）：

1. bump OhMyMarkdown 依赖到含本切片的 commit
2. `QuestionMarkdownView` 删除 `hasAsyncContent` 启发式 + `@State visible` + `.opacity` + `.task(id:markdown)` 整段（PR #7 `bdca384` 引入的 fade-in 补丁）
3. iPad sim 实测验证：含 SVG/公式题目首次访问空白→图、复访同步出图、无源串闪烁

## 7. 已知限制与接受的风险

- viewBox 解析为字符串扫描（regex/手写状态机），不走完整 XML parser。理论上 corner case（如 `<svg` 出现在前置注释里）可误匹配；4KB 上限 + 取最外层 `<svg ` 实测足够。
- aspect 回退 0.6 是经验值，对 landscape SVG 会偏大、portrait SVG 偏小；glyph 到达仍 layout shift 少量。复杂场景留后续 polish。
- Math 高度估算为线性回归（display × 2 / inline × 1.2）。多行/嵌套公式可能偏小；同上，glyph 到达时 layout 调整。
- shared coordinator 让"多 renderer 隔离"成为隐含约束。doc 中写明，违反时（多 view 注入不同 renderer 实例）cache 互相清理是已知行为非 bug。
- 既有 setRenderer didSet 复杂行为（PR #5 R8）保留，未做精简。本切片仅在它之上加 placeholderMode。

## 8. 范围与提交节奏

本 MK PR 一次性落 A + B + C 三块（互相耦合：B 静态空白依赖 C 高度估算，否则静态空白等于零高度；A 是独立优化但同 PR 推共担 review 成本）。

下游 oh-my-exam fade-in 删除 + 依赖 bump 走独立小 PR。
