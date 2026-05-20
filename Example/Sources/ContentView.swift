import MarkdownKit
import MarkdownMath
import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    var body: some View {
        TabView {
            RenderTab()
                .tabItem { Label("渲染", systemImage: "doc.richtext") }
            EditorTab()
                .tabItem { Label("编辑", systemImage: "square.and.pencil") }
            StreamTab()
                .tabItem { Label("流式", systemImage: "dot.radiowaves.right") }
        }
    }
}

private extension View {
    @ViewBuilder
    func inlineNavigationTitleDisplayMode() -> some View {
        #if os(iOS)
            navigationBarTitleDisplayMode(.inline)
        #else
            self
        #endif
    }
}

// MARK: - StylePreset

private enum StylePreset: String, CaseIterable, Identifiable {
    case `default` = "默认"
    case compact = "紧凑"
    case large = "大字号"

    var id: String {
        rawValue
    }

    var renderStyle: RenderStyle {
        switch self {
        case .default:
            return .default
        case .compact:
            var s = RenderStyle.default
            s.paragraphSpacing = 2
            s.quoteIndent = 8
            return s
        case .large:
            var s = RenderStyle.default
            #if canImport(UIKit)
                s.bodyFont = .preferredFont(forTextStyle: .title3)
                s.codeFont = .monospacedSystemFont(ofSize: 17, weight: .regular)
            #elseif canImport(AppKit)
                s.bodyFont = .systemFont(ofSize: 17)
                s.codeFont = .monospacedSystemFont(ofSize: 16, weight: .regular)
            #endif
            s.paragraphSpacing = 12
            return s
        }
    }
}

// MARK: - RenderTab

private struct RenderTab: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownText(sampleMarkdown)
                    .markdownStyle(self.preset.renderStyle)
                    .mathRenderer(self.mathRenderer)
                    .svgRenderer(self.svgBlockRenderer)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .navigationTitle("MarkdownKit")
            .inlineNavigationTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("样式", selection: self.$preset) {
                        ForEach(StylePreset.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
            }
        }
    }

    @State private var preset: StylePreset = .default
    // Stored once so the JSContext inside MathJaxRenderer is not rebuilt every body pass.
    private let mathRenderer = MathJaxRenderer()
    // Stored once so the SwiftDraw rasterizer state is reused across body passes.
    private let svgBlockRenderer = SwiftDrawSVGBlockRenderer()
}

// MARK: - EditorTab

private struct EditorTab: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MarkdownEditor(text: self.$source)
                    .markdownStyle(self.preset.renderStyle)
                    .onSelectionChange { self.selection = $0 }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Selection: \(self.selection.location), length \(self.selection.length)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            self.source = editorSampleMarkdown
                        } label: {
                            Label("重置示例", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            self.source.append("\n\n- [ ] 新任务\n- [ ] 继续输入…")
                        } label: {
                            Label("追加段落", systemImage: "plus.bubble")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial)
            }
            .navigationTitle("源码编辑器")
            .inlineNavigationTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("样式", selection: self.$preset) {
                        ForEach(StylePreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
            }
        }
    }

    @State private var preset: StylePreset = .default
    @State private var source = editorSampleMarkdown
    @State private var selection = MarkdownEditorSelection(location: 0, length: 0)
}

// MARK: - StreamTab

