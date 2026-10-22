# 文本选择协议整改

## 范围

本次补齐视觉方向导航、组合字符扩选、RTL 选区方向与逻辑偏移越界语义。保留之前的渲染行命中定位及引用命中策略。

- 视觉移动交给 NSTextSelectionNavigation，不再将上下方向与左右方向都换算为 UTF-16 加减。
- 逻辑 offset API 继续使用 UTF-16，但越界返回 nil；加法检测溢出。
- 选区方向来自 TextKit 数据源；点击字符范围使用完整组合字符。

## 验证

- `/tmp/selection-contract-red.log`：7 项测试中的新增两项暴露 7 个预期失败（emoji、重音、上下移动）。
- `/tmp/selection-direction-red.log`：RTL 视觉边界与越界位置共 4 个预期失败。
- `/tmp/selection-direction-green.log`：26 项选区与链接测试通过。
- `/tmp/selection-contract-full.log`：iOS 26.4 模拟器运行成功；30 项与 501 项，共 531 项测试通过。
- 已补入 iOS 18 runtime manifest。尚未运行 iOS 18 门禁、未完成外部评审，未更新 App 固定 revision 或安装。

官方 API 已经 Context7 与当前 Xcode SDK 头文件核实。该记录只覆盖本次增量，不能作为其余跨库整改完成证明。

## Claude 反馈复现：混排扩展

- M1 已复现：英文 / 阿拉伯文交界在 4 个方向边界上，扩展一个字符却选中 4 个字符。红灯证据 `/tmp/selection-mixed-red.log`。
- 改用 NSTextSelectionNavigation 的 `extending: true`，由排版引擎给出选区，避免对两个视觉插入点做逻辑 min/max 后跨越整个 run。
- iOS 26.4 的 MarkdownTextSelectionTests 共 11 项通过（`/tmp/selection-mixed-green.log`），包括组合字符、上下移动、引用命中和新增混排测试。
- M3 的普通中文左右半区命中未复现：首尾字形两侧均命中正确字符。该证据仅覆盖普通中文，尚不能排除连字、RTL 或行尾空白问题。
- 新测试加入运行时清单。其余 Claude 反馈、完整运行时门禁与 App 最终固定版本仍待完成。

## 混排方向与布局枚举

- M2 / M6 已分别复现：LTR 段落内 Arabic run 的 rect 方向错误；段落起点 backward 查询错误地返回后一段方向（`/tmp/selection-direction-review-red.log`）。
- rect 方向改由 TextKit 提供的同一字符 leading/trailing caret x 顺序推导；每次请求按行缓存，避免自行猜测 Unicode bidi。枚举 segment 前只准备目标范围布局，收集后再查询 caret，不在回调里重复整篇 ensureLayout。
- backward 查询使用插入点之前的文本位置。
- M4 的文档首尾上下左右非空返回用例全部通过，当前未复现 nil，未加入推测性 fallback。
- 格式化后 iOS 26.4 的选择 suite 14 项通过（`/tmp/selection-edges.log`）；新增用例已登记运行时清单。
- 仍待：M3 RTL/连字及行尾验证、M5 连续上下移动目标 x、完整库与 App 回归、最终外部复审。
