#!/usr/bin/env bash
# .claude/skills/auto-fix-pr-after-implementation/scripts/request-copilot.sh <PR>
#
# 请求 Copilot 对指定 PR 重跑一轮 code review，同时输出 baseline + Monitor 模板。
# 设计目的：把 `gh pr edit --add-reviewer @copilot` 和后续 Monitor 的 baseline 取数绑死
# 在一条命令里，避免“触发了但忘起 Monitor”。

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <PR_NUMBER>" >&2
    exit 2
fi

PR="$1"
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
    echo "error: <PR_NUMBER> 必须是纯数字（你传的是 \"$PR\"），不要传 URL 或分支名" >&2
    exit 2
fi
OWNER_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

# 1. add-reviewer
gh pr edit "$PR" --add-reviewer @copilot >/dev/null

# 2. 验证真的加进去了（静默失败的唯一可靠检测）
REQUESTED=$(gh api "repos/$OWNER_REPO/pulls/$PR" \
    --jq '[.requested_reviewers[].login] | contains(["Copilot"])')

if [ "$REQUESTED" != "true" ]; then
    # Copilot 接请求后可能立刻从 queue 移走——此时已经开始 review，也算成功
    PENDING=$(gh api graphql -f query="
        query { repository(owner: \"${OWNER_REPO%/*}\", name: \"${OWNER_REPO#*/}\") {
          pullRequest(number: $PR) {
            reviewRequests(first: 10) { nodes {
              requestedReviewer { ... on Bot { login } ... on User { login } }
            }}
          }
        }}" --jq '[.data.repository.pullRequest.reviewRequests.nodes[].requestedReviewer.login] | contains(["Copilot"])')
    if [ "$PENDING" != "true" ]; then
        echo "⚠️  add-reviewer 调用成功但 Copilot 没进 queue——可能 repo 没装 Copilot reviewer 应用" >&2
        # 不 exit 1：有时 Copilot 立刻开始了 review；让调用方看 baseline 决定
    fi
fi

# 3. 取当前 Copilot 最后一次 submit 的时间戳作为 Monitor baseline。
BASELINE=$(gh api "repos/$OWNER_REPO/pulls/$PR/reviews" --paginate \
    --jq '[.[] | select(.user.login == "copilot-pull-request-reviewer[bot]")]
          | sort_by(.submitted_at) | last.submitted_at // ""')

cat <<MSG
✅ Copilot re-review 已请求 (PR #$PR, $OWNER_REPO)
baseline_ts=$BASELINE

⚠️  下一步必做：立即起 Monitor 等新 submitted_at——这两条是原子对。

Monitor 模板（直接复制到 Monitor tool call 的 command 字段，timeout 1800000ms）：

LAST="$BASELINE"; while true; do OUT=\$(gh api "repos/$OWNER_REPO/pulls/$PR/reviews" --paginate --jq "[.[] | select(.user.login == \"copilot-pull-request-reviewer[bot]\") | select(.submitted_at > \"\$LAST\")] | .[0] | select(. != null) | \"\(.submitted_at) commit=\(.commit_id[0:7]) state=\(.state) body=\(.body[0:200] | gsub(\"\\n\"; \" \"))\"" 2>/dev/null || true); if [ -n "\$OUT" ]; then echo "\$OUT"; exit 0; fi; sleep 30; done
MSG