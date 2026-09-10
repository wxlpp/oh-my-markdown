# Markdown 块布局与主题修复

## 复现与处理

来自 oh-my-story 真机截图：连续表格、代码、引用的装饰背景相交，末尾背景被视图裁切。真实 TextKit 回归测试先复现了相交和高度不足，再验证修复。

- 在顶层装饰块的首、末段落预留背景空间，块间换行保留前块的段落度量；不改复制字符串、源码范围或块起点。
- 视图测量包含末尾背景扩展高度；SVG 独立占位/资源布局契约保持原样。
- 从持久化 blockStorage 读取节点，不调用会展开整篇文档的公开 blocks 数组；不在每个块上复制累计字符串。
- 监听 iOS 外观/对比度与 macOS effectiveAppearance，在视图自身的外观环境里解析颜色配置并重绘。沿用现有渲染会话，不清空流式输入。
- 新增可选主题：默认 nil 跟随系统，支持 system/light/dark；静态与流式 SwiftUI 视图及原生视图均可配置。

## 回归基准

RenderGolden 原始迁移基准保留原来源标识。本次仅更新 7 组 iOS 和 7 组 macOS 装饰块基准的 NSParagraphStyle 与对应布局帧；程序比对确认字符串、标识、其他文本属性均未改变。旧的重叠间距不再作为正确结果。新测试独立约束装饰矩形不相交和视图高度容纳背景，避免只依赖更新后的快照。

## 消费方

oh-my-story 删除基于 colorScheme 的 `.id(...)` 重建兼容层，使用库默认主题。模拟器在同一页面 light → dark 切换后，表格、代码、引用无重叠且颜色正确。

## 验证结果

- macOS 当前主机：520 个测试全部通过，包含长文增量工作量约束；使用独立 scratch path 避免仓库从 MarkdownKit 更名后旧模块缓存路径失效。
- iOS 26.4 模拟器：15 个定向测试通过，覆盖布局、渲染快照，以及主题默认/固定/清除覆盖。
- SwiftFormat lint 通过；image-ownership、link-activation、平台最低版本检查通过。
- oh-my-story 移除 `.id(...)` 兼容层后构建成功；实际页面浅色切深色截图复查 PASS，背景不相交且没有末尾裁切。
- 此次未做 iOS 18.0 和 macOS 15 发布环境验证，不将当前主机结果代称最低版本发布门禁通过。
- 完整静态门禁通过：`SWIFT_BIN=/tmp/markdown-fresh-swift Scripts/run-static-gates.sh .artifacts/layout-fix-static-fresh`。该临时包装仅为 swift 命令指定干净的 `.artifacts/layout-fix-build` scratch path；未跳过测试，包含第二次 520 个测试通过、Release warnings-as-errors 构建和全库格式检查。
