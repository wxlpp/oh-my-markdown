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

## 设计评审修订：交付与 API 合约（优先于前述概述）

### 唯一依赖路线

fork 是官方包的互斥替代品，不支持同一依赖图中与官方实现并存。保持 package/module/C symbol identity，避免维护两套重命名符号。

| 层 | URL / identity | 基线 | 首个维护版本及要求 |
|---|---|---|---|
| cmark | https://github.com/wxlpp/swift-cmark.git / swift-cmark | 08ddb528923cc1a6527e02b7a1aee9e516ca749a（上游 0.9.0） | 0.9.1，精确版本 |
| Swift 桥接 | https://github.com/wxlpp/swift-markdown.git / swift-markdown | 3c6f9523da3a1ec2fd829673e472d95b8097a3b8 | 0.8.1，精确依赖上述 cmark |
| oh-my-markdown | 现有仓库 | 本次修复分支 | 精确依赖上述 Swift 桥接 0.8.1 |

这些 fork/tag 尚未发布；创建前再次检查 URL/tag 占用，若冲突则更新本设计，不能覆盖现有 tag。发布顺序 cmark → Swift 桥接 → Markdown 库 → App。门禁拒绝任何相同 identity 指向其他 URL 的 resolved 条目。兼容文档明确此互斥限制，不能声称适用于任意第三方依赖图。

保留上游许可证和 base SHA。允许 fork 修改：cmark 的 inlines.c、option 头文件、独立 Unicode 分类辅助文件/生成器/冻结数据、CLI 测试选项、测试和维护说明；Swift 桥接仅 Package.swift、ParseOptions、CommonMarkConverter 和相应用例/维护说明。其他文件修改必须说明必要性。后续跟进上游安全更新，重跑严格模式与扩展测试；上游支持并发布等价选项后，通过下一次明确版本迁移退回官方 URL，不自动切换。

当前 Markdown 库 resolved 的 cmark 为 0.8.0（924936d0427cb25a61169739a7660230bffa6ea6），App 冻结 checkout 为 0.9.0；本次明确统一到 0.9.0 基线并发布 0.9.1，不将其标作 0.8.x。两基线 diff 只有 src/html.c 的两处脚注返回箭头从 UTF8 字面量改成同字节 hex escape；仍需严格 CommonMark、GFM 脚注输出以及库 AST/source-range 回归验证升级兼容。此前 670 项结果仅是 0.9.0 基线，不能标为 0.8.0 基线验证。

### API 与数据流

- umbrella `OhMyMarkdown/Exports.swift` 显式 `public typealias MarkdownParseOptions = MarkdownCore.MarkdownParseOptions`；增加只 import OhMyMarkdown 的消费者编译验证。
- `public struct MarkdownParseOptions: OptionSet, Sendable, Hashable`；`rawValue: UInt`，`.cjkFriendlyEmphasis`；默认 `[]`。
- `MarkdownDocument.init(parsing: String, options: MarkdownParseOptions = [])`；`public let parseOptions`；equality 比较配置和 blocks。内部由 blocks 构造的 initializer 也显式接收配置。`parsingAppend` 使用原 document 的配置。
- `IncrementalParseState.parseOptions`、`IncrementalParseResult.document.parseOptions` 一致；`IncrementalSourceBuffer.parse(options:previous:metrics:afterCmark:)` 自身验证配置，失配以 `FullParseReason.configurationChanged` 从 byte 0 全量解析，不依赖 UI 清缓存。
- `parsePipeline`、`parsePlainTail`、`parseMathTail` 都接受同一不可变 options；所有 swift-markdown 入口由单一映射函数构造 ParseOptions。
- `ParseSubmission.parseOptions` 参与 Hashable identity，`ParseJob.parseOptions` 读取 submission；active/pending/retry 不能被新的配置误认领。结果提交时除了 commit/session token，还检查当前 options。
- 平台 `MarkdownLabelView.parseOptions: MarkdownParseOptions`（UIKit/AppKit 同名同义，默认 []）。源模式下改变 options 触发新 generation，取消 pending/retry、使 active 结果失效、清空 latestParse/previousModel/parse cache，并按当前完整 source 重解析；不是普通样式重绘。
- `setDocument` 渲染已解析文档：仅渲染该文档时采用 document.parseOptions，文档是权威事实；不改写调用方配置的 view.parseOptions。因无原文，之后改变 view.parseOptions 只设置下一次 setMarkdown 的规则，不重解释现有 AST；文档模式不得保留旧 source 用来意外覆盖该文档。下一次 setMarkdown 才退出文档模式，并使用调用方保留的配置。
- SwiftUI 使用 `.markdownParseOptions(_:)` 环境 modifier，静态 MarkdownText 与 MarkdownStreamingText 都消费它。coordinator 同时比较 source/source identity 与 options，source 相同但 options 改变也触发重解析。流式 source 本身只负责文本，不保存全局解析配置。
- App 在聊天 Markdown 根部应用 `.markdownParseOptions(.cjkFriendlyEmphasis)`，其他消费者默认 strict。

### Unicode 输入与明确范围

冻结 Unicode 18.0.0。输入包括 EastAsianWidth、Scripts、Blocks、UnicodeData、PropList（仅用于交叉校验）、StandardizedVariants、emoji-data、emoji-variation-sequences、emoji-sequences 和 emoji-test；全部保存 URL、SHA256、许可证。生成器输出 CJK、P/S 标点、Unicode 空白和 fullwidth ambiguous punctuation sequence 表，扩展模式不混用旧 cmark 标点数据；严格模式继续原逻辑。码点/VS 分类按固定提案，不把不同参考实现的不同版本混为同一规范。

CommonMark 空白分类精确等于 UnicodeData 的 General_Category=Zs 加 U+0009/U+000A/U+000C/U+000D；不得直接使用 PropList.White_Space。VT U+000B、NEL U+0085、Zl U+2028、Zp U+2029 必须有不属于空白的负例。

伪 emoji、FE00–FE0E、FE0F、IVS、non-BMP、未分配宽字符都进入分类测试。畸形 UTF8 使用现有 cmark validate 行为，新增分类函数不得越界读取。生成器与输入校验和进入仓库；生成结果必须可重现。

流式穷举集合是每个 Unicode scalar 边界对应的 UTF8 offset；另在 cmark byte feed 测试覆盖多字节字符中间切分。并非向 Swift String 传递无效片段。
