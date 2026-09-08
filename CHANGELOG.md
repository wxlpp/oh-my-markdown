# Change Log
All notable changes to this project will be documented in this file.
MarkdownKit adheres to [Semantic Versioning](http://semver.org/).

## [Main](https://github.com/wxlpp/MarkdownKit)
### Added

### Changed

### Removed

## [0.2.0](https://github.com/wxlpp/MarkdownKit)
破坏性发布。迁移指南见 [`docs/release/0.2.0-migration.md`](docs/release/0.2.0-migration.md)。

### Added
- **远程图片按需开启**：`markdownRemoteImages(_:)`。`.defaultHTTPS` 走独立
  `URLSession`（不共享 cookie / 凭据 / 缓存），仅 HTTPS，仅
  PNG/JPEG/GIF/WebP/HEIC/HEIF，编码体 20 MiB、单边 8192 像素、32 帧、累计
  4000 万像素上限，超时钳在 1…120 秒。
- **链接策略与打开者分离**：`markdownLinkPolicy(_:handler:)`。`MarkdownLinkPolicy`
  是纯 `Sendable` 判定，`MarkdownLinkHandler` 是 `@MainActor` 打开动作；非 web
  scheme 需要两者同时放行。
- **资源失败诊断**：`onMarkdownResourceError(_:)` 交出 `MarkdownResourceFailure`
  ——类别 + `SanitizedMarkdownOrigin`（scheme/host/port，永不含 path 与 query）。
- **两个复制命令**：`renderedSelectionResult()` 给屏幕上的内容，
  `markdownSourceSelectionResult()` 给选区覆盖的源码，后者带
  `MarkdownCopyGranularity` 说明保真度。
- **语义无障碍树**：`AccessibilityTree` / `AccessibilityNode`，以及平台视图上按
  文档顺序、各有真实布局框的元素。
- **Dynamic Type**：`MarkdownContentSizeCategory`、`MarkdownScaledFont`、
  `RenderStyle.pinFont(for:)` / `setFont(_:for:)`；`RenderStyle.default` 现在跟随
  读者字号，标题至少保留其声明比例的平方根。
- **不可变渲染边界**：`RenderConfigurationSnapshot`、`MarkdownConfigurationID`、
  按 session 拥有的资源租约。

### Changed
- 平台下限从 iOS 26 / macOS 26 **下调**到 iOS 18 / macOS 15。
- **⌘C 的结果变了**：过去给 Markdown 源码，现在给屏幕上的内容；旧行为改由
  「Copy Markdown Source」提供。
- `mathRenderer(_:)` / `svgRenderer(_:)` 改收
  `MathRendererConfiguration` / `SVGRendererConfiguration`。
- `MathJaxRenderer` / `SwiftDrawSVGBlockRenderer` 由 `@unchecked Sendable` class
  改为 actor。
- `RenderStyle` 不再是 `@unchecked Sendable`；跨 actor 传递改用快照。
- `MarkdownRenderConfiguration.default` 的语义 ID 字符串变了（新增字号档位与
  spacing 字段），以它为键持久化的内容在升级后失效。

### Removed
- `AttributedStringRenderer` 及其可变缓存（`imageCache` / `mathCache` /
  `svgBlockCache` / `mathRasterScale` / `svgRasterScale` / `*RendererGeneration`）。
  没有公开替代品直接交出 `NSAttributedString`——渲染需要主 actor、已解析资源集
  与其租约，旧 API 允许在资源释放后继续持有字符串。
- `MathLoadCoordinator.shared` / `SVGBlockLoadCoordinator.shared` 及其全部公开
  方法：进程级可变缓存不再对宿主开放。
- `MathRenderedGlyph` / `SVGBlockGlyph`（裸 `PlatformImage`）、
  `MarkdownSourceHighlighter`、`SyntaxHighlighter.highlight(…)`、
  `DocumentParser.parsedBlocks` 的公开可见性。

## [0.1.2](https://github.com/wxlpp/MarkdownKit/releases/tag/v0.1.2)
### Changed
- `swift-markdown` 依赖从 `from: "0.8.0"` 收紧为 `.upToNextMinor(from: "0.8.0")`。
  理由与 0.1.1 的 SwiftDraw 同源：`from:` 对 0.x 等价 upToNextMajor，会静默吃下未来
  每一个 0.x minor。
### Fixed
- `SVGRasterizer` 的「硬约束 1」注释已过期并被更正：SwiftDraw 自 `0.29.0` 起**支持**
  `ex` 单位（新增 `.em` / `.ex`）。`normalizeUnits` 仍然必须做，但理由从「不归一化就
  解析失败」变成「不归一化就静默渲出错误尺寸」——SwiftDraw 按 1ex = 1pt 解析，与
  MathJax 的字体相对 x-height 不等。**这是从显式失败退化成静默错误，更难发现。**
- README 的安装示例从 `branch: "main"` 改为版本引用（v0.1.1 的全部意义就是能被按版本
  引用，门面文档却还教人用 branch）；删掉指向不存在 workflow 的失效 CI badge。

### ⚠️ 已知但未修（需要各自的测试才能动）
- **解析期取消会被记成永久失败**：SwiftDraw `0.29.0` 在 XML 解析循环里加了
  `try Task.checkCancellation()`。`SVG(data:)` 是 `init?` + `try?`，所以**取消会变成
  nil** → 在本包里映射成 `.parseFailed` → `.failed` → 进 `MathLoadCoordinator` /
  `SVGBlockLoadCoordinator` 的 **negative 缓存**，而 `loadIfNeeded` 见到 negative 就
  永不重试。今天不触发，只因为两个 coordinator 的 `Task {}` 从不 `.cancel()`；一旦
  按 `MathJaxRenderer` 注释里写的计划做细粒度取消，这就是个真 bug。修它需要「cancelled
  不得进 negative cache」的断言，不在本次范围。

## [0.1.1](https://github.com/wxlpp/MarkdownKit/releases/tag/v0.1.1)
### Changed
- **SwiftDraw 依赖从裸 revision pin 改为版本区间 `.upToNextMinor(from: "0.29.0")`。**
  这不是清理，是修 bug：**只要本包含有 revision 依赖，它自己就永远无法被下游按版本引用**
  —— SwiftPM 直接拒绝解析（`package 'markdownkit' is required using a stable-version but
  'markdownkit' depends on an unstable-version package 'swiftdraw'`）。`v0.1.0` 打了 tag
  却没人试过用它，所以这个缺陷是发布之后才暴露的。原 pin 的 commit `4d09d03` 是
  `0.29.0` 的祖先（后者领先 16 个 commit、behind_by=0），换区间不丢任何东西。
- 验证：`swift build`、`swift test`（218 tests / 47 suites）、以及
  `xcodebuild -destination 'generic/platform=iOS Simulator'` 对 `MarkdownKit` 与
  `MarkdownMath` 两个 scheme —— iOS 腿是 `v0.1.0` 漏跑的。

## [0.1.0](https://github.com/wxlpp/MarkdownKit/releases/tag/v0.1.0)

首个 tag。此前 110 个 commit 全在 `main` 上，下游无法按版本引用。

⚠️ **这个版本不能被当作版本化依赖使用**（见 0.1.1）；需要 `revision:` pin 才能消费。

### Added
- `MarkdownCore` —— 经 swift-markdown 解析出的类型化 block 树（IR），无 UI、无渲染。
- `MarkdownRenderKit` —— block 树 → `AttributedString` / 布局片段，平台无关。
- `MarkdownPlatformView` —— 建在 TextKit 2 上的 UIKit / AppKit 视图，处理文本选择与流式更新。
- `MarkdownKit` —— SwiftUI 层，多数消费方 import 这个。
- `MarkdownMath` —— `MathRendering` 协议的 MathJax + SwiftDraw 实现。
