# Change Log
All notable changes to this project will be documented in this file.
MarkdownKit adheres to [Semantic Versioning](http://semver.org/).

## [Main](https://github.com/wxlpp/MarkdownKit)
### Added

### Changed

### Removed

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
