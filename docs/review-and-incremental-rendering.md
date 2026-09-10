# Markdown 审阅与增量上屏

## SwiftUI 使用

```swift
import OhMyMarkdown

MarkdownSelectionReader { selection in
    MarkdownReviewText(
        chapterMarkdown,
        documentID: chapterID,
        revision: revisionID,
        annotations: annotations,
        commentActionTitle: "评论",
        isCommentingEnabled: canComment,
        copyActionTitle: "复制",
        copyMarkdownSourceActionTitle: "复制 Markdown 源码",
        onComment: { snapshot in
            // 原样保存 snapshot；不要从 quote 重建 renderedRange。
            presentComposer(snapshot)
        },
        onAnnotationTap: { annotationID in
            openThread(annotationID)
        }
    )
    .markdownStyle(readerStyle)
}
```

`MarkdownReviewText` 复用 `MarkdownText` 的渲染、主题、图片配置与真正系统选区。iOS 在系统选区菜单中追加评论动作；macOS 在选区上下文菜单追加评论动作。`isCommentingEnabled = false` 保留批注显示和点击，移除评论动作并拒绝已经打开菜单中的旧动作。批注更新只重绘，不触发解析或富文本物化。复制菜单文案可逐视图覆盖，默认 `nil` 延续已有系统/库文案，不修改进程全局设置。

同一视图对应一个不可变文档版本。`documentID` 与 `revision` 切换会创建独立平台视图；旧菜单动作同时检查当时的 snapshot identity，不能对新提交执行。独立章节分别创建视图即可，库没有提案、作品或评论线程业务依赖。

## 选区与不可定位状态

`MarkdownSelectionSnapshot` 可编码、可比较，包含：

- `documentID`、`revision`：宿主定义的文档及版本身份。
- `renderedRange`：当前渲染字符串的 UTF-16 `NSRange`，不是 Markdown 源码偏移。
- `quote`：该范围精确对应的渲染子串。粗体标记不包含在内；附件保留 U+FFFC；这与复制 API 生成的图片替代文本、表格 TSV 不同。
- `renderedContentID`：库计算的稳定、不透明坐标身份，必须随选区原样保存。

构造 `MarkdownAnnotation(id:selection:)` 后传回视图。定位时同时验证文档、版本、坐标身份、合法 Unicode 范围和引用内容。`renderedContentID` 的构造参数默认空值仅便于源码兼容；空值不会被接受为可定位批注。库不会猜测相同句子的位置，也不会把旧范围自动移到新版本。

资源回填可能把文字占位换成附件，使 UTF-16 坐标发生变化。此时旧批注保留为业务数据，但本次渲染不画线。宿主通过 `MarkdownSelectionProxy.annotationStatus(id:)` 查询 `.renderedContentChanged` 等状态，继续显示原引用并提示不可定位。状态包含 `located`、`rendering`、`documentMismatch`、`renderedContentChanged`、`invalidRange`、`quoteMismatch`；没有这个批注时返回 `nil`。

坐标身份按顶层块的 UTF-16 内容摘要组合：未变块重用 SHA-256 摘要，每份快照最多汇总一次固定长度摘要。启用审阅的视图在提交时预热；不使用审阅功能的视图不支付摘要成本。同一文档、同样的渲染内容与块边界重新打开会得到相同身份；字体与重排不改变文字时不会使批注失效。发生文本或块边界变化时保守拒绝旧坐标。

`annotationRect(id:)` 返回平台视图**本地坐标**中的矩形，不能直接当作屏幕坐标；无有效范围时返回 `nil`。重叠批注按传入数组顺序命中第一个。一个 `MarkdownSelectionReader` 只跟踪一个平台视图，多个章节应各自建立 reader。溢出表格有独立水平滚动/选区视图，本次不将其内部选区伪装成主文档范围；主文档可定位范围仍以实际占位字符串为准。

## 真正增量上屏的边界

准备层把可信基线模型身份与块替换范围传到主线程物化层。只有当前已安装快照对应这份基线，且配置、宽度和占位模式相同，才接受增量。准备结果被跳过、资源刷新或配置变化不会绕过既有 commit token 授权。

增量物化重用未变块的富文本对象：

- 流式尾部追加或替换，仅物化改变的尾部。
- 块数不变的中间替换保留前后缀；多物化一个后继块以处理块间换行与装饰段落间距。
- 未变代码块、引用等复杂前缀不会导致整份文档重建。代码与引用改变也走同一范围算法。
- 含图片、公式或 SVG 资源的文档暂时全量回退，保持已审计的资源租约事务。后缀块索引变化时也回退，避免复用错误的辅助功能索引。

平台视图明确使用 `NSTextStorage` backing，在 `NSTextContentStorage` 编辑事务内调用 `replaceCharacters(in:with:)`，同步编辑绘制镜像。选区映射使用原始内容变化范围，与为更新段落间距而扩大的富文本替换范围分开：未变前缀选区保留，未变后继与后缀选区平移，覆盖改变内容的选区清除。原有全量替换路径继续保留有效范围内的选区行为。

每份快照按块持有富文本和资源 owner，不引用整串历史快照。`RenderSnapshot.attributedString` 是兼容入口，调用时才组装全文；增量安装不调用它。新 owner 在事务内接管之后才安装，旧快照一直存活到 TextKit、绘制镜像与表格视图完成替换。物化失败保持旧内容和 owner。