private struct StreamTab: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownStreamingText(self.streamSource)
                    .mathRenderer(self.mathRenderer)
                    .svgRenderer(self.svgBlockRenderer)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .navigationTitle("流式输出")
            .inlineNavigationTitleDisplayMode()
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button {
                        if self.isRunning {
                            self.stopStream()
                        } else {
                            self.startStream()
                        }
                    } label: {
                        Label(
                            self.isRunning ? "停止" : "开始",
                            systemImage: self.isRunning ? "stop.circle" : "play.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(self.isRunning ? .red : .accentColor)

                    Button {
                        self.clearStream()
                    } label: {
                        Label("清空", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(self.isRunning || !self.hasOutput)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial)
            }
            .onDisappear {
                self.stopStream()
            }
        }
    }

    @State private var streamSource = MarkdownStreamingSource()
    // Stored once so the JSContext inside MathJaxRenderer is not rebuilt every body pass.
    private let mathRenderer = MathJaxRenderer()
    // Stored once so the SwiftDraw rasterizer state is reused across body passes.
    private let svgBlockRenderer = SwiftDrawSVGBlockRenderer()
    @State private var isRunning = false
    @State private var hasOutput = false
    @State private var taskHandle: Task<Void, Never>?
    @State private var streamRunID = 0

    private func stopStream() {
        self.taskHandle?.cancel()
        self.taskHandle = nil
        self.streamRunID += 1
        self.isRunning = false
    }

    private func clearStream() {
        self.stopStream()
        self.streamSource.clear()
        self.hasOutput = false
    }

    private func startStream() {
        self.taskHandle?.cancel()
        self.streamRunID += 1
        let runID = self.streamRunID
        self.streamSource.clear()
        self.hasOutput = false
        self.isRunning = true
        self.taskHandle = Task {
            let tokens = streamTokens
            var didMarkOutput = false
            for token in tokens {
                guard !Task.isCancelled else {
                    break
                }
                do {
                    // Use try (not try?) so CancellationError propagates and stops the loop
                    try await Task.sleep(for: .milliseconds(Int.random(in: 18...55)))
                } catch {
                    break
                }
                await MainActor.run {
                    guard self.streamRunID == runID else {
                        return
                    }
                    self.streamSource.append(token)
                    if !didMarkOutput {
                        self.hasOutput = true
                        didMarkOutput = true
                    }
                }
            }
            await MainActor.run {
                guard self.streamRunID == runID else {
                    return
                }
                self.isRunning = false
                self.taskHandle = nil
            }
        }
    }
}

// MARK: - Sample content

private let sampleMarkdown = """
# MarkdownKit

基于 **TextKit 2** 构建的高性能 Markdown 渲染引擎，支持文字选择与流式输出。

## 文字格式

普通文字、**粗体**、*斜体*、***粗斜体***、~~删除线~~

行内代码：`NSTextLayoutManager`

链接：[swiftlang/swift-markdown](https://github.com/swiftlang/swift-markdown)

## 代码块

```swift
// 静态渲染
MarkdownText("**Hello** _MarkdownKit_")

// 流式输出
@State var source = ""
MarkdownText(source)
    .task {
        for await chunk in stream {
            source += chunk
        }
    }
```

## 引用块

> TextKit 2 以 `NSTextLayoutManager` 为核心，彻底取代了 TextKit 1 的 `NSLayoutManager`。
>
> 更精确的行片段布局，原生支持 RTL，更高效的懒加载渲染。
>
> > 嵌套引用：在引用中继续引用，支持多层嵌套。

## 无序列表

- **MarkdownText** 保持高保真只读渲染，**MarkdownEditor** 提供源码编辑
- 原生文字选择（iOS 选择把手 · macOS 鼠标拖拽）
- 流式渲染：增量更新 `NSTextContentStorage`，无闪烁
  - 嵌套子项：块级别 diff，只重渲已变化的区块
  - 嵌套子项：SwiftUI 原生 `MarkdownText` 视图

## 有序列表

1. 解析：`swift-markdown` → `BlockNode` / `InlineNode`
2. 渲染：`AttributedStringRenderer` → `NSAttributedString`
3. 排版：`NSTextLayoutManager` 排版并绘制
4. 展示：`MarkdownText` SwiftUI 视图

## 任务列表

- [x] TextKit 2 渲染引擎
- [x] iOS 文字选择（选择把手）
- [x] macOS 文字选择（鼠标拖拽）
- [x] 流式输出 / 增量渲染
- [x] Markdown 源文本编辑器
- [ ] 表格支持
- [x] 代码语法高亮

## 表格（窄表）

| 功能 | 状态 | 备注 |
|------|:----:|------|
| TextKit 2 | ✅ | 直接驱动 |
| 表格渲染 | ✅ | GFM 标准 |
| 图片加载 | ✅ | 异步 URLSession |
| 链接点击 | ✅ | 系统浏览器 |

## 表格（宽表 — 测试横向滚动）

| 组件 | 平台 | 最低系统 | 渲染引擎 | 线程模型 | 性能等级 | 文字选择 | 流式支持 | 备注 |
|------|:----:|:--------:|----------|:--------:|:--------:|:--------:|:--------:|------|
| MarkdownText | iOS | 26.0 | TextKit 2 | MainActor | ⭐⭐⭐⭐⭐ | ✅ | ✅ | SwiftUI 原生视图 |
| MarkdownLabelView | iOS | 26.0 | TextKit 2 | MainActor | ⭐⭐⭐⭐⭐ | ✅ | ✅ | UIView 封装 |
| MarkdownLabelView | macOS | 26.0 | TextKit 2 | MainActor | ⭐⭐⭐⭐⭐ | ✅ | ✅ | NSView 封装 |
| AttributedStringRenderer | 全平台 | 26.0 | — | 任意 | ⭐⭐⭐⭐ | N/A | ✅ | 纯值类型渲染器 |
| MarkdownParser | 全平台 | 26.0 | swift-markdown | 任意 | ⭐⭐⭐⭐ | N/A | ✅ | 基于 cmark |

## 表格（数据对比）

| 框架 | Stars | 语言 | TextKit 版本 | SwiftUI | 流式 | 表格 | 代码高亮 | 最后更新 |
|------|------:|:----:|:------------:|:-------:|:----:|:----:|:--------:|----------|
| MarkdownKit | — | Swift | TextKit 2 | ✅ | ✅ | ✅ | ✅ | 2026 |
| Down | ~1.2k | Swift | TextKit 1 | ❌ | ❌ | ✅ | ✅ | 2024 |
| Ink | ~2.8k | Swift | — | ❌ | ❌ | ✅ | ❌ | 2023 |
| MarkdownUI | ~2.5k | Swift | — | ✅ | ❌ | ✅ | ✅ | 2025 |
| AttributedString | 内置 | Swift | TextKit 2 | ✅ | ❌ | ❌ | ❌ | — |

## 嵌套列表

- 一级项目
  - 二级项目
    - 三级项目
  - 另一个二级
- 回到一级

## 标题层级

### H3 三级标题

#### H4 四级标题

##### H5 五级标题

###### H6 六级标题

## 分割线

---

## 流程图（Mermaid）

```mermaid
graph LR
A[张三] -- 师徒 --> B[李四]
A -- 结拜兄弟 --> D[赵六]
B -- 结发夫妻 --> C[王五]
B -- 师徒 --> E[小七]
D -- 盟友 --> C
D -. 暗中监视 .-> E
A -. 宿敌 .-> C
E -- 徒弟 --> F[阿八]
F -. 叛变 .-> A
C -- 知己 --> F
```

## 数学公式

通过 `MarkdownMath` 接入 MathJax，支持四种 LaTeX 定界符。

行内：质能方程 $E=mc^2$，欧拉恒等式 \\(e^{i\\pi}+1=0\\)，对角线 $\\sqrt{2}\\approx1.414$。

块级（`$$ … $$`）：

$$\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}$$

块级（`\\[ … \\]`）：

\\[ \\int_0^1 x^2\\,dx = \\frac{1}{3} \\]

矩阵：

$$\\begin{matrix} a & b \\\\ c & d \\end{matrix}$$

## SVG 代码块（流式渲染）

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 60" width="120" height="60"><rect width="120" height="60" rx="8" fill="#4C8BF5"/><text x="60" y="38" font-size="20" text-anchor="middle" fill="white">SVG</text></svg>
```

## 中文支持

完美支持**中文**与 English 混排。TextKit 2 原生支持 Unicode 全字符集，行内断字规则与系统文本视图保持一致。

*Enjoy MarkdownKit!* ✨
"""

