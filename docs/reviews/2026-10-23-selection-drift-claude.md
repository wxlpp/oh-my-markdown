# 静态文本选区漂移：Claude Code 定向评审

评审源码：4091d2cf7bcc48b49cd7420e7d72897ae8582b0f（生产源码与 App 冻结411fae3相同）。实际模型 claude-opus-5-5，high，standard，fast off。只读源码评审，未运行测试。原始结果保存在 .artifacts/claude-review/selection-drift-review-result.json。

## 用户补充与作者判断

评审运行期间用户明确：生成完成后也会漂移；选中区域后拖动右侧手柄，左侧起点会变化。此补充未包含在本轮输入中，因此不能把评审结论当作已解释该复现。优先验证报告S4（系统设置选区时再次通知inputDelegate）和端点几何/方向标记。D1最近插入点偏差可能独立存在，但不能单独解释固定起点变化。D2复杂度和性能需要测量；D3流式相交失效不是本次静态复现的充分原因。尚未修改生产代码或确认根因。

## 原始报告

# 文字选择与拖动评审（UITextInput）

**结论：** 旧测试只验证了"点到字符中心能命中这个字"，没有覆盖拖动手柄时最关键的几件事：手指离哪条字符边界最近、手指在行尾空白处、手指在行间或段间空隙、长文档的性能、以及流式更新中的选区。仅凭代码就能确认三处缺陷，另有几处高概率问题需要在设备上复现。

这次是只读评审，只依据你贴的源码，没有运行任何代码，也没有改文件。下面标"确认"的，是从代码逻辑能直接推出的；标"推测"的，必须先跑后面的复现步骤。

---

## 一、确认的缺陷

### D1【高】`closestPosition` 返回"手指下面那个字的起点"，而不是"离手指最近的光标边界"

- **位置：** `MarkdownTextInput+iOS.swift:432-434`、`:452-461`；测试 `MarkdownTextSelectionTests.swift:9-27`
- **原因：** `line.characterIndex(for:)` 返回的是点所在字形的字符下标，相当于向下取整。测试 `characterHitIncludesBothHalvesOfGlyph` 要求点在字宽 0.25 和 0.75 处，`characterRange(at:)` 都返回同一个字。`characterRange(at:)` 直接对 `closestPosition` 的结果取 `rangeOfComposedCharacterSequence`，所以这个测试能通过，就说明 `closestPosition` 在字的右半边也返回该字的起点。
- **问题：** UIKit 拖手柄时用的是 `closestPosition(to:)` 和 `closestPosition(to:within:)`，它需要的是"最近的插入点"。现在两个 API 共用一个向下取整的结果，等于把正确行为当成了测试要求的反面。
- **触发条件：** 拖结束手柄到某字的右半边，这个字不会被选进来，要越过它的右边缘才行。拖起始手柄到某字的右半边，这个字反而被选进来。中文字形宽 16–17pt，用户会感觉"总差一个字，手柄比手指慢半格"。从右往左书写的文字（如阿拉伯文）同样有偏差。
- **为什么旧测试没发现：** 现有的命中测试都打在字符矩形的 `midX`，断言范围是 `range.location ... NSMaxRange(range)`，取整方式对不对都能通过。
- **修复方向：** 两个 API 分开实现。`characterRange(at:)` 保留"手指下面的字"。`closestPosition` 改为在命中的行内用 `enumerateCaretOffsetsInLineFragment(at:)` 或 `locationForCharacter(at:)` 取各边界的 x，选离 `point.x` 最近的那个，这样从右往左的文字也自然正确。

### D2【高】拖动的每一帧都在主线程上做 O(n²) 的计算

- **位置：** `MarkdownTextInput+iOS.swift:414`、`:420-424`；`:385`、`:391-393`
- **原因：**
  - `closestPosition` 每次都要 `ensureLayout(documentRange)`，再从文档开头枚举布局片段，每个片段调用一次 `offsetOf`。
  - `selectionRects` 对每个片段枚举整行的光标位置，每个光标位置又调用一次 `offsetOf`。
  - 项目自己在 `MarkdownLabelView+iOS.swift:426-430` 写明：`offsetOf` 的耗时与偏移量成正比，400 段的文档实测 0.4 秒。
- **触发条件：** 长文档（典型是 LLM 长回答），在靠后的位置拖手柄。UIKit 每次手指移动都会调用 `closestPosition`、`selectionRects` 和 `caretRect`。
- **表现（推测，需要性能工具确认）：** 主线程卡顿，手柄跟不上手指，系统合并触摸事件后选区一跳一跳，用户会觉得是"漂移"。
- **修复方向：**
  - 先用 `layoutManager.textLayoutFragment(for: point)` 直接定位片段，不再从头遍历。
  - 偏移量用 `contentStorage.offset(from: elementRange.location, to:)` 算段内相对值，再加上一个缓存的段起点表（可复用 `blockStarts`，或每个快照建一次表）。
  - `ensureLayout` 只对视口和选区范围做。

