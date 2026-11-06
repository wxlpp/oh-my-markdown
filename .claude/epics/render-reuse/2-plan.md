# 实施计划：Markdown 首帧复用

> 采用 executing-plans；本计划实施者自行执行，评审独立。设计依据 1-spec.md。

## 1. 缓存与平台恢复

1. 在 Tests/OhMyMarkdownTests 新增 RenderReuseTests：真实LabelView完成渲染→缓存→dismantle→新view立即restore/measure的失败用例；覆盖stale source拒绝、配置变化、资源跳过和恢复后append。
2. Sources/MarkdownRenderKit/MarkdownRenderCache.swift 实现有界MainActor LRU，模型值与规范化配置键；缓存不拥有平台资源/视图，纯缓存行为测试覆盖容量/清空。
3. iOS/macOS MarkdownLabelView 各补 package preserve/restore 方法：registry gate确认当前提交；cache恢复初始snapshot仅在currentSnapshot为空执行；沿用RenderMaterializer和既有replaceSnapshot，不改变异步driver/token协议。
4. 定向运行缓存、session、资源与选择测试，保证旧session不能越界；保留失败与通过证据。

## 2. SwiftUI 生命周期接入

1. 新增环境modifier markdownRenderCache；两个representable Coordinator跟踪cache，dismantle前取当前原文并缓存，再正常dismantle。
2. sizeThatFits 在原有测量前尝试恢复，updateUIView先应用当前配置；macOS测量同步覆盖。
3. 新增SwiftUI拆装首帧用例（不仅仅测platform方法），检查当前trait/解析选项不误命中。
4. 静态门槛及当前可用OS上的相关包测试；标明iOS18/macOS15运行门槛未覆盖。提交并Claude定向代码评审。

## 3. App 消费与真机

1. 推送已审阅库提交，不自动合并；App工程、StoryUI Package.swift、Package.resolved固定同一SHA，不使用本机路径或修改SPM缓存。
2. ChatListController持有每列表cache，在hosting环境注入；内存告警清理。其余全局bar和交互不动。
3. App增加真实Markdown子视图/首帧内容验证；8项底层回归、长短父子收展、流式/选区、键盘旋转按影响运行。
4. 录完整交互，抽原始帧对比旧52.915s正文空帧证据；必须正文与操作栏同时到位。出现反例则不得交付为已修复。
5. format/diff检查、Debug/Release及签名真机构建；Claude复核集成差异与关键帧；覆盖安装并核实启动，保留用户数据。报告证据边界，不宣称发布门槛全过。
