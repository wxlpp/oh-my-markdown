# CJK 强调解析扩展

## 目标与授权

属于用户已授权的「修复所有问题」整改：`改成**“确认这笔交易完成了”**，现金要找零。` 在聊天中正确显示强调；采用成熟规则，禁止以替换原文、插入不可见字符或渲染后正则修补达成。该项不能替代选区、网页、元数据及交付的其他未完成项。

## 事实

- 当前 oh-my-markdown 使用 swift-markdown 0.8.x，底层 swift-cmark；强调由 `inlines.c/scan_delims` 内置处理，星号和下划线早于普通扩展回调。
- swift-markdown 的 ParseOptions 尚未暴露 CJK 选项；转换器负责构造 cmark options。
- MarkdownDocument 的全量、普通尾窗、数学尾窗都调用 Markdown.Document；必须统一传递解析选项。
- 使用 tats-u/markdown-cjk-friendly 社区提案固定提交 `71d6b25d406a31d0303b102d582bd675067ed73f` 的强调章节与测试，不声称这是现行 CommonMark 标准。

## 决策

1. 在隔离的、可追溯的 swift-cmark 维护分支增加默认关闭的 CJK 强调 option，仅在 delimiter flanking 分类分支生效。沿用原匹配栈、嵌套、转义、代码、长度及源码位置逻辑。
2. swift-markdown 维护分支只增加 ParseOptions 到 cmark option 的映射和对应测试。两个维护分支保留原许可证和上游来源，不修改构建缓存。
3. 使用固定 Unicode 数据版本与自动生成的紧凑区间表；包括宽度 W/F/H、默认 emoji 排除、Hangul、变体选择符及标点序列。不能用汉字范围或引号白名单冒充规则。首先核对提案固定提交实际使用的数据版本及许可证，再冻结生成输入和校验和。
4. oh-my-markdown 默认严格解析；提供值类型解析选项，CJK 由聊天消费侧显式启用。选项进入文档、解析会话和任务身份；改变选项必须重新解析，不能复用旧规则的增量树或缓存。
5. 全量、增量、数学处理共用同一 option；CJK 不改字节内容，现有数学 source map 仍负责已有数学转换。原文复制、链接及 source range 不受 CJK 改写。
6. 仅涵盖强调和加粗（`*`、`_`）；删除线仍保持现有 GFM 规则，不能宣传整个 CJK 提案全部实现。
7. 维护分支使用语义版本依赖，确保 oh-my-markdown 可按稳定版本被下游引用。完成验证后发布带许可证的最小 fork 版本；不得将临时路径依赖或 revision-only 依赖带入库正式交付。

## 替代方案

- App 字符串替换：破坏转义、代码与 source range，拒绝。
- Swift AST 事后补 strong：需要重新实现 inline precedence 和嵌套，还会分裂全量与增量语义，拒绝。
- 整体更换解析器：影响表格、数学、源码范围和全部增量机制，当前没有证据支持这个代价。
- 普通 cmark extension：现有核心先消费强调符，不能实现目标。

## 验收

- 原截图句子、CJK 标点、Hangul、IVS、emoji、混合英文、转义、行内/围栏代码、嵌套、未闭合输入、链接和数学均有正反用例。
- 关闭 option：上游 CommonMark/GFM 测试保持原输出。开启 option：固定社区强调用例通过，差异逐项记录。
- 每个切分点的流式追加与一次性解析一致；取消/恢复、切换规则、源码 byte ranges、复制和选区回归。
- 下游稳定版本解析验证；Markdown iOS18/macOS15 仓库门禁；App 的真实冻结依赖构建、聊天渲染截图/交互验证。不能用 iOS26 的绿色结果替代平台门禁。
- 独立设计评审、实施后 Claude Code 评审、问题处置及 PR 留痕。未验证项保持开放，不以单个截图代替完整验收。
