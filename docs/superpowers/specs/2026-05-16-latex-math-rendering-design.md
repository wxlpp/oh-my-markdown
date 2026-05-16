# LaTeX 数学公式渲染 — 设计文档

- 日期：2026-05-16
- 状态：已通过 brainstorming，待写实现计划
- 适用库：[MathJaxSwift](https://github.com/colinc86/MathJaxSwift)（colinc86）

## 1. 目标与范围

为 MarkdownKit 增加 LaTeX 数学公式渲染能力。

**支持范围（已确认）**

- 行内公式：`$…$`、`\(…\)`
- 块级公式：`$$…$$`、`\[…\]`
- 只读视图（`MarkdownText` / `MarkdownLabelView` / `MarkdownStreamingText`）渲染公式
- `MarkdownEditor`（源码编辑器）：对四种定界符做 token 高亮，**不渲染**
- 非法 LaTeX：直接展示 MathJax 自己生成的错误输出 SVG（红色提示），不另做错误样式

**明确不在范围**

- WYSIWYG 公式编辑
- 编辑器内公式实时预览
- `chtml` / `mathml` 输出路径（只走 SVG）
- 化学式等需要额外 MathJax 扩展包之外的能力（默认 `loadPackages: .all`，不再扩展）

## 2. 关键约束（决定方案的硬事实）

1. **`\(…\)` / `\[…\]` 必须在源码层预扫描**：CommonMark 把 `\( \) \[ \]` 当转义标点，反斜杠被吞、定界符丢失。swift-markdown 解析完再从 `.text` 找已来不及，必须在喂给 swift-markdown **之前**扫描原始源码。`$` 不是 CommonMark 特殊字符可存活，但为统一一起在预扫描处理。
2. **MathJaxSwift 只产出 SVG 字符串**，不光栅化。渲染管线基于 `NSTextAttachment`（图像），需要 SVG → `PlatformImage` 步骤。选用 `SwiftDraw`（纯 Swift SPM，支持 `<defs>/<use>/currentColor`）。
3. **渲染必须异步 + 缓存**：MathJax 跑在 JavaScriptCore，init 与转换都重。复用现有图片管线模式（占位文本 + 自定义属性 → 平台层异步加载 → 填缓存 → 重渲染）。
4. **基线对齐**：MathJax SVG 自带 `vertical-align: -X.XXex`，需解析后设到 `NSTextAttachment.bounds.y`，行内公式才落在文字基线上。
5. **模块化（已确认）**：核心三层保持零额外依赖；MathJaxSwift + SwiftDraw 收敛到独立可选产品 `MarkdownMath`，渲染器只暴露注入协议。

## 3. 模块分层

```
MarkdownCore         新增 IR 节点 + MathScanner（零新依赖）
MarkdownRenderKit    新增占位/缓存 + MathRendering 协议（零新依赖，仍平台无关）
MarkdownPlatformView 新增异步加载循环，镜像图片那套（零新依赖）
MarkdownKit          SwiftUI 透出 .mathRenderer(_:) 修饰符（零新依赖）
MarkdownMath  [新]   MathJaxSwift + SwiftDraw，实现 MathRendering（独立 product）
```

未引入 `MarkdownMath` 时整库可正常编译运行，公式优雅降级为原始 LaTeX 文本。

## 4. MarkdownCore：IR 与解析

### 4.1 IR 新增

```swift
// InlineNode 新增
case math(latex: String)        // 行内：$…$、\(…\)

// BlockNode 新增
case mathBlock(latex: String)   // 块级：$$…$$、\[…\]
```

保持 `Sendable` / `Equatable`。`latex` 存去掉定界符后的原始公式串。

### 4.2 MathScanner（源码层预扫描）

在 `MarkdownDocument.init(parsing:)` 中、调用 `Markdown.Document(parsing:)` **之前**执行：

1. 扫描原始 source，按四种定界符切出数学区段，规则：
   - 跳过围栏代码块（``` ``` ```）、缩进代码块、行内 `` `…` `` 内的定界符
   - `\$` 转义视为字面美元，不作定界符
   - 定界符未配对 → 整体当字面文本（流式中途半截公式靠此优雅降级）
   - display 由定界符类型决定：`$$` / `\[\]` ⇒ 块级；`$` / `\(\)` ⇒ 行内
2. **哨兵编码（防伪造）**：保留一个固定私有区标量 `U+10FE00`（SPUA-B）作哨兵字符。每段数学分配一个递增索引，存入 `index → (latex, display)` 旁路表；替换文本 = `哨兵标量 + 索引数字 + 哨兵标量`。哨兵字符**不携带 latex 内容**，只是定位锚。
   - 替换前先扫描原始 source：若用户文本本身已含该保留标量，逐个转义为一个不冲突的占位转义序列，IR 构建完成后再还原。保证「能存活进 IR 的哨兵」一定由 `MathScanner` 注入，用户文本无法伪造或碰撞。
3. swift-markdown 正常解析替换后的源码
4. **就地回填（保留容器结构）**：递归遍历 IR 树（`paragraph` / `blockquote` 内层 / `ListItem.blocks` / 嵌套列表 / 表格单元格），把哨兵锚换回数学节点：
   - 行内哨兵 → 原位 `InlineNode.math`
   - 块级哨兵：当其所在段落「仅含该一个块级哨兵」时，**用 `BlockNode.mathBlock` 原位替换该段落节点**——在其父容器（blockquote / list item / 顶层）的 `children` 中替换，**绝不上提到顶层、绝不重排兄弟节点**
   - 块级哨兵出现在段落中间（前后有文字）时：在**当前父容器内**就地把该段落拆成 `[前段落, mathBlock, 后段落]`，顺序与嵌套层级保持不变
   - 块级定界符出现在只能容纳 `[InlineNode]` 的上下文（表格单元格）时：降级为行内 `InlineNode.math`（`BlockNode` 无法进入 `TableCell`）
5. `MarkdownDocument.parsingAppend(to:previousSource:)`（增量流式路径）对重解析的 suffix 同样跑完整 `MathScanner`（含哨兵转义/还原与就地回填）；索引旁路表按本次解析作用域局部分配，不跨 prefix/suffix 复用

### 4.3 增量解析的「数学感知重解析边界」

现有 `parsingAppend` 保留 prefix 块、只从 tail 块（或表格相邻块）重解析。问题：若一个开界符（`$$` / `\[` / `$` / `\(`）落在**被保留的 prefix 块**里，闭界符随追加文本到达，suffix-only 的 `MathScanner` 看不到开界符 → 增量结果与全量解析永久不一致，且正常 append 不触发全量回退。

规则（必须实现并测试）：

- `parsingAppend` 在信任增量路径前，对 `previousSource` 跑 `MathScanner` 的定界符状态机，记录 prefix 末尾是否处于「未闭合数学跨段」状态，以及最靠后的未匹配开界符位置
- 若存在可能被追加文本闭合的未闭合开界符：
  - 将重解析起点**前移到该开界符所在块的起点**（扩大重解析窗口覆盖完整公式）；或
  - 无法安全定位时，**回退到全量 `MarkdownDocument(parsing:)`**
- 代码围栏 / 行内代码上下文同样纳入该状态机，避免误把代码内 `$$` 当未闭合开界符

### 4.4 共享定界符扫描

`MathScanner` 内部的定界符识别（含代码区/转义跳过规则）抽成共享工具，供编辑器 token 高亮复用，保证「高亮」与「解析」规则完全一致。

## 5. MarkdownRenderKit：占位、缓存、注入协议

仍零依赖、平台无关、纯值类型。

### 5.1 属性键与缓存

```swift
extension NSAttributedString.Key {
    static let markdownMathSource = NSAttributedString.Key("MarkdownKit.mathSource")
    // 编码 latex + display 标志，对标 .markdownImageSource
}

struct MathCacheKey: Hashable {           // latex + display + pointSize + colorHex
    let latex: String
    let display: Bool
    let pointSize: CGFloat
    let colorHex: String
}

struct MathRenderedGlyph: Sendable {
    let image: PlatformImage
    let baselineOffsetEx: CGFloat          // 由 SVG vertical-align 解析得到
}

// AttributedStringRenderer 新增
var mathCache: [MathCacheKey: MathRenderedGlyph] = [:]
```

样式 / 动态字体变化 ⇒ `pointSize` / `colorHex` 变 ⇒ key 变 ⇒ 自动重渲染（与图片缓存同思路）。

### 5.2 渲染规则

- `.math` / `.mathBlock`：
  - 缓存命中 → `NSTextAttachment`，`bounds.y` 由 `baselineOffsetEx` 换算（行内落到文字基线）
  - 未命中 → 占位文本（原始 latex，等宽淡色）+ `.markdownMathSource` 属性
- `BlockNode.mathBlock`：独立成段、居中

### 5.3 注入协议

```swift
public protocol MathRendering: Sendable {
    func render(latex: String, display: Bool,
                pointSize: CGFloat, color: PlatformColor) async -> MathRenderedGlyph?
}
```

RenderKit 只定义协议与类型，不依赖任何 MathJax 实现。

## 6. MarkdownPlatformView：异步加载循环

完全对标现有 `triggerImageLoads / loadImage / finishImageLoad`：

- `triggerMathLoads(in:)` 枚举 `.markdownMathSource` → 去重（`_mathLoading` 集合）→ `await mathRenderer.render(...)` → 填 `mathCache` → `updateContent()` 重渲染
- 持有 `var mathRenderer: (any MathRendering)?`，默认 `nil`
  - `nil` 时 `triggerMathLoads` **直接 early-out**（不进枚举循环、不派发任务），占位保持原始 latex 文本（不引入 MathJax 也能编译运行）
- `mathCache` 设上限（计数封顶 / LRU），避免流式长对话内存膨胀

### 6.1 失败的负缓存 / 退避（不可无限重试）

现有图片失败路径只把 source 移出 loading 集合、不记失败态，导致每次 `updateContent()`/流式 pass 都重试。镜像到 MathJax 会把一次依赖失败放大成成百次 JavaScriptCore + SVG 工作。规则（必须实现并测试）：

- 区分失败类型：
  - **确定性硬失败**（`MathJax()` init 抛错、JS 崩溃、SVG 光栅化失败）→ 按 `MathCacheKey` 写入**负缓存**，后续 `triggerMathLoads` 跳过该 key，不再派发；占位回落原始 latex 文本
  - **瞬态取消**（视图复用导致的 `Task` 取消）→ 不写负缓存，允许后续重试
- `MathJax()` init 抛错应只发生一次并被记住（实例级 `failed` 标志），不每个公式各抛一次
- 注意：LaTeX 语法错误**不算失败**——MathJax 返回错误 SVG，渲染成功并正常进 `mathCache`（对应已确认的「展示 MathJax 错误输出」）
- 负缓存与样式键一致：`pointSize` / `colorHex` 变化产生新 key，给一次重新尝试的机会

## 7. MarkdownKit（SwiftUI）

新增 `.mathRenderer(_:)` 修饰符，消费者显式 opt-in 注入 `MathJaxRenderer`。

## 8. MarkdownMath 新产品

`Package.swift`：

- 新依赖：`MathJaxSwift`（colinc86）、`SwiftDraw`
- 新 target `MarkdownMath` 依赖 `MarkdownRenderKit`
- 新 `.library(name: "MarkdownMath", targets: ["MarkdownMath"])`
- 独立测试 target（gated，避免核心测试拉入 MathJax）

`MathJaxRenderer: MathRendering`：

- 持有共享 `MathJax` 实例（懒加载）；**`MathJax()` init 抛错或 JS 硬失败** → `render` 返回 `nil` → 占位回落原始 latex 文本
- `tex2svg(latex, conversionOptions: .init(display: display), inputOptions: .init(loadPackages: .all), outputOptions:)`
- **LaTeX 语法错误**：MathJax 自身把错误渲染进 SVG（不抛错）→ 直接光栅化展示其红色错误输出
- SVG 后处理注入文字色（`currentColor` / root `color`）→ 解析 `ex` / `viewBox` / `vertical-align` → 按 `pointSize` 换算像素 → SwiftDraw 按屏幕 scale 光栅化 → `PlatformImage` + 基线偏移

## 9. 编辑器 token 高亮

- `MarkdownSourceHighlighter` 复用 `MathScanner` 共享定界符扫描，对四种形式只染色（像 inline code），不渲染
- `RenderStyle` 新增：
  - `mathTokenColor`（编辑器高亮色）
  - `mathScale`（默认 1.0）
  - `mathColorOverride`（nil → 用 `textColor`）

## 10. 测试

- **MathScanner**：四定界符；`\$` 转义；代码块/行内代码内不识别；未配对当字面；`\(` / `\[` 存活；块/行内分类；多行 `$$`
- **容器保留（高优先级）**：块级公式在列表项内、块引用内、嵌套列表内、块引用套列表内——均原位成为该容器子块，兄弟节点顺序与嵌套层级不变、不上提；表格单元格内的块定界符降级为行内 `.math`；段落中间的块级公式就地拆为前/公式/后三块且留在原父容器
- **哨兵防伪造**：源码本身含保留标量 `U+10FE00`、含形似 `哨兵+数字+哨兵` 的文本、含其它私有区字符时，均不得被误判为数学节点；转义/还原后用户文本字节级不变
- **IR / 增量**：`.math` / `.mathBlock` 位置正确；`parsingAppend` 在 prefix/tail 含公式时仍正确
- **增量边界（高优先级）**：开界符在被保留 prefix 块、闭界符在追加文本时，增量结果须与全量解析一致（前移重解析起点或全量回退）；跨多个 block 的 `$$…$$` 在逐 chunk 流式追加下最终渲染正确；代码围栏内的 `$$` 不触发误判
- **失败负缓存（高优先级）**：确定性硬失败的公式在后续多次 `updateContent()`/流式 pass 中**不被重复派发**（断言派发次数有上限）；`MathJax()` init 抛错全程只发生一次；瞬态取消后仍可重试；样式键变化后允许重新尝试
- **RenderKit**：空缓存 → 占位 + 属性存在；命中 → attachment 带基线 bounds；`mathRenderer == nil` 回落路径
- **MarkdownMath**（独立 gated target）：已知公式返回非空且尺寸为正；非法公式返回非空（MathJax 错误 SVG）；SVG 颜色注入生效
- **编辑器**：高亮只覆盖定界符区段

## 11. 风险与前置 spike

1. **SwiftDraw 对 MathJax SVG 的还原度**（`<use>/<defs>` / 字形 path / `currentColor`）——实现第一步即用真实 MathJax SVG 样本做验证 spike。不达标的回退：手解析 MathJax SVG 几何（工作量大）或换光栅化器
2. SVG `vertical-align` 解析驱动行内基线对齐的准确性
3. 流式中途半截 `$…$`：scanner 见未配对 → 暂作字面文本，闭合定界符到达后成公式（短暂闪烁，可接受）
4. **增量解析跨保留块漏判（已在 4.3 设计中规避）**：开界符在 prefix、闭界符在 suffix 时必须前移重解析起点或全量回退——实现须以「跨多 block 流式 $$」测试为准入门槛
5. **硬失败无限重试（已在 6.1 设计中规避）**：确定性失败须负缓存，区分瞬态取消；实现须以「失败公式流式不重复派发」测试为准入门槛
6. **容器结构破坏（已在 4.2 设计中规避）**：块级公式回填必须就地、保留父容器与兄弟顺序，绝不上提到顶层——实现须以嵌套场景测试为准入门槛
7. **哨兵伪造/碰撞（已在 4.2 设计中规避）**：保留标量 + 替换前转义已有出现 + 还原，确保用户文本无法跨越解析器信任边界

## 12. 验收标准

- `$x^2$`、`\(a+b\)` 行内渲染并落在文字基线
- `$$\int_0^\pi \sin x\,dx = 2$$`、`\[ ... \]` 块级居中渲染
- 非法公式显示 MathJax 红色错误输出
- 未引入 `MarkdownMath` 时全库编译通过，公式降级为原始文本
- `MarkdownEditor` 中四种定界符按 `mathTokenColor` 高亮，源码保持纯文本
- 列表项 / 块引用 / 嵌套列表内的块级公式渲染在原容器内、文档结构不错位
- 源码含保留哨兵标量或形似哨兵的文本时不被误渲染为公式、文本无损
- 跨多个块的 `$$…$$` 在逐 chunk 流式下最终渲染与全量解析一致
- 渲染器硬失败的公式不在流式中被反复重试（派发次数有上限）
- 流式追加含公式的文本不崩、最终渲染正确
- 现有图片 / 表格 / 列表等渲染与增量解析行为不回归
