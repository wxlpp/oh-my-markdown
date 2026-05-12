---
name: auto-fix-pr-after-implementation
description: |
  当本会话刚刚通过任意路径（superpowers / ccpm / 直接 gh pr create / 其他）
  在 GitHub 上打开了一个 PR，且该 PR 尚未收到 Copilot review 时，直接启动
  fix-pr 工作流：拉全部 review 反馈 → 分析 → 修改代码 → 验证（Round 2+）→
  提交 → threaded reply → 触发下一轮 Copilot review。**触发条件不绑定特定
  worktree 或 superpowers 来源**——只要当前会话里刚开了 PR 就激活。
---

# 在本地处理 PR 的 review 反馈

拉取评论 → 分析 → 修改代码 → 验证（Round 2+）→ 提交 → 回复 → 触发下一轮。

## 触发条件

只有在以下条件全部满足时才激活：

- 当前会话里刚打开了一个 PR（session state，或 `gh pr view --json createdAt` 检查最近创建时间，一般 5 分钟内）
- 该 PR 还没有收到 Copilot 的首轮 review（首轮 review 由 PR 打开事件自动触发，约 2–5 分钟到达；本 skill 监控并响应它）
- 用户没有显式选择退出（检查 session memory）

后续轮次（Round 2+）继续自动跑，但需要主动用 `request-copilot.sh` 触发——见 §3.5 / §8.5。

## 1. 定位 PR

- 当前会话刚开过 PR → session state 里 PR 编号
- 否则 `gh pr view --json number,headRefName,state,url` 取当前分支的 PR
- 当前分支没关联 PR → 停并提示用户

## 2. 拉全所有反馈

**首选用脚本**（hard-code 了 §3.1 的 login 陷阱）：

```bash
.claude/skills/auto-fix-pr-after-implementation/scripts/fetch-comments.sh <PR> [--since ISO8601]
```

脚本输出 4 块：Copilot review objects、Copilot inline comments、人类 inline comments、CI checks。两个 endpoint 的 login 字符串已经分别硬编码，避免 §3.1 的漏查。

脚本不可用时手动拉下面 6 项，缺一不可：

| 拉什么 | 命令 |
|---|---|
| PR 元数据 | `gh pr view <PR> --json title,body,state,reviewDecision` |
| 主线评论 | `gh pr view <PR> --comments` |
| 行内 review 评论 | `gh api repos/{owner}/{repo}/pulls/<PR>/comments` |
| review 对象（每轮一个） | `gh api repos/{owner}/{repo}/pulls/<PR>/reviews` |
| thread `isResolved` | GraphQL reviewThreads，见 §8.3 |
| CI 状态 | `gh pr checks <PR>` |

处理原则：
- 只处理**未 resolved** 的 thread（`isResolved == false` 且最后一条评论不是当前 git user）
- CI failed 的 check 也算"未处理反馈"
- 优先 `CHANGES_REQUESTED`
- 同文件多条评论合并考虑，避免来回改
- **Copilot review 是独立作者**——漏处理 merge 后就补不回了（Copilot 不 review 已 closed PR）

如果**所有**未处理反馈都是空（评论类 + CI 类）：本轮 **empty**，输出一行状态（如 `PR #<N> 没有需要处理的新反馈`），**跳过 §4–§9** 直接退出。

## 3. Copilot 陷阱速查

Copilot 接入有几个不直觉的坑，踩过就不能再踩。

### 3.1 Copilot 在两个 endpoint 的 login 字段不一样

| endpoint | `.user.login` |
|---|---|
| `/pulls/<PR>/comments`（inline 行内评论） | `"Copilot"` |
| `/pulls/<PR>/reviews`（review 对象） | `"copilot-pull-request-reviewer[bot]"` |

**不要**跨两个 endpoint 共用同一 filter 字符串——会直接 0 条漏掉真评论。per-endpoint 用对应字符串，或 `.user.login | IN("Copilot", "copilot-pull-request-reviewer[bot]")` 兜底。

### 3.2 等 Copilot 一轮 review 完成：看 `/reviews` 的 `submitted_at`

Copilot review 是异步的，push 后典型 2–5 分钟完成一轮。**不要**用"`/comments` 条数稳定 N 秒"做启发式——自己发的 threaded reply 也会让计数涨。

