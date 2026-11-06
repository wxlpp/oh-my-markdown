# 已完成 Markdown 正文的首帧复用

## 授权与问题

2026-11-06 作者同意一并修 Markdown 库，更新 App 依赖后真机验证；全局 AI chat bar 不动。App 的 native self-sizing 已解决行高/相邻行分时更新，但原始帧仍证明：离屏正文重新创建 MarkdownLabelView 后，异步解析完成前，正文高度为零而操作按钮已显示。外层 hosting view 缓存、prefetch、overscan 均无效，已经撤回。

## 方案

新增调用方显式持有的 `MarkdownRenderCache`，缓存 `RenderDisplayModel` 值，不保留 UIView、SwiftUI 状态、选择、actor、session token 或资源 lease。默认最多8条、原文 UTF-8 合计256KiB；超限不入缓存，LRU 淘汰；提供 removeAll。不开全局单例。App 在每个聊天列表控制器内拥有一份，关闭列表/内存警告即释放。

SwiftUI MarkdownText / MarkdownStreamingText 的 representable 在 dismantle 时才缓存当前已提交的模型，避免每个 token 重算全文缓存键。仅当 currentCommitToken 仍被本视图 registry 授权时缓存，防止把旧模型登记到新原文。streaming source 的当前原文在收尾时读取，不新增每次 append 的全文副本。

新视图首次 sizeThatFits 时，若尚无快照，查找匹配原文、parseOptions、有效宽度和已解析字体/颜色/间距/mathScale 的模型；忽略仅用于会话隔离的 configuration id/generation。命中后同步 materialize 一份新的 RenderSnapshot 并安装，后续仍由正常异步 session 接管。缓存快照使用本视图 session 的 sequence 0，不进入授权 registry；其后真实提交序号>=1。缓存命中不会被当成真实 actor 提交，不被再次缓存，不能产生资源加载或改写其他会话。

本轮只缓存 resourceValues 为空的模型（普通文字、列表、链接、代码、无异步资源的表格）。此时 static/streaming placeholderMode 对显示无影响，可跨模式恢复。带图片/公式/SVG的模型不缓存；它们原有加载和内存记账不变。缓存只节省已完成模型的重新解析，不把新原文解析搬到主线程。

SwiftUI 通过 `.markdownRenderCache(cache)` 显式接入；nil 为原行为。iOS/macOS 使用同一缓存契约，各自平台测量入口恢复。用户选择、链接策略、review 注释取当前视图配置，不从旧视图复制。

## 验收与边界

- 第一份真实异步渲染完成、拆除后，新视图在不 await 的首次测量中已有正文、正高度及相同可见文字。
- 原文/解析选项/宽度/主题/字号改变不误命中；未完成最新请求或已撤销token不污染缓存；资源模型不入缓存；LRU/容量/清空受测。
- 缓存恢复后继续append、替换、拆除，不接收旧会话迟到结果；后续合法提交保持当前选区契约。
- App 的父/子收展原始帧必须显示正文首帧可见，不能用外层view身份、终态断言、降采样概览代替。
- 复用已有8项布局回归；补正文首帧断言及带键盘/旋转、流式阅读和选择验证。Claude Code 独立评审后修复反馈。
- macOS15运行门槛按作者既有指示暂缓；记录实际运行OS，不宣称满足旧系统发布门槛。不自动合并。