### D3【中】流式或资源快照替换时，碰到变更区的选区会被直接清空，拖动中途也一样

- **位置：** `MarkdownLabelView.swift:55-63`；`MarkdownLabelView+iOS.swift:142`、`:150-164`
- **原因：** 只要选区和 `contentChangeRange` 有交集，就直接 `return`，选区清空。`replaceSnapshot` 在 `appendMarkdown` 的每一块、图片/数学公式/SVG 加载完成（`refreshResolvedResources`）时都会执行。
- **触发条件：** 流式输出时，在正在增长的最后一段里长按或拖选。每来一块内容，选区和手柄就消失一次。如果资源加载导致变更区覆盖选区所在的块，也会清空。
- **另一个推测问题：** 变更发生在选区之前（例如前面的图片占位文字换成单字符附件）时，选区按 `contentLengthDelta` 平移了。但 UIKit 手里拖动中的锚点只是一个整数偏移，`MarkdownTextPosition` 没有版本号，不会跟着平移。下一次手指移动时，锚点会按旧偏移落到错误的字上。

---

## 二、高概率推测（必须复现）

### S1【高】手指在"带换行的行"右侧空白处时，结果跳到下一段开头

- **位置：** `MarkdownTextInput+iOS.swift:434`
- **原因：** 夹紧上限是 `NSMaxRange(line.characterRange)`。段落最后一行的 `characterRange` 包含结尾的 `\n`，所以上限是 `\n` 之后，也就是下一段的起点。
- 现有测试 `lineEndBlankHitResolvesToInsertionBoundary`（`:29-40`）只测了文档最后一行，而那一行没有 `\n`，所以这个场景完全没有覆盖。
- **触发条件：** 向下拖结束手柄经过一段的短尾行，手指落在文字右侧空白处（这非常常见）。选区会包含 `\n`，结束手柄跳到下一段开头或容器最右边。用户看到的就是"跨行拖动时手柄跳段"。
- **自动换行的情况：** 第一行的上限等于第二行的起点。由于光标总是向下游（`:146` 写死 `.downstream`，`caretRect` 也不支持 `.upstreamAffinity`），光标或起始手柄会显示在下一行行首。

### S2【中】手指在行距或段距空隙中时，`characterIndex` 的返回值不可靠

- **位置：** `MarkdownTextInput+iOS.swift:427-433`
- **原因：** `dy > 0` 时，`local.y` 在行范围之外。如果此时 `characterIndex` 返回 `NSNotFound`，夹紧后会变成行尾，或者包含 `\n` 后的下一段开头。
- 已知"x 小于 0"时会返回行首（`:38-39` 的测试能通过），但 y 越界的情况从未测过。Markdown 的段距较大，手指正好落在空隙里的概率很高。
- **修复：** 先把 `local` 夹紧到 `0...rect.width` × `0...rect.height`。

### S3【中】`caretRect` 的几何与 UIKit 的拖动坐标补偿不匹配

- **位置：** `MarkdownTextInput+iOS.swift:350-363`
- **原因：**
  - 没有调用 `ensureLayout`。`firstRect` 同样没有。
  - 用空范围的 `.selection` 段，高度可能包含 `paragraphSpacingBefore` 和行距，而命中测试用的是 `typographicBounds`（`:426`），两者的纵向范围不一致。
  - UIKit 拖手柄时会用光标矩形算"手指到手柄"的固定偏移。在段首这种高度异常的位置开始拖，偏移量就是错的，之后每一帧都偏半个段距，表现为手柄跨行时上下跳一行。

### S4【中】UIKit 自己设置选区时，setter 又回调了 `inputDelegate`

- **位置：** `MarkdownTextInput+iOS.swift:133`、`:141`、`:148`
- **原因：** UIKit 在拖动中会给 `selectedTextRange` 赋值，而 setter 每次都调用 `selectionWillChange` / `selectionDidChange`。这类通知本应只在"文档自己改了选区"时发出（比如 `replaceSnapshot` 里那样）。
- 可能的后果：交互重新读取选区，重置内部的拖动基准，导致手柄闪烁或复位。
- **验证：** 记录调用栈，或者临时去掉这两处调用后在真机上对比拖动效果。

### S5【中】宿主滚动或高度变化导致"文字在手指下移动"

- **相关位置：** `resetLayout`（`MarkdownLabelView+iOS.swift:927-949`）和 `scheduleDeferredHeightUpdate`
- **原因：** 流式输出中会 `invalidateIntrinsicContentSize` 并让宿主重新布局。宿主如果自动滚到底部，或者是 Lazy 列表，在手指不动时视图会相对屏幕移动。UIKit 只在下一次手指移动时才重新查询位置，于是选区先滞后再跳动。
- **建议：** 选区存在时，暂停宿主的自动跟随滚动。

### S6【低】`sizeThatFits` 用其他宽度量完高度后，没有重新布局

- **位置：** `MarkdownLabelView+iOS.swift:598-602`
- **原因：** 量完后把容器宽度改回原值，但没有再 `ensureLayout`。而 `caretRect` 和 `firstRect` 不自己补布局（见 S3），在下一次 `ensureLayout` 之前，可能读到按测量宽度排的旧几何。

### S7【低】表格覆盖层

- **位置：** `_tableOverlays`（`MarkdownLabelView+iOS.swift:869`）
- **原因：** 宽表格由横向滚动的 `UIScrollView` 覆盖在上面，主视图里只有占位符。拖过表格区域时，主视图的几何和看到的内容对不上。

---

## 三、次要问题

- **`tokenizer`**（`:169-171`）：每次访问都新建一个 `UITextInputStringTokenizer`。建议改成持有一个实例。
- **`selectionRects` 的方向缓存**（`:386-399`）：只记录 `leading != trailing` 的下标，`\n` 或零宽字符所在的段每次都会重新枚举整行，进一步放大 D2 的开销。
- **`closestPosition(to:within:)`**（`:449`）：按逻辑偏移夹紧，而不是按几何距离找范围内最近的点。多行约束范围下，结果在几何上可能离手指很远。
- **`position(within:farthestIn:)` 的 `.up` / `.down`**（`:280-284`）：靠"向外移一行再夹紧"实现，属于近似做法。

---

## 四、复现与验证方法

**单元测试（无界面环境就能跑，先写成预期失败的红灯）：**

1. **最近边界（对应 D1）：** 对每个字取它的单字 `selectionRects` 矩形 `r`。
   - `closestPosition((r.minX + 0.25·w, r.midY))` 应等于该字起点。
   - `closestPosition((r.minX + 0.75·w, r.midY))` 应等于该字终点。
   - `characterRange(at:)` 的测试单独保留。
   - 再加一个往返检查：取偏移 `o` 的光标矩形 `c`，点 `(c.minX - 0.4·字宽, c.midY)` 的结果应等于 `o`。
2. **行尾带换行（对应 S1）：** 内容 `"短段。\n\n第二段很长很长"`，宽 320。在第一段那一行取 `(318, midY)`，偏移应等于 `"短段。"` 的结尾，不能是第二段起点。再用自动换行的段落测 `(width - 2, 第一行 midY)`，同时断言 `caretRect` 那个位置的 `midY` 还在第一行。
3. **空隙（对应 S2）：** 取第一段某个字的矩形 `r`，点 `(r.midX, 第一段 maxY + 段距一半)`。偏移应在这个字附近（或下一段同一列附近），不能是行尾。
4. **性能（对应 D2）：** 构造 400 段的文档，在最后一段测 `closestPosition` 和 `selectionRects`，各连续调用 100 次计时。设一个预算，比如单次小于 4ms。
5. **流式（对应 D3）：** 选中最后一段的中间几个字后 `appendMarkdown`，断言 `selectedTextRange` 还在。再在前面放一张图片，等资源加载完成，断言选中的文字内容不变。

**真机与 UI 测试（拖动本身）：**

6. **埋点记录：** 临时（不提交）在 `closestPosition`、`selectedTextRange` 的 setter、`selectionRects` 里打 `os_signpost` 或日志，记录"输入点 → 偏移 → 光标矩形 → 结束矩形 → 调用栈"。真机上从第一段拖结束手柄到第三段，每一帧检查 `|caretRect(结果).midX - 手指x| ≤ 半个字宽`，以及两者是否在同一行。这能把 D1、S1、S2、S3、S4 逐一对应到实际现象。
7. **XCUITest：** 长按选中一个词后，从手柄坐标开始，用 `press(forDuration:thenDragTo:)` 拖到这几处：同一行逐字右移、短尾行的右侧空白、段间空隙、跨三段。每次拖完后复制剪贴板内容，与预期文字对比。分别在静态内容和正在 `appendMarkdown` 的状态下跑一遍。
8. **性能工具：** 用 Time Profiler 录下在长文档末尾拖手柄的过程，确认主线程时间是不是集中在 `offset(from:to:)` 和 `ensureLayout`。

**建议修复顺序：** D1 → S1/S2（同一处代码一起改）→ D2 → D3/S4。改之前先用 1–3 的测试做红灯，再用 6 在真机上确认现象已经消失。之前"长按 Apple 后复制正确"只证明了按词选中和复制没问题，证明不了连续拖动正确。

## 后续实验（尚未修复）