权威信号：`/pulls/<PR>/reviews` 里 Copilot 新增一个 review 对象，`body` 开头是
`Copilot reviewed N out of M changed files in this pull request and generated K comments.`

Monitor 模板：

```bash
LAST_TS=$(gh api "repos/$OWNER/$REPO/pulls/$PR/reviews" --paginate \
  --jq '[.[] | select(.user.login == "copilot-pull-request-reviewer[bot]")]
        | sort_by(.submitted_at) | last.submitted_at // ""')
# Monitor 每 30s 拉最新 Copilot review，submitted_at > LAST_TS 就算完成
```

**必须 `--paginate`**：GitHub `/pulls/<num>/reviews` 默认每页 30 条，不支持 `sort` /
`direction` 参数（没法倒序抓最新几条）。活跃 PR（多轮 Copilot + 各种 review reply
衍生的 review 对象）很快翻页，新 review 落后续页会让 baseline / 监听 query 只扫
第一页、永远不匹配，Monitor 看似"卡住"。曾尝试过 `per_page=100` 作为轻量替代，但
**不可靠**——PR 寿命超过 100 条 review 后同样失败。`scripts/request-copilot.sh`
里 baseline 和 Monitor 模板都改用 `--paginate` 拉全量再 `sort_by | last`。

### 3.3 `generated K` 是唯一 empty 判断（包括 suppressed）

- `K == 0` → 本轮 empty，可以直接 merge
- `K > 0` → 走 §4，**包括** Copilot 自己放进 "Comments suppressed due to low confidence" 折叠块的那几条

`low confidence` 是 Copilot 的信心 hedge，不是跳过借口。suppressed comment 的特殊处理：

- 没有独立 comment ID，不能 `in_reply_to`
- 用 `gh pr comment <PR> --body "..."` 发 PR 顶层评论
- body 里带 `[Copilot round N review](https://github.com/<owner>/<repo>/pull/<PR>#pullrequestreview-<review_id>)` 链接 + 指向 `file:line`
- 不论采纳与否都必须回复，拒绝时讲清理由（引 CLAUDE.md 规则 / 测试证据 / 编译验证）

### 3.4 触发 Copilot re-review 用脚本（add-reviewer + Monitor baseline 绑定）

```bash
.claude/skills/auto-fix-pr-after-implementation/scripts/request-copilot.sh <PR>
```

脚本做三件事：
1. `gh pr edit <PR> --add-reviewer @copilot`（**必须 `@copilot` 带 `@`**——其他写法 §3.4.1 有对照表）
2. 验证 Copilot 真进 queue 了（API 静默失败是历史坑）
3. 输出 Monitor `baseline_ts` + 填好的 Monitor command 模板

**⚠️ 脚本结尾的 Monitor command 必须当场启动**——脚本和 Monitor 是**原子对**。只要调了脚本，同一 turn 里就必须起 Monitor，别拆开。

#### 3.4.1 直接调 gh CLI / REST 的对照表（脚本不可用时备查）

| 命令 | 结果 |
|---|---|
| `gh pr edit --add-reviewer @copilot` | ✅ 成功（脚本走这条） |
| `gh pr edit --add-reviewer Copilot`（无 `@`） | ❌ GraphQL "Could not resolve user 'copilot'" |
| REST `POST /requested_reviewers -f 'reviewers[]=Copilot'` | ❌ 200 但静默丢弃 |
| REST 同上 `reviewers[]=copilot-pull-request-reviewer[bot]` | ✅ 但繁琐 |

如果 repo 没装 Copilot reviewer 应用，脚本的 verify 步会 warn 但不 exit 1——按人工 review 流程走。

### 3.5 push 不会让 Copilot 自动跟

**Copilot 只在 PR 首次打开时自动 review**。每次新 commit push 到 PR 后都要显式跑 §3.4，不能假设"已在 reviewer 列表就自动跟下一轮"。只在 §9.5（`fixed` 路径）调用。

## 4. 分析与计划

- 未处理反馈做 TaskCreate 清单：来源 URL、文件:行号、类别（bug / 风格 / 架构 / 测试缺失 / ...）
- 每条判断 **接受 / 部分 / 拒绝**，记理由
- 拒绝的在最终回复里要讲为什么，不能默默忽略
- 反馈之间冲突 → 停下来问用户优先级

**⚠️ 评估每条评论前必须 Read 它标注的具体 `file:line`，再下接受/拒绝判断**——grep 只能做定位，不能当判断依据。常见 failure mode：

