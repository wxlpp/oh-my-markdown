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