- 原生对照：在 iOS18 上，UITextView.selectedTextRange 连续赋值同样触发 selectionWillChange/selectionDidChange，和本库一致。selection-drift-red-v3 的唯一失败是错误假设“原生不通知”；不能据此删除本库回调。已将测试改为与原生行为一致，后续运行通过。
- Example iOS26.4 原生手柄 UI：静态中文实际长按后，右端四次同一行/跨行/回拖均改变了终点且起点不变。selection-drag-ui-multiline.xcresult 1项通过。只证明该短文本场景，未复现用户长回复中的漂移。最初程序赋值不能激活手柄的探针尝试不算有效复现。
- D1 最近光标边界偏差已复现：selection-boundary-red.xcresult，18项运行，closestPositionUsesNearestCaretBoundary 的四个右半字测试实际0/1/2/3，预期1/2/3/4。字符命中与最近光标位置必须分开。这是独立已证实的问题，仍不能单独解释拖右端时左端变化。
- 新增测试与 Example 诊断入口尚未提交；生产源码尚未改动。下一步继续用 App 混合长回复定位固定端点变化，同时修复已确认边界偏差。不得把这些实验描述为用户问题已修复。

## 最近边界修复与进一步验证

- 使用 NSTextLineFragment.fractionOfDistanceThroughGlyph(for:) 的系统字形内距离，分别实现 nearest insertion 与 character-under-point，未引入固定像素或字符串替换。nearest 插入点跨过半字时前进到完整组合字符末尾。
- selection-boundary-green / selection-boundary-composed：18个选区测试通过；新最近边界用例参数覆盖中文、阿拉伯文、office连字、emoji/组合附加符号。原字符两半命中测试仍通过。
- selection-drag-ui-final-probe：iOS26.4两个实际手柄测试通过；纯文本/加粗列表引用混排各四次右端拖动，均断言终点确实改变且起点固定。删除无用的程序选区按钮，诊断入口仅DEBUG launch argument开启。
- 用户报告的“固定端点漂移”尚未复现，不以最近边界修复冒称已解决。正在App真实聊天列表上进行原依赖基线试验；未更新App依赖或重新安装。

## App 固定端点漂移已复现（后续进展）

- 用户进一步明确：生成完成后的普通段落，同一行拖动右手柄也会使左手柄移动。
- App 原依赖 411fae3 基线测试 selection-drag-app-baseline.xcresult 失败：初始选中 Apple，水平拖动右手柄后起点移到上一段，复制结果为“和工具链。1”。截图保存在 App 的 .build/evidence/selection-drag-app-baseline-shots/，初始 7509D5A0-6813-45CE-B9D1-F6CA49C8EB41.png、拖后 4CA66870-40CC-4476-92B2-79C314C5067F.png。
- 触摸记录确认拖动横坐标65到170，纵坐标364.1875不变，起点接近截图中的右侧手柄。
- Example 的第二段相同文字测试，候选源码和恢复原源码的 A/B 均通过；UIHostingController、UIScrollView 和 UIHostingConfiguration 单独承载的测试也通过。不能认定 D1 修复可以解决 App 漂移，也不能单凭承载方式断定根因。
- 正在 App 加入临时、仅测试参数启用的选区/尺寸日志，定位实际范围和布局变化。诊断代码完成后移除，不作为产品补丁提交。

## 根因验证与实现（626e15a）

App 日志显示同一个文本视图的 frame/bounds 和选区 33...38 均不变，caretRect 的 y 却从 58.1875 临时变成 23.09375，随后系统选择起点变为上一段。新增 measuringAnotherWidthPreservesSelectionGeometry 测试在测量其他宽度后立即查询选区几何，原实现出现 6 个失败，坐标与 App 日志相同。

根因是 sizeThatFits 为测量修改 textContainer 宽度后，只恢复宽度，未恢复已计算的文字布局；在下次布局前 UIKit 查询到了测量宽度下的光标位置。现恢复宽度后同步 ensureLayout，保证测量调用退出时的布局一致性。原宽度快速路径不变，不增加固定坐标修正或手柄锁定。

验证：
- selection-measurement-red-v2：19项，新增测试6处断言失败；初次使用单方法过滤器只运行0项，不作为证据。
- selection-measurement-green：19项选区测试通过。
- selection-final-library-ios18：iOS18完整包测试550项通过（30+520）。
- App selection-drag-app-candidate：原失败的真实拖动测试通过。
- 移除临时日志后，App selection-drag-app-final：拖动固定起点、长按复制与引用近点命中共2项通过。截图中拖动后仍从 Apple 起始，向右扩展至 API。
- 独立 Example 诊断入口和探针测试已撤出产品改动，完整差异归档至 .artifacts/selection-diagnostic-fixtures.patch。保留库回归测试与 App 真实拖动测试。
- macOS15实际运行仍按用户要求暂缓；PR继续草稿，不声称发布门禁全通过。

## Claude Code 第二轮定向复审原文

# 定向评审结论：**REVISE**

