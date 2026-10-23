# 评审结论：**REVISE**

审查范围只限你给的文本，没有运行任何工具。共发现 1 个需要修改的正确性问题，另有 2 条不阻断的建议。

## 需要修改

### 1. `setDocument` 会改写视图上长期有效的 `parseOptions`，导致下一次 `setMarkdown` 用错规则

**涉及文件**
- `Sources/MarkdownPlatformView/MarkdownLabelView+iOS.swift` 的 `setDocument(_:)`：`self.storedParseOptions = document.parseOptions`
- `Sources/MarkdownPlatformView/MarkdownLabelView+macOS.swift`：同一处
- `Sources/MarkdownPlatformView/MarkdownRenderSession.swift`，`.setDocument` 分支：`self.parseOptions = document.parseOptions`

**触发条件**（UIKit/AppKit 直接使用，例如 cell 复用）
1. 视图初始化时设置 `view.parseOptions = .cjkFriendlyEmphasis`。
2. 某条消息走 `view.setDocument(MarkdownDocument(parsing: text))`，这个文档用的是默认 `[]`。例如缓存命中，或调用方自己解析时漏传了选项。
3. 同一个视图复用后调用 `setMarkdown(next)`。

**结果**
- 第 3 步会按 strict 解析，CJK 强调悄悄失效。
- 反过来也一样：视图配置为 strict，加载一份 CJK 文档后，后续所有源码都会按 CJK 解析。
- SwiftUI 不受影响，因为每次 `updateUIView` 都会重新设置一遍；问题只出在命令式 API。所以两条平台路径的行为不一致。

**原因**
"文档 AST 是权威"只应该约束这份文档怎么渲染，不应该顺带改掉"下一份源码用什么规则"这个配置。会话里的 `effectiveParseOptions` 已经用 `suppliedDocument?.parseOptions` 管住了文档模式，所以这两处改写对渲染正确性没有任何作用，唯一的效果就是把配置泄漏到下一份内容。

**修复**
- 删掉上面两处赋值。`parseOptions` 的 getter 始终返回调用方配置的值。
- 如果需要知道当前渲染文档用的规则，读 `renderedDocument?.parseOptions`。
- `platformSameSourceAndDocumentAuthority` 里 `#expect(view.parseOptions == .cjkFriendlyEmphasis)` 这条断言要改成上面的语义。
- 设计稿里"采用 document.parseOptions"这句也要同步改为：只用于渲染该文档，不改写视图配置。

## 不阻断的建议

### a. 内部传参的默认值 `[]` 会让漏传在编译期不报错
- **位置：**
  - `parsePipeline` / `parsePlainTail` / `parseMathTail` 的 `options: = []`
  - `IncrementalSourceBuffer.parse(options: = [])`
  - `ParseSubmission.init(parseOptions: = [])`
- **风险：** 以后新增调用点时如果漏传，会静默退回 strict。
- **更糟的情况：** 如果某个生产路径用 `init(parsedBlocks:)`（默认 `[]`）重建了文档，`.parsed` 分支里的 `document.parseOptions == received.parseOptions` 校验会丢弃每一个 CJK 结果，表现为一直不出结果，最后超时报错。
- **现状：** 目前 diff 里能看到的生产调用点都正确传了参。
- **建议：** 去掉 package 级函数的默认值，只在测试辅助代码里提供默认。

### b. 全新的流式视图在还没有内容时就会提交一次空解析
- **位置：** `MarkdownStreamingText` 的 `makeUIView` / `makeNSView`
- **现象：** 先设置 `parseOptions`，此时既没有源码也没有文档，就会发出 `.replaceParseOptions`，产生一次空 commit 和一次空解析。
- **影响：** 最终状态是对的，只是多了一次提交。
- **建议：** 会话在"没有源码也没有文档"时，收到 `.replaceParseOptions` 只记下配置，不提交解析。

## 你关注的六点，确认没有问题

- **关闭选项仍是 strict：** `[]` 映射成 swift-markdown 的 `[]`，和改动前的默认参数一样，smart 仍然开启；cmark 的分支只在开启该标志时才生效；`before_char_pos = 0` 这个初始化不改变行为。
- **原文和 source range 不变：** 三个解析入口都传入了同一个 `options`；字节内容和数学 source map 的路径没有变化。
- **UIKit/AppKit/SwiftUI 传播：** 静态视图在 `updateUIView` 里先设置选项再设置源码，流式视图在 make 阶段就设置；两个平台的 setter 语义一致。
- **同一 source 换配置：**
  - 视图 setter 会发出 `.replaceParseOptions`，会话随即清空 `latestParse`、`incomingParse` 和 `previousModel`。
  - `IncrementalSourceBuffer.parse` 自己会检查 state 和 document 两份选项，失配就以 `configurationChanged` 从第 0 字节全量重解析，不依赖 UI 层清缓存。
