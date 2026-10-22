# CJK 强调解析实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use oh-my-superpowers:executing-plans to implement this plan task-by-task.

**目标：** 按 spec 为 App 聊天提供可选择的解析器层 CJK 强调，不改写原文。
**架构：** swift-cmark option → swift-markdown ParseOptions → MarkdownCore 解析配置 → 渲染会话 → App 聊天。

## 1. 底层规则与可再现输入

- [ ] 从当前冻结上游 revision 建立独立维护 checkout，记录来源、许可证、版本；不修改 SourcePackages。
- [ ] 下载并固定社区用例及 Unicode 数据，生成区间表脚本，明确数据版本及许可。
- [ ] 用 cmark 测试展示严格模式原输出及目标 CJK 差异（红）。
- [ ] 在 `src/inlines.c` 加 option 控制的 flanking 分类辅助函数；在 `src/cmark-gfm.h` 分配无冲突 option bit，Unicode 分类单独文件。保留原匹配算法。
- [ ] 严格模式跑上游规范测试；开启模式跑社区强调用例和畸形 UTF8/超长 delimiter 边界。记录结果并提交。

## 2. Swift 桥接

- [ ] swift-markdown `ParseOptions.swift` 新增 `cjkFriendlyEmphasis`，`CommonMarkConverter.swift` 映射底层 option。
- [ ] 增加强调树和 source range 测试；关闭选项输出不变。
- [ ] 跑 Swift 桥接测试，提交维护分支。版本依赖发布前使用本地受控联调，仅在最终交付时锁稳定版本。

## 3. Markdown 库端到端传播

- [ ] 先定位 DocumentParser、IncrementalParseState、ParseExecutor、渲染会话及 SwiftUI 配置的真实签名，列出完整 option 流向后修改。
- [ ] 新增 Sendable/Equatable 解析配置，默认严格；document 保留配置，所有 parsePipeline/plain/math tail 使用它。
- [ ] 选项改变时失效旧解析任务/缓存，不沿用旧增量边界；SwiftUI/UIKit 配置保持一致。
- [ ] 对每个 UTF8 合法切分点验证增量==全量；数学、链接、复制、选区及 source range 回归。
- [ ] 更新运行时清单与说明，跑必需平台门禁及完整库测试。

## 4. 发布与 App 消费

- [ ] 审查最小 fork diff，发布可稳定解析的语义版本；库依赖切到冻结版本后验证独立消费 fixture。
- [ ] App 聊天显式开启 CJK，统一 Xcode、StoryUI 和 resolved 冻结版本。
- [ ] 真实 App 展示截图句子与流式输出，验证源码复制、引用点击及选择；记录未覆盖范围。
- [ ] Claude Code 对最终跨库 diff 评审，处理真实问题并将评审模型、SHA、验证和处置同步 PR。

## 未完成的其他整改

本计划不关闭网页/选区剩余边界、并行测试同步问题、App 固定依赖及整体验收；继续在 App 的 parser-and-contracts 总账追踪。