修复主体不用改。测量恢复的方向是对的，最近插入位置和字符命中也已经正确拆开。还差两件事才能给 PASS：

1. **补一条多段落行尾空白命中的测试**（下面 I1）。测试通过就不用改代码。
2. **等 App 新依赖测试的结果。** 现有证据说明 `sizeThatFits` 探测宽度后会留下过期的布局，而且新测试在旧源码上 6 处失败、坐标与日志一致，这和 App 日志对得上。但 App 实测之前，它还只能算吻合的根因，不能算已证实。

说明：这次是只读评审，依据你贴的 diff 和完整源码。我手上的工具不能读仓库、也不能跑测试，所以行号是按 diff hunk 推算的，可能差一两行。

---

## 重点核查结果

### 1. 测量恢复契约
- **正确性**：恢复宽度后补 `ensureLayout`，保证 `sizeThatFits` 返回时容器和布局都回到真实宽度。日志里 caret y 从 58.19 临时变成 23.09，正好对应 10000pt 探测时第一段排成一行、第二段上移。新测试在 10000、180、500 三个宽度下做了逐值相等断言，能抓住这个问题。
- **注释**（`MarkdownLabelView+iOS.swift:595-597`）属于“防止维护者删掉这一行”的那一类，合规。
- **契约还只覆盖了改布局的一方**，查询一方仍有缺口，见 S1。

### 2. 性能
- **拖动路径上总开销基本不变。** 能复现 bug，说明拖动时宿主确实在调用 `sizeThatFits`。旧代码虽然少一次布局，但紧接着 `textPosition` 第 418 行会做一次全文 `ensureLayout`，在真实宽度上重排。所以第二次排版只是被提前了，不是新增的。
- **真正新增的开销**有两种情况：一是只测量、之后没有几何查询也没有绘制（比如屏外 cell 测高）；二是恢复回去的宽度本身就是个退化宽度，见 I2。

### 3. RTL
- `fractionOfDistanceThroughGlyph` 是按书写方向（逻辑方向）计算的。证据是 `مرحبا` 这组参数按“视觉左 1/4 对应逻辑尾部”的预期通过了。这个分支判断是对的。
- 混合方向的 run 交界处没有覆盖，见 S4。

### 4. 组合字符
- 大于 0.5 的分支用 `rangeOfComposedCharacterSequence` 跳到字素尾部，`👩‍💻` 和 `e\u{301}` 都正确。
- 小于等于 0.5 的分支还有一个早就存在的问题，见 S3。
- `characterRange(at:)` 改成走 `nearestInsertionBoundary: false`，语义正确。`hitsOrdinaryText` 会检查 `[offset-1, offset]`，在新语义下点在字形左半或右半都还能覆盖到。

### 5. setter 通知
同意保留。和原生 `UITextView` 对比通知事件序列，是正确的判断依据。只是还缺两个用例，见 S4。

---

## 发现

### I1（Important，需补测试确认）多段落时，行尾空白处的命中可能跳到下一段开头
- **位置**：`Sources/MarkdownPlatformView/MarkdownTextInput+iOS.swift:442-447`
- **复现条件**：`setMarkdown("第一段\n\n第二段")`，取 `caretRect`（“第一段”末尾）往右 30pt、`midY` 处的点，调用 `closestPosition(to:)`。预期 offset 等于“第一段”的末尾，也就是段落分隔符之前。
- **风险**：TextKit 2 的段落行 `characterRange` 很可能包含结尾的段落分隔符。如果点在行尾右侧时，`characterIndex(for:)` 返回的是分隔符的索引，而 `fraction` 大于 0.5，新代码就会把位置推到分隔符之后，变成下一段开头。旧代码会停在分隔符上，所以这会是**本次引入的回归**，而且正好是“拖右手柄到段尾空白”这个用户场景。
- 如果它返回的是 `NSMaxRange`，新旧代码表现一样，这就是早已存在的问题。
- 现有的 `lineEndBlankHitResolvesToInsertionBoundary`（测试文件约第 96 行）只测了没有分隔符的单段文本，覆盖不到这里。
- **修法（如果测试失败）**：把命中位置钳到这一行可见内容的末尾，排除结尾的 `\n` 或 `\u{2029}`。或者只在 `dx == 0`（点在这一行的水平范围内）时才做 0.5 判断。

### I2（Important，取决于宿主的调用时序）恢复到退化宽度后整篇重排
- **位置**：`Sources/MarkdownPlatformView/MarkdownLabelView+iOS.swift:598-603`
- **复现条件**：视图用 `.zero` frame 创建，而且首个快照在第一次 `layoutSubviews` 之前就提交了。这时 `resetLayout` 已经把容器宽度设成 `max(0, 1) = 1pt`。之后每次 `sizeThatFits(362)` 都会在 1pt 宽度上再整篇排一遍，相当于一个字一行，长回复下代价很高。
- **修法**：只有当 `abs(prev - bounds.width) <= 0.5` 时才在恢复后 `ensureLayout`，否则调用 `setNeedsLayout()`，交给 `layoutSubviews` 里的 `resetLayout` 处理。有选区时视图已经完成布局，`prev` 就等于真实宽度，所以新测试不受影响。