`materializationWork` 记录新物化块数、复用块数、新物化 UTF-16 数量和回退原因（`initial`、`unprepared`、`missingDelta`、`baselineMismatch`、`configurationChanged`、`resources`、`shiftedSuffix`、`invalidRange`）。诊断不声称整条主线程路径常数复杂度：块元数据、摘要汇总、辅助功能布局及 TextKit 自身工作仍可能随文档增大。`setMarkdown` 表示新文档；公开增量入口仍是 `appendMarkdown` / `MarkdownStreamingText`。中间块 delta 能力由准备层提供，不新增带模糊源码坐标的公共编辑 API。

## 验证

新增测试先确认旧实现缺少对应API与增量能力，再验证真实平台行为：61块流式文档编辑时，观察 `NSTextStorageDelegate` 的字符变更范围位于尾部，确认 backing 实例保留、未组装快照全文、原选区保留，并与全量平台安装比较富文本。中间替换、代码/引用间距、基线失配、配置变化、资源坐标变化、过期动作、重叠批注与只读状态均有定向覆盖。

平台 API 根据 Apple 文档确认：[UITextInput 编辑菜单](https://developer.apple.com/documentation/uikit/uitextinput/editmenu(for:suggestedactions:))、[CryptoKit SHA256](https://developer.apple.com/documentation/cryptokit/sha256)。TextKit backing 的关联语义同时依据 Xcode 26.4 SDK 的 `NSTextContentManager.h` / `NSTextStorage.h` 核验。

### 本次验证记录（2026-09-10）

- `Scripts/Tests/delivery-gates-tests.sh`：通过。
- `Scripts/run-static-gates.sh .artifacts/review-static-final`：全部通过；529项测试 / 77组，125.6秒；Release 构建启用 warnings-as-errors；平台版本、图片 owner 审计、链接激活审计及 SwiftFormat 均通过。
- iOS 18.0 / iPhone 16 Pro：审阅、增量物化、平台事务25项通过；独立资源对抗14项通过，包含物化失败回滚、替换期间旧 backing 保留与回收。结果在 `.artifacts/review-ios18-transaction.xcresult` 和 `.artifacts/review-ios18-resource.xcresult`。
- iOS Simulator 通用构建通过（iOS 18 deployment target）。原生菜单文案、只读模式、重叠批注几何及代码/引用/溢出表格增量等价均在 iOS 18 运行验证。
- 本机 Xcode 26.4 / Swift 6.3 / macOS 26.3.1。最低 macOS 15 运行环境检查不满足；没有把本机测试充当 macOS 15 证据。尚未执行 Example iOS 18 的完整发布测试矩阵；本记录为本次库改动验证，不是完整版本发布声明。

首次完整静态运行发现两个问题后进行了修复和复跑：新增绘制代码需归入现有审计文件；普通渲染路径不应支付审阅摘要计算成本。后者在三种 1 MiB 生产 session 与1000次生命周期压力测试中定向复跑通过，再通过完整门禁。未修改测试时限或放宽审计清单。

### 独立终审修复验证（2026-09-10）

两项回归先在原实现上失败，再在修复后通过：macOS 使用真实 `NSMenuItem` 创建和派发动作，确认同一源 token 的资源回填后旧菜单不会发起评论，新菜单仍可使用；iOS/macOS 使用四块文档把中间普通段落改为代码块，确认被重物化以调整间距的未变后继选区保留并平移，改变内容内的选区清除。菜单项只保存创建时的选区值与快照 ID，不持有旧资源快照。

- macOS 定向运行 `MarkdownReviewTests`、`IncrementalMaterializationTests`、`MarkdownCopyTests`、`PlatformSessionWiringTests`：58项 / 4组通过。
- 同组测试在 iOS 18.0 / iPhone 16 Pro：57项 / 4组通过；结果为 `.artifacts/review-ios18-review-fixes.xcresult`。macOS 独有菜单测试不计入 iOS 数量。
- Release warnings-as-errors 构建、图片 owner 审计、链接激活审计、SwiftFormat 和 `git diff --check` 通过。本次修复未更改公共 API。

### 段落下方内联评论（2026-09-11）

`MarkdownReviewText` 新增 `inlineCommentHeights`（批注 ID 对应宿主评论卡高度）和 `onInlineCommentLayout`（返回本地坐标中的卡片矩形）。宿主在矩形处绘制自己的评论 UI；库为选区末尾所在段落增加间距，同段多条评论按 annotations 顺序排列，卡间留 12 点。无有效锚点或无高度时不插入空间。

此布局只修改 TextKit 段落属性，不向正文插入字符；复制、选区 UTF-16 偏移和 `renderedContentID` 不变。安装资源/内容快照前恢复原段落间距，随后重新验证锚点并应用间距。布局回调在主线程触发，SwiftUI 宿主应在后续主线程任务中同步几何状态，避免布局期间同步改状态。

- macOS `swift test --filter MarkdownReviewTests`：7 项通过，日志 `/tmp/markdown-inline-tests.log`。
- iOS 18.0 同组：7 项通过，结果 `/tmp/markdown-inline-ios-verified.xcresult`。
- 新增覆盖同段多评论不重叠、后续正文下移、移除恢复、复制/选区不变且不触发重物化。
- 聚焦代码评审指出并修复销毁后的旧布局范围及切换文档身份后的残留间距；对应回归加入同组测试。修复后 macOS 7 项通过（`/tmp/markdown-inline-fixed-final.log`）、iOS 18.0 7 项通过（`/tmp/markdown-inline-ios-final.xcresult`），聚焦复审 PASS。