- **文档 AST 权威：** 文档模式下 `.append` 会被忽略，`effectiveParseOptions` 取文档自己的选项。问题只有上面第 1 条。
- **异步结果的配置隔离：**
  - 涉及的路径：receive / incremental / prepare / diagnostics 之后 / preparationFailed / retry。
  - 每条路径除了检查 token，还会比对 `parseOptions`；`.parsed` 分支另外校验文档自身带的选项。
  - 选项参与 `ParseSubmission` 的 Hashable 身份，旧配置的结果不会被新配置误认领。

## 仅凭这段文本无法核实的部分

需要你另外确认：
- `cjk.h` / `cmark_cjk_flanking` 对 `_` 的规则，以及对 IVS 的分类。
- `CMARK_OPT_CJK_FRIENDLY_EMPHASIS` 的位值是否和已有的 cmark-gfm 选项冲突。
- MarkdownCore 里除这三处之外，还有没有别的 `Markdown.Document(parsing:)` 调用点，比如评审、注解或复制时的二次解析。

## 作者处置

- 实际模型claude-opus-5-5，high，standard，fast mode off，纯文本评审。输入为Markdown247e78d..57f16f4及底层fork差异，原始JSON保存在.artifacts/claude-review/cjk-result.json。
- 视图配置泄漏：新增双向文档/源码切换回归，红灯4处证明getter与后续源码均被污染。删除UIKit/AppKit与session的3处配置赋值；document仍通过effectiveParseOptions持有渲染权威。spec明确文档不改写未来源码配置。
- 修复后11项CJK会话/SwiftUI/公开模式测试通过，含参数化方向。日志.artifacts/claude-review/document-config-{red,green}.log。
- 内部默认参数与首次空解析目前没有错误路径证据，保留为非阻断建议；不为消除一次空初始化解析新增状态机。
- 底层Unicode分类、option bit及严格模式已有前一阶段专项和独立评审覆盖；本次报告未见头文件不等于这些项未验证。
# 复核结论：**PASS**

我只审了你贴的 `57f16f4..5145476` diff 和 session 片段。这次会话没有读文件或跑命令的工具，所以没有去仓库里核对上下文，也没有自己重跑测试。"11 项通过"是你报告的结果，我没有复现。

## 阻断问题是否已解决：是

**生产代码**
- 三处删除后，`parseOptions` 只剩一个来源。view 的 `storedParseOptions` 和 session 的 `parseOptions` 都只保存用户配置的值，文档自带的选项只通过 `suppliedDocument` 生效。
- `effectiveParseOptions = suppliedDocument?.parseOptions ?? parseOptions` 的效果是：有文档时用文档的选项，`setMarkdown` 清掉 `suppliedDocument` 后自动回到用户配置。不用再在 `setDocument` 里回写选项。
- 两个平台的 `setDocument` 改动一致，session 侧也同步改了。如果只改 view 层，session 里的值仍会被覆盖，配置等于没改，现在没有这个问题。

**新测试 `documentDoesNotReplaceSourceParsingConfiguration`**
- 文档的选项与配置故意取相反值，两个方向都跑。覆盖了上一轮指出的两处：
  1. getter：`#expect(view.parseOptions == configured)`。
  2. 后续渲染：`setMarkdown` 之后的输出必须符合配置值，不能跟着文档走。
- 去掉 session 那一行修改，`configuredCJK: true` 这一组就会失败；去掉 view 那一行，getter 断言会失败。所以测试确实测到了修改点。
- 用 commit token 变化来判断渲染已稳定是对的。两个方向的前后字符串本来就不同，按 token 判断能直接给出断言失败，不会卡到超时。

**原测试的调整**
- setter 改成写 `.cjkFriendlyEmphasis`，这样新值和当前 getter 返回的 `[]` 不同，确实会触发一次提交，`settled { token != ... }` 不会空等。
- `setMarkdown` 前补了 `view.parseOptions = []`，这一段的意图没变：在默认选项下按原文渲染。

## 不阻断的建议

1. **两个平台都要跑测试**：iOS 和 macOS 的实现都改了，请确认 11 项在两个平台上都通过。如果只跑了一个，PR 正文里写明是哪个。
2. **公开 API 的语义变了**：`setDocument` 之后，`parseOptions` getter 不再返回文档的选项。如果 `parseOptions` 的 doc comment 或 SwiftUI 包装层（`fa1df30`）里有"反映当前文档选项"之类的说法，或者有依赖这个旧行为的比较逻辑，请顺手核对一下。

iOS18同路径11项/3 suites通过，xcresult：.artifacts/cjk-final-ios/Options.xcresult。该专项覆盖本轮改动；前一版本完整iOS18结果仍仅代表其原revision。