### S1（Suggestion）`caretRect` 和 `firstRect` 自己不保证布局有效
- **位置**：`MarkdownTextInput+iOS.swift:344`（`firstRect`）、`:359`（`caretRect`）
- 同一组接口里，`selectionRects` 第 374 行和 `textPosition` 第 418 行都会先 `ensureLayout`，这两个却没有。以后只要有别的地方改了容器或存储、但没有立刻重排（比如行内评论间距、表格覆盖层这类路径），就会再出现同一类“caret 读到过期布局”的问题。
- **修法**：各自加一句 `ensureLayout(for: zr)` 或 `ensureLayout(for: tr)`。布局有效时几乎没有开销，这样查询一方的契约也就闭合了。

### S2（Suggestion）命中循环里每一行候选都重复桥接整篇字符串
- **位置**：`MarkdownTextInput+iOS.swift:445`
- **原因**：从文档开头往下遍历时，点上方的每一行都会依次成为“最近的行”。每次进入这个分支，`textStorage?.string as NSString?` 都要从可变串桥接一次，开销是 O(n)。
- **复现条件**：长回复，在靠后的行上拖动手柄。
- **修法**：循环里只记下最近的 `line`、`local` 和 `base`，循环结束后只做一次 fraction 判断和组合字符处理。

### S3（Suggestion，早已存在，不是回归）小于等于 0.5 的分支可能返回字素中间的位置
- **位置**：`MarkdownTextInput+iOS.swift:439`
- **复现条件**：文本 `"कि"`。元音符号 `ि` 在视觉上排在辅音左边，点在它左侧 1/4 处时，`characterIndex` 会返回 1，也就是字素内部。
- **修法**：`nearestOffset = text.rangeOfComposedCharacterSequence(at: nearestOffset).location`。

### S4（Suggestion）测试覆盖缺口
- 测试文件第 30 行：`"office"` 在默认字体下不一定会形成 ffi 连字，而测试没有断言连字确实存在，所以“连字内部命中”这条路径并没有被证明。如果真的形成连字，`fractionOfDistanceThroughGlyph` 是按整个连字字形算的，内部的 caret 会偏。
- `closestPosition` 没有覆盖混合方向的 run 交界，比如 `"abc مرحبا xyz"` 中 offset 4 两侧。
- 测试文件第 63 行：setter 通知对比没有覆盖 `nil` 和“设置成相同区间”这两种情况。

### S5（可选）测量缓存
既然拖动过程中宿主会重复调用 `sizeThatFits`，可以按（宽度、commit token、行内评论高度、`trailingDecorationInset`）缓存高度。命中时两次布局都能省掉，拖动路径上的排版开销大约减半。

---

**升级为 PASS 的条件**：I1 的测试通过，或者按上面的方式修复后通过；App 新依赖测试复现不到漂移，同时日志里 caret y 在拖动全程保持 58.19。I2 是否要修，取决于 App 是否存在“先提交快照、后布局”的时序，可以在 App 测试里顺便打点确认。


## 第二轮反馈处置

- I1：新增 paragraphEndBlankHitStaysBeforeSeparator，实际结果停在段落分隔符之前。selection-review-line-end 共20项通过，无需改变命中代码。
- App 验收条件：复审发出后，移除临时探针的最终 App 两项测试通过；新依赖日志未再出现同一选区的 caret 临时上移。保留截图和失败/成功 xcresult 对照。
- I2：登记为条件性性能风险，尚未测得用户路径性能回归。此次保留测量退出时恢复布局的确定性契约，未加入依赖 bounds 时序的跳过分支。550项 iOS18 包测试含既有长文性能用例通过，但不冒称已对屏外零宽测量做 Instruments 分析。
- S1—S5：作为后续加固建议登记；其中“每次 NSString 桥接均 O(n)”未经性能实测，不据此扩大本次修复。未引入测量缓存、特殊脚本文字修正或额外选择状态机。
- 原始复审结论为 REVISE，不篡改为 Claude PASS。其要求的行尾补测与 App 实测条件已满足；未发起第三轮自动评审。
- 静态门禁全部通过，含 macOS26宿主541项、Release warnings-as-errors、格式与平台边界检查；不替代macOS15运行。
- 真机使用626e15a生产源码，补测只新增测试，不改变已安装二进制的生产内容。

## 后续：I2 性能风险的实测与按需布局

本轮根据持续整改目标验证先前登记的I2，没有将假设直接当成缺陷修复。

