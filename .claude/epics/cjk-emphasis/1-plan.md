# CJK 强调解析实施计划

## 最新集成证据（2026-10-23 交付核对）

- 已验证源码 revision：411fae3806ec6d08a9350192f97faee15c11bc63。之后本次仅整理计划状态，不改生产代码、测试或依赖。
- 当前源码 iOS18 完整 package + Example 清单断言：552 executed / 552 passed / 0 skipped / 0 failed；必需 target/case 齐全。日志、xcresult、git SHA 和环境记录在 `.artifacts/ios18-final-head/`。
- 当前源码 macOS26 宿主完整测试541项通过；Release warnings-as-errors、格式、图片所有权与链接隔离门禁通过，见 `.artifacts/claude-review/final-macos-tests.log`、`.artifacts/final-head-static/`。这些不代替 macOS15 实际运行。
- macOS15 环境不可用；用户已确认库 PR 保持草稿、继续 App 验证。Markdown 正式版本发布与合并均延期，下面相关交付项仍不打勾。
- 公共 fork 标签已核对：cmark 0.9.1=17ad3e9b113f7747a5822ac00bc0efca2c15e628；Swift桥接0.8.1=92f5d9cad5e048a04dd3f4d306348836dbe89eae。标签未覆盖。
- 独立稳定版本消费者及同 identity 冲突负例证据保留在 `.artifacts/cjk-consumer/`，仅本地测试标签99.0.0未对外发布；App 实际消费411fae3/Harness154a08b并完成签名Release构建和真机安装。
- Claude Opus5.5配置隔离修复复核PASS，完整报告 `docs/reviews/2026-10-23-claude-cjk.md`，PR #15 已同步原文与处置。App PR #270 的后续键盘修复另有定向报告，不能借本库PASS替代其评审。
- 下方勾选代表实现/指定证据完成，不代表整个发布门禁或所有库已合并。后文按时间追加的旧状态仅为历史。

> **For agentic workers:** REQUIRED SUB-SKILL: Use oh-my-superpowers:executing-plans to implement this plan task-by-task.

**目标：** 按 spec 为 App 聊天提供可选择的解析器层 CJK 强调，不改写原文。
**架构：** swift-cmark option → swift-markdown ParseOptions → MarkdownCore 解析配置 → 渲染会话 → App 聊天。

## 1. 底层规则与可再现输入

- [x] 从当前冻结上游 revision 建立独立维护 checkout，记录来源、许可证、版本；不修改 SourcePackages。
- [x] 下载并固定社区用例及 Unicode 数据，生成区间表脚本，明确数据版本及许可。
- [x] 用 cmark 测试展示严格模式原输出及目标 CJK 差异（红）。
- [x] 在 `src/inlines.c` 加 option 控制的 flanking 分类辅助函数；在 `src/cmark-gfm.h` 分配无冲突 option bit，Unicode 分类单独文件。保留原匹配算法。
- [x] 严格模式跑上游规范测试；开启模式跑社区强调用例和畸形 UTF8/超长 delimiter 边界。记录结果并提交。

## 2. Swift 桥接

- [x] swift-markdown `ParseOptions.swift` 新增 `cjkFriendlyEmphasis`，`CommonMarkConverter.swift` 映射底层 option。
- [x] 增加强调树和 source range 测试；关闭选项输出不变。
- [x] 跑 Swift 桥接测试，提交维护分支。版本依赖发布前使用本地受控联调，仅在最终交付时锁稳定版本。

## 3. Markdown 库端到端传播

- [x] 先定位 DocumentParser、IncrementalParseState、ParseExecutor、渲染会话及 SwiftUI 配置的真实签名，列出完整 option 流向后修改。
- [x] 新增 Sendable/Equatable 解析配置，默认严格；document 保留配置，所有 parsePipeline/plain/math tail 使用它。
- [x] 选项改变时失效旧解析任务/缓存，不沿用旧增量边界；SwiftUI/UIKit 配置保持一致。
- [x] 对每个 UTF8 合法切分点验证增量==全量；数学、链接、复制、选区及 source range 回归。
- [ ] 更新运行时清单与说明，跑必需平台门禁及完整库测试。清单、iOS18和当前宿主已完成；macOS15实际运行延期。

## 4. 发布与 App 消费