/// Simulate token-by-token streaming: split on every ~2 characters
private let streamTokens: [String] = {
    let text = """
    # 流式输出演示

    这段文字模拟了大语言模型 **逐 token** 输出的场景，覆盖了 MarkdownKit 支持的各类语法元素。

    ## 工作原理

    每次收到新的文本 chunk，解析器会重新解析**整个累积字符串**，然后与上一次的块列表做 diff，只更新发生变化的区块，从而实现无闪烁的流式渲染。

    ```swift
    // 核心增量渲染逻辑
    public func appendMarkdown(_ chunk: String) {
        streamingSource += chunk
        _parseTask?.cancel()          // 丢弃上一次未完成的解析
        _parseTask = Task {
            let newBlocks = await Task.detached(priority: .userInitiated) {
                MarkdownDocument(parsing: streamingSource).blocks
            }.value
            applyBlocks(newBlocks,
                        prevBlocks: prevBlocks,
                        prevStarts: prevStarts)
        }
    }
    ```

    ## 特性验证

    - [x] 增量渲染，无闪烁
    - [x] 标题实时出现，字体权重正确
    - [x] 代码块逐字显示，背景不跳动
    - [x] 表格实时建立，列宽稳定
    - [x] 引用块、列表、分割线
    - [ ] 代码语法高亮（规划中）
    - [ ] 图片内联（规划中）

    ## 流式表格（窄）

    | 阶段 | 耗时 | 说明 |
    |------|-----:|------|
    | 解析 | ~0.3 ms | cmark 原生解析 |
    | 渲染 | ~0.5 ms | AttributedString 生成 |
    | 排版 | ~0.8 ms | TextKit 2 行片段 |
    | 绘制 | ~0.2 ms | Core Graphics |
    | **合计** | **~1.8 ms** | **60 fps 绰绰有余** |

    ## 流式表格（宽 — 测试横向滚动）

    | 模型 | 提供商 | 上下文窗口 | 输出速度 | 多模态 | 函数调用 | 流式 | 延迟 | 价格/1M tokens |
    |------|--------|:----------:|:--------:|:------:|:--------:|:----:|:----:|---------------:|
    | GPT-4o | OpenAI | 128 k | 快 | ✅ | ✅ | ✅ | 低 | $5.00 |
    | Claude 4 Sonnet | Anthropic | 200 k | 快 | ✅ | ✅ | ✅ | 低 | $3.00 |
    | Gemini 2.5 Pro | Google | 1 M | 中 | ✅ | ✅ | ✅ | 中 | $3.50 |
    | Llama 3.3 70B | Meta | 128 k | 快 | ❌ | ✅ | ✅ | 低 | 开源 |
    | Qwen 2.5 72B | Alibaba | 128 k | 快 | ✅ | ✅ | ✅ | 低 | 开源 |

    ## 适用场景

    1. **ChatGPT / Claude** 等 LLM 接口的实时响应展示
    2. **代码补全**预览，支持语法块渐进显示
    3. **文档生成**工具，边生成边预览
    4. 任何需要**渐进式文字展示**的场合

    ## 代码示例 — SwiftUI 集成

    ```swift
    struct ChatView: View {
        @State private var markdown = ""

        var body: some View {
            ScrollView {
                MarkdownText(markdown)
                    .padding()
            }
            .task {
                // 模拟流式接收
                for try await token in llmStream {
                    markdown += token
                }
            }
        }
    }
    ```

    ## 数学公式（流式）

    流式场景下数学公式同样增量渲染。行内：高斯求和 $1+2+\\dots+n=\\frac{n(n+1)}{2}$。块级：

    $$e^{i\\pi}+1=0$$

    ## SVG 代码块（流式）

    流式场景下 `svg` 代码块逐 token 累积，解析完整后异步光栅化、命中缓存即落位为图像；未注入 renderer 时降级为高亮源码。

    ```svg
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 60" width="160" height="60"><rect width="160" height="60" rx="10" fill="#4C8BF5"/><circle cx="30" cy="30" r="14" fill="#FFD166"/><text x="100" y="38" font-size="20" text-anchor="middle" fill="white">stream</text></svg>
    ```

    ## 引用块测试

    > **TextKit 2** 是苹果在 WWDC 2021 推出的全新文字排版引擎，以 `NSTextLayoutManager` 为核心。
    >
    > 相比 TextKit 1，它提供了更精确的行片段布局、原生 RTL 支持以及更高效的懒加载渲染。
    >
    > > 嵌套引用：`NSTextLayoutFragment` 是 TextKit 2 的最小布局单元，
    > > 每个段落、列表项、代码块都对应一个 fragment。
    > >
    > > > 三层嵌套：fragment 内部通过 `NSTextLineFragment` 表示单行，
    > > > 支持跨行的连字（ligature）与双向文字（bidi）。

    ## 嵌套列表

    - **解析层**
      - `MarkdownParser` — 调用 swift-markdown，输出 `[BlockNode]`
      - `BlockNode` — 统一的中间表示，与平台无关
        - `.paragraph`, `.heading`, `.codeBlock`, `.table`…
    - **渲染层**
      - `AttributedStringRenderer` — 值类型，线程安全
        - 接收 `availableWidth`，内联计算 tab stops
        - 溢出表格：文字置透明，写入 `.markdownTableNaturalWidth`
    - **显示层**
      - `MarkdownLabelView` — 平台视图（UIView / NSView）
        - TextKit 2 直接驱动，无中间层
        - 溢出表格由 `_syncTableOverlays()` 注入独立 ScrollView

    ---

    ## 性能指标

    在 iPhone 15 Pro 上，渲染 **500 行** Markdown（含表格、代码块、嵌套列表）：

    - 首次渲染：< **8 ms**
    - 流式追加（单 token）：< **2 ms**
    - 内存占用：< **4 MB**
    - CPU（持续流式）：< **3%**

    > 以上数据在 Release 模式、关闭 Instruments 附加的条件下测量。

    ---

    **流式输出完成！** 🎉 感谢体验 MarkdownKit。
    """
    var tokens: [String] = []
    var idx = text.startIndex
    while idx < text.endIndex {
        let next = text.index(idx, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
        tokens.append(String(text[idx..<next]))
        idx = next
    }
    return tokens
}()

private let editorSampleMarkdown = """
# MarkdownEditor

这是一个基于系统 `UITextView` / `NSTextView` 的 Markdown **source editor**。

## 已接入能力

- [x] Markdown token 高亮
- [x] 代码围栏语言高亮
- [x] 回车续写列表
- [x] 空列表项回车退出
- [x] Tab 缩进 / Shift-Tab 反缩进
- [x] Cmd-B / Cmd-I / Cmd-K / Cmd-Shift-C

## 快速试试

1. 在任务列表末尾按回车，观察是否自动续写
2. 把光标放到空的 `- ` 项后按回车，观察是否退出列表
3. 选中几行按 Tab 或 Shift-Tab，观察缩进变化
4. 选中文本后使用快捷键包裹强调、链接或代码

```swift
struct EditorDemo: View {
    @State private var text = "# Hello\n\n- [ ] edit me"

    var body: some View {
        MarkdownEditor(text: $text)
            .markdownStyle(.default)
    }
}
```

> 第一版目标是稳定的源码编辑，不是 WYSIWYG。
"""

// MARK: - Preview

#Preview {
    ContentView()
}