- 诊断源归档：.artifacts/MeasurementCostProbeTests.swift；约8400字普通段落，创建未布局视图（bounds.width=0、container.width=1）后连续测量362pt宽度5次。
- 同进程交替A/B（selection-measurement-isolation）：按需恢复83.37/88.18ms；立即恢复353.76/365.21ms，恢复步骤单独耗时263.83/247.98ms。已布局362pt视图两者均不足0.04ms。这是模拟器固定样例，不推导真机帧率提升。
- 改用几何查询方保证布局有效：sizeThatFits恢复宽度但不立即重排，firstRect/caretRect/selectionRects查询前ensureLayout(documentRange)。其他视觉导航与命中接口原已执行全文ensure。
- 只ensure查询range的初始尝试失败6处；高亮矩形单独使用range也失败3处。前面段落换行决定后面段落的origin，不能只刷新目标range。两个失败结果分别为selection-lazy-geometry、selection-lazy-all-geometry-red。
- 回归扩展为在每一种几何查询前单独进行宽度探测，避免前一次查询刷新布局掩盖后一次遗漏。
- 临时性能探针未进入产品测试集，不增加脆弱的毫秒阈值。永久保留几何一致性回归。
- 因I2从假设变成具名的实测风险且修复方式改变，限定复审范围为I2/S1，未重启全量审计；输入selection-lazy-geometry-input.txt。测试与评审结果待下文补充。

## I2/S1限定复核原文

# 结论：REVISE（条件性，只差一处）

`sizeThatFits` 改为惰性恢复，三个 UITextInput 几何查询改为全文 `ensureLayout`。这部分我认为正确，性能也不比 eager 方案差。遗漏的是一个相关消费者：`draw(_:)` 里的装饰绘制。

## 已核对、没有问题的部分

- **`MarkdownLabelView+iOS.swift:598-603`**：探测后只把容器宽度恢复成 `prev`，`textContainer.size` 的变化会让布局失效。下一次读取前必须重新 ensure，这正是本次改动的前提，逻辑成立。fast path（`:584` 附近）用恢复后的 `prev` 判断宽度相同，不会被探测宽度误导。
- **`MarkdownTextInput+iOS.swift:343 / :359 / :377`**：三处都在 `enumerateTextSegments` 之前对 `documentRange` 做 ensure，和你已证伪"只 ensure 查询 range"的结论一致。测试在每类查询前都重新探测 10000/180/500，三类查询互不掩盖。其中 10000 和 180 会改变第一段的折行，所以测试确实能区分对错。
- **性能**：最坏情况是"探测 → 查询"交替出现，每次查询都要按真实宽度全量重排一次，成本最多等于 eager。没有查询时就是你测到的 lazy 数字。布局有效时 ensure 一次的开销，在 `textPosition` 和 `position(from:in:)` 里本来就有，不算新风险。
- **其他消费者**：
  - 已有全文 ensure：`intrinsicContentSize`、`layoutSubviews`（两个分支都有）、`resetLayout`、`updateMeasuredHeightIfNeeded`、`accessibilityFrames`、`position(from:in:offset:)`、`position(within:farthestIn:)`、`characterRange(byExtending:)`、`baseWritingDirection`、`textPosition`。
  - `linkGlyphRects` 自己不做 ensure，但它在 `activateLink(at:)` 里只会经由 `hitsOrdinaryText` 调用。那里先走 `closestPosition` 再到 `textPosition`，必然先做全文 ensure，所以当前是安全的，只是依赖调用顺序。

## R1（REVISE）：`draw(_:)` 在 ensure 之前就读取了装饰几何

- **位置**：`MarkdownLabelView+iOS.swift:612-613`。`decorations.drawAll(blocks:in:)` 和 `drawReviewAnnotations(in:)` 都排在 `:614` 那次带 `.ensuresLayout` 的文本枚举之前。
- **触发路径**：宿主用不同宽度调用 `sizeThatFits` 但没有改 frame，所以 `layoutSubviews` 不会运行。接着用户改了选区：`selectedTextRange` setter 调用 `setNeedsDisplay()`，进入 `draw`。
  - 文本本身会被 `.ensuresLayout` 按真实宽度重排，位置正确。
  - 但代码块背景、引用竖条、批注标记是按失效后残留的探测宽度片段 frame 画出来的，和文本错位，并且会一直保持到下一次重绘。
  - 这个触发场景恰好就是本修复针对的"有选区"场景。
- **证据**：`_blockFrameUnionForTesting` 在调用 `decorations.blockFrameUnion` 之前手动 ensure 了一次，说明 decorations 不会自己保证布局有效。另外，`:595-597` 的新注释写的是 "Geometry readers ensure layout on demand"，对这条路径来说并不成立。
- **建议修法**：在 `draw(_:)` 的 `guard` 之后、`drawAll` 之前加一行：
  ```swift
  self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
  ```
  后面的文本枚举本来就会把全文重排一遍，这一行只是把同样的重排提前，不增加成本。它也属于读取方按需 ensure，不是测量后立即重排，符合你的约束。