- [x] 审查最小 fork diff，发布可稳定解析的语义版本；库依赖切到冻结版本后验证独立消费 fixture。
- [x] App 聊天显式开启 CJK，统一 Xcode、StoryUI 和 resolved 冻结版本。
- [x] 真实 App 展示截图句子与流式输出，验证源码复制、引用点击及选择；记录未覆盖范围。
- [x] Claude Code 对最终跨库 diff 评审，处理真实问题并将评审模型、SHA、验证和处置同步 PR。

## 未完成的其他整改

本计划不关闭网页/选区剩余边界、并行测试同步问题、App 固定依赖及整体验收；继续在 App 的 parser-and-contracts 总账追踪。

## 实施准备证据（2026-10-23）

- 独立 checkout：`/Users/evan/Repositories/work-spec/swift-cmark-cjk`，分支 `feat/cjk-emphasis`，基线 `08ddb528923cc1a6527e02b7a1aee9e516ca749a`。仅从现有冻结缓存复制 Git 仓库，缓存本身未修改；upstream 指向 swiftlang/swift-cmark，尚未创建远端 fork 或发布版本。
- `swift build --product cmark-gfm-bin` 通过。
- `python3 test/spec_tests.py --program .build/debug/cmark-gfm-bin --spec test/spec.txt`：670 passed，0 failed/errored/skipped。日志 `/tmp/cmark-baseline-spec.log`。
- 原截图句子直接输入 cmark CLI，输出仍含字面量 `**`，确认严格模式基线。尚无 CJK 生产实现。
- CJK 设计独立评审仍在进行；此准备不代表设计已 PASS。

## 评审后具体实施约束

- [x] 依 spec 修订的 API 签名执行，不再把 API 设计推迟到写代码阶段。新增 `Sources/MarkdownCore/MarkdownParseOptions.swift`，在 DocumentParser/IncrementalParseState 中传播；RenderSessionTypes/ParseExecutor/MarkdownRenderSession 中建立 submission 配置隔离；MarkdownLabelView+iOS/+macOS 和 OhMyMarkdown 的环境 modifier、两个 representable 接入。
- [x] 新增配置切换矩阵：strict→CJK / CJK→strict，静态同 source、append、active、queued、retry、取消恢复；底层 parse 直接传错误 previous 也必须从0开始。文档模式验证 changing options 不隐式重新解释 AST，后续 setMarkdown 才采用新规则。
- [x] 将 Unicode 输入清单补全，校验 manifest 后生成；测试生成区间分类与参考数据一致，不能只测原截图。
- [x] fork base SHA 和允许文件按 spec 表格校验。fork URL 未存在时创建；cmark 0.9.1 / Swift 桥接 0.8.1 tag 占用时停止该发布步骤并更新版本设计，绝不覆盖 tag。
- [ ] 每一级先构建验证再 tag；Swift 桥接精确依赖 cmark `0.9.1`，Markdown 库精确依赖 Swift 桥接 `0.8.1`。最后用本地临时 bare Git remote 的 version-tag consumer fixture 证明稳定版本解析，再发布真实库版本，避免仅在 path override 下成功。
- [x] 干净缓存 fixture：单独版本消费 Markdown 库成功；App 完整依赖图成功；加入官方同 identity URL 的负例被明确拒绝。脚本断言所有 resolved 的 identity/URL/version/revision，禁止 branch/revision/path 依赖进入稳定库 manifest。
- [x] 维护文档记录上游安全修复更新步骤及退回官方的迁移要求；最终 PR 明示 fork 互斥兼容限制。

## 设计评审状态

首次独立评审 BLOCK：依赖拓扑、配置失效、API、Unicode数据和发布验收不够具体。以上修订与 spec 对应章节逐项补齐，待同一评审者定向复核；未宣称 PASS。

### 第二轮设计评审处置

- cmark 08ddb528 是上游 0.9.0，首个维护版本更正为 0.9.1；Swift 桥接仍为基于 0.8.0 的 0.8.1。库旧 resolved 为 cmark 0.8.0；基线升级差异只含 src/html.c 两处相同 UTF8 字节的字面量转换。增加脚注 HTML 与 AST/source-range 兼容验证，不将前述 670 项错误记作 0.8.0 证据。
- 空白表生成改为 GC=Zs 加 TAB/LF/FF/CR。PropList 不用于生成该表；增加 VT/NEL/Zl/Zp 负例。
- Exports.swift 增加显式公共 typealias，consumer fixture 只 import OhMyMarkdown，显式声明 MarkdownParseOptions 并调用 modifier。


## 实施 checkpoint（2026-10-23）