- grep filter 返回 0 条 → 没 Read 确认 → 以为没 inline comments → 漏整条
- grep 扫调用侧把它当"证据"，没 Read 真身就脑补"已经修了，误报" → reject 错

规则：**grep 定位 + Read 判断**，两步缺一不可。特别是当你"一眼就想 reject"时——那正是 confirmation bias 最强的时候，必须 Read 才能下结论。

## 5. 修改代码

- 严格遵 CLAUDE.md：双语注释惯例、显式 `self.`、Swift 6 严格并发、Primer / CoreDesign token 规范、`bundle: .module` 资源加载
- 一次改一个关注点，避免把多个修复混在一起难 review

## 6. 本地验证

跑下面的命令验证本轮 fix 引入的改动。

**首轮 fix-pr** 可以跳过——PR 刚创建时，提 PR 之前的 `swift build` / `swift test` 已经在 PR opener 那边验证过，首轮 review 通常带的是 doc / 注释级别的小改动，回归风险低。

**Round 2 及之后必须跑**——累积的改动让 build/test 风险线性增长，不能再借首轮的新鲜度。依次跑，任一失败必须修完才进入 §7：

1. `swift build -Xswiftc -warnings-as-errors` — 必须 0 warning 通过（严格并发等价于 build 错误）
2. `swift test` — Swift Testing 框架，stub 测试也要跑通
3. （可选，组件级 / modifier 改动）`#Preview` 视觉抽查 light + dark 双 colorScheme

例外（即使在 Round 2+ 也可跳过）：本轮改动**纯粹是仓库内的 markdown / 文档**（PR 描述、`docs/*.md`、`.claude/**`），不接触任何 `.swift` / `.xcassets` / `Package.swift`——这种情况下 build/test 与本轮无关，可以省。

## 7. 提交

- Commit message：`type(scope): 中文摘要`（CoreDesign 仓近期惯例：`feat:` / `fix:` / `docs(ccpm):` / `refactor:` / ...）
- 本次是第几轮：`git log --oneline | grep "PR #<N>"` 数一下，命名如 `fix(scope): 处理 PR #<N> 第 K 轮 review 反馈`（或描述本轮主修内容）
- 提交前 `git status` + `git diff --staged` 复核，**不要** `git add -A`——逐文件加避免混入 `.env` / credentials
- Message 末尾保留 `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`

## 8. 推送与回复（自动执行，不再问用户）

### 8.1 push

- `git push` 到当前 tracking 分支
- **绝不** `--force` / `--force-with-lease`
- push 必须先于回帖：回复里引的 commit hash 没推上去会 404

### 8.2 threaded reply（每条 inline 评论单独回）

走 Pull Request Review Comments API 在原 comment 下面挂回复，让 reviewer 可以一条条点 Resolve：

```bash
gh api -X POST repos/<owner>/<repo>/pulls/<PR>/comments \
  -f body="..." \
  -F in_reply_to=<original_comment_id> \
  --jq '.html_url'
```

**对每条未 resolved 的 inline comment 都要回**，内容模板：

| 情况 | 内容 |
|---|---|
| 本轮新修 | `已修复 (<hash>)：<改动 + 文件:行号>` |
| 前几轮已修但 thread 未 auto-resolve | `已修复：<改动 + 当前文件:行号>` |
| 拒绝 | `未采纳：<理由>` |
| 部分采纳 | `部分采纳：<采纳部分 + 未采纳部分的理由>` |

格式要点：
- 1–3 句话
- 指向**当前**代码位置（不是 commit diff）
- 本轮新修要带 commit hash
- 代码标识符 / 文件路径用反引号
- **commit SHA 必须用半角括号 `(hash)` 或空格 `commit <hash>` 包**——GitHub autolink 只
  认 ASCII 边界。**不要**用全角括号 `（hash）`——`（）` 不被当分隔符，整串视作一个词，
  SHA 不 link。

对于 §3.3 的 suppressed comment 不适用 threaded reply——用 `gh pr comment` 发顶层评论，带 review 链接 + file:line。

如果 reply body 含中文双引号 / 复杂 markdown：把 body 写到 `/tmp/reply.md`，再用 `body=$(cat /tmp/reply.md)` + `-f body="$body"` 传——避免 shell 解析中文引号截断 `-f` 参数。

### 8.3 识别需要回的 thread