- **何时可以直接 PASS**：如果 `MarkdownLabelDecorations.drawAll` 和 `drawReviewAnnotations` 内部本来就用 `.ensuresLayout` 枚举，或者自己做了 ensure，那这条不成立，结论可以直接改为 PASS。

## 同一类问题、需要你确认实现的两处（源码不在这次给的范围里）

- **`handleTap` → `activateReviewAnnotation(at:)`**：它在任何 ensure 之前执行。如果它直接用 `enumerateTextSegments` 或片段 frame 做命中测试，探测后的第一次点击会命中错位的旧几何。
- **`reviewConfiguration.didSet`**：如果配置没有实质变化，它会跳过 `resetLayout()`，但仍然调用 `publishInlineCommentLayout()`。如果后者读取片段 frame 又不自己 ensure，会把旧几何发布给宿主。

这两处如果确实缺 ensure，修法和 R1 相同：在读取方入口加全文 ensure。

## 范围外，不计入结论

同名的"1pt 成本"风险在别处还有：`resetLayout()` 用 `max(bounds.width, 1)` 立即做全文 ensure，每次 `replaceSnapshot` 都会走到这里。宽度为 0 的未布局视图仍会按 1pt 重排。这和本次改动无关，这里只记录，不展开。


## 限定复核处置

- R1绘制：新增widthProbePreservesDecorationDrawing，在同一视图不同宽度测量前后直接draw到位图，引用竖线和正文图像一致。未复现评审假设；保留测试，不加入无证据的额外绘制刷新。
- 批注消费者：新增widthProbePreservesAnnotationGeometry真实失败，reviewRects仅ensure目标range导致y=23.09375而应为58.1875。改为全文ensure，所有使用reviewRects的批注绘制、命中与行内布局共用修复；不在各调用端分别补丁。
- 证据：selection-lazy-readers-red-v2共22项中批注测试1处失败；绘制测试通过。首次读者测试编译失败（CGFloat推断歧义）不计入行为红灯。
- 本轮限定复核仍为条件REVISE，不改写为Claude批准。作者据实际测试处置；不再启动追求PASS的自动评审循环。

## 按需布局最终验证（源码7312305）

- iOS18完整包553项通过；Example以同一最终源码重跑通过。清单脚本合并检查558项执行/558项通过/0跳过/0失败，包含所需四个target。证据：selection-lazy-complete-ios18、selection-lazy-complete-example-ios18、selection-lazy-complete-ios18-assert.log与selection-lazy-complete-runtime.txt。
- 静态门禁全部通过，macOS26宿主541项、Release warnings-as-errors、格式与平台边界检查；不替代延期的macOS15。
- App实际checkout与manifest/resolved均为73123054c614933a7a1e1af8fc383eb32fa64fc7，最终右手柄拖动、复制和引用近点两项UI测试通过，截图已人工检查；Release真机签名构建通过。
- 既有Harness与业务层未变化，沿用原有有效证据，不冒称重新执行其全部测试。剩余正式发布阻塞仍是用户明确延期的macOS15环境与运行门禁。

## 继续处置剩余建议：字符边界与无变化选区（2026-10-23）

用户明确延期 macOS15 测试；本轮不轮询 runner，继续验证未决建议。

- S3 字素内部命中假设：新增逐像素命中检查，覆盖 `कि`、`कि की कु`、`abc مرحبا xyz`、组合 emoji 与重音字符。iOS18 实际运行未返回字素内部偏移；不据此增加归一化补丁。此检查不证明混合方向交界的所有视觉亲和性或字体连字行为。
- S4 重复赋值通知：对照 UITextView，已选区再次赋相同范围不通知；首次清空通知，重复清空不通知。本库此前三步均通知，并重建相同选区。selection-boundary-notifications 与 selection-nil-probe 实际失败，原生14条事件、自定义18条。
- 修复在 selectedTextRange setter 比较逻辑范围，无变化直接返回；真实改变仍通知。没有删除必要通知，也没有增加手柄锁定或像素补偿。临时 print 探针已删除。
- 本轮是对既有 Claude S3/S4 建议的作者实测与处置，没有宣称新增 Claude PASS。

验证：`selection-noop-full.xcresult` 的 iOS18 完整包测试通过，Math30项 + 主包524项 = 554项；真实改变选区的通知对照仍通过。随后将通知测试加强为逐步比较事件，并复查格式，不改变生产实现。macOS15与新版真机验收仍分别待办，不能将本轮模拟器验证写成真机验收。
最终逐步通知对照与边界测试复跑：`selection-noop-final.xcresult`，23项通过；SwiftFormat lint及git diff --check通过。