- cmark 102ac97c + 17ad3e9b：显式选项和生成 Unicode 分类已实现；严格规范670、API815、社区golden5份、25项明确语义以及长delimiter通过。第一轮代码评审REVISE的生成门禁/覆盖问题已修，定向复核已 PASS。尚未发布。
- Swift 桥接92f5d9c：明确选项桥接、严格模式与源范围验证；完整XCTest301通过。当前用临时bare Git精确版本fixture联调，未冒充公共远端发布。
- MarkdownCore第一段：同步/plain/math解析统一options；document/equality/append保留配置；incremental本层拒绝不一致previous，从0重解析。新增3项测试（包含3组scalar分段输入），与增量现有专项共33项通过。会话submission/active/pending/retry以及SwiftUI/UIKit/AppKit传播尚未实现，不是端到端完成。
- 临时fixture必须保留原identity（swift-cmark.git、swift-markdown.git），不能将实验目录名写入最终resolved。正在更新并检查；最终公共依赖发布前还有干净缓存完整图门禁。

### 会话与 UI 配置 checkpoint

- ParseSubmission 捕获解析配置，ParseExecutor 使用捕获值；会话规则切换失效旧解析/渲染缓存，异步结果与重试必须匹配当前配置。
- UIKit/AppKit 暴露 parseOptions 与 setDocument；文档 AST 保持权威，后续源码输入才使用调用者新规则。
- SwiftUI 静态/流式统一 markdownParseOptions 环境 modifier。配置在 source 相等早退前转发；幂等比较由平台属性负责，避免 coordinator 重复持有同一状态。流式 listener 注册前先安装配置。
- 会话专项39项通过；完整 macOS 测试539项通过（/tmp/cjk-markdown-full.log）。随后增加取消/恢复专项并格式化，CJK UI与会话5项通过（/tmp/cjk-ui-checkpoint.log，包含静态/流式及双向参数）。全量539不包含最后新增的取消恢复一项。
- 尚未通过 iOS18/macOS15 发布门禁；尚未发布 fork、接 App、最终 Claude 评审或安装。此次为执行阶段 checkpoint。

### 选择边界与发布环境续查

- 新增 lineEndBlankHitResolvesToInsertionBoundary：行首外侧命中起点、行尾空白命中文档插入终点。iOS26.4选择专项16项通过（/tmp/selection-line-end.log），未复现需要改生产逻辑的问题。
- 已创建 iOS18.0 的 iPhone16Pro，环境门禁通过，正在执行旧系统完整包测试。
- 当前宿主macOS26.3.1；GitHub仓库actions/runners返回空列表，macOS15门禁目前无可执行runner，不能用当前macOS全量替代。仍有其他独立工作可推进。

### 阶段评审 BLOCK 处置

- 评审发现 setDocument 后 append 会清空权威AST。先扩展平台共用回归，真实红灯显示原文档被替换成追加片段（/tmp/cjk-document-append-red.log）。
- session 的 append 在 suppliedDocument 存在时不修改来源或退出模式，仍按当前commit发布权威文档；setSource才清除document。setDocument明确恢复static占位模式。
- 修复后CJK会话/SwiftUI与既有渲染会话共17项通过（/tmp/cjk-document-append-green.log）。等待同一评审者定向复核。
- 静态门禁的格式、540测试、Release warnings-as-errors均通过；总体失败项是platform-floors内Example解析尚未发布fork，非floor数值错误，需真实发布后重跑该项。

### 公开模式复核处置与真实版本

- 定向复审REVISE指出facade.renderMode仍切到streaming。新增断言复现红灯（/tmp/cjk-document-mode-red.log）；两平台记录当前document/source输入模式，文档append仍发送推进token但不改变公开模式。setMarkdown退出document后append正常streaming。
- 10项CJK会话、环境和公开模式测试通过（/tmp/cjk-document-mode-green.log）。
- 已建立wxlpp/swift-cmark与wxlpp/swift-markdown fork，推送feat/cjk-emphasis。检查标签不存在后发布0.9.1=17ad3e9b、0.8.1=92f5d9c，未覆盖标签。
- 移除本地临时mirror到忽略的.artifacts/cjk-temporary-mirrors.json；独立scratch/cache从GitHub解析成功，resolved URL/version/revision逐项断言通过。日志.artifacts/public-resolution.log。Example真实依赖测试仍在执行；尚未宣称整个App依赖图或稳定Markdown消费fixture通过。