GraphQL 拿 thread 的 `isResolved`，跳过已 resolved：

```bash
gh api graphql -f query='
query {
  repository(owner: "<owner>", name: "<repo>") {
    pullRequest(number: <PR>) {
      reviewThreads(first: 100) {
        nodes {
          isResolved
          isOutdated
          comments(first: 1) { nodes { databaseId } }
        }
      }
    }
  }
}'
```

### 8.4 并行发送

一次 tool call 并行发全部 reply（GitHub authenticated 写操作 rate limit 充裕）。每条 `--jq '.html_url'` 收敛输出。

### 8.5 请求 Copilot 下一轮 review

`fixed` 路径走完 §8.1–§8.4 后，跑 §3.4 命令触发下一轮。`empty` 路径不用（本轮没新 commit）。

## 9. 报告

给用户一份简短总结：

- 处理数量（接受 / 拒绝 / 部分 / 前轮已修待 resolve）
- 修改文件清单
- analyze / test 结果
- commit hash + push 状态
- threaded reply 数

**到此为止**。§8.5 已请求下一轮 review，起一个 Monitor（§3.2 模板）等新 `submitted_at`；不自动启 cron loop。

## 10. 决定是否继续循环

每轮收尾后：

- `empty`（无新反馈）：退出报告成功
- `fixed`（已修并推）：§8.5 触发后回到 §3.2 起 Monitor 等下一轮
- 无硬性轮数上限——只要 review 仍有未处理反馈、且未触发 §重要事项 / §失败处理 中任一停止条件，就继续自动循环。每轮各消耗 1 次 Copilot premium request，循环成本计入用户预算；用户可以随时显式 opt-out 终止

### 10.1 babysit / cron 模式（可选——仅无人值守场景）

> 默认不启用。attended 流程用 §3.2 的 Monitor 就够——一次性、精准、零 token 空转。
> 本节只在用户明确说"babysit / 我离开几小时不看 PR"时手动启。

**状态载体**：

- 计数文件：`/tmp/fix-pr-<owner>-<repo>-<PR>.count`（单行整数）
- cron job：`prompt="/fix-pr"`、`recurring=true`。`CronList` 按 prompt 精确匹配找 id

**决策表**（仅 babysit 模式生效）：

| 本轮结果 | cron 存在？ | 动作 |
|---|---|---|
| `fixed` | 否 | 计数清零；`CronCreate(cron="2-59/5 * * * *", prompt="/fix-pr", recurring=true)` |
| `fixed` | 是 | 计数清零；保持 cron |
| `empty` | 否 | 直接退出（不启 loop） |
| `empty` | 是 | `count += 1`；`count >= 4` → `CronDelete` + 删计数；`< 4` → 保持 |

cron 表达式 `"2-59/5 * * * *"`（每 5 min，相位偏 2 min）。

**为什么默认不启**：

- cron 每 5 min 进一次完整 Claude 对话，99% 是 empty 轮 → token 空转
- 5 min tick vs Monitor 30s 轮询 → 响应慢 10 倍
- 复杂 review（架构建议 / trade-off）Claude 独自误修后 merge，代价比等用户高
- §3.2 的 `submitted_at` 是权威信号，不需要启发式

## 重要事项

- 每一轮 Copilot review 都会消耗一次 premium request。循环没有硬性轮数上限，但用户可以随时打断；每一轮开始前简短回报本轮规划，让用户有切入窗口。
- 如果遇到需要人工判断的 `CHANGES_REQUESTED`（架构分歧、范围争议），立即停止并上报给用户，不要自动处理。
- Round 2+ 的 fix 必须过 §6 验证；`swift build` 或 `swift test` 失败时立即停止，不要推送损坏的提交。Round 1 因为继承 PR-open 时的验证状态可以跳过 §6（首轮例外，仅当本轮改动是非平凡 swift 源代码时谨慎评估是否仍需补跑）。
- 不要自动启用 babysit cron mode。这个能力只能由用户显式开启。

## 失败处理

- §2 拉评论失败：手动跑 §2 表格里的 6 个命令兜底
- §3.2 Monitor 超时（10 min）：询问用户继续等还是不带 review 推进
- §3.4 add-reviewer 失败 / queue 没接：仓库没装 Copilot reviewer 应用 → 退出自动循环
- §6 验证失败：fix → 再跑一遍，**不**推送损坏 commit
