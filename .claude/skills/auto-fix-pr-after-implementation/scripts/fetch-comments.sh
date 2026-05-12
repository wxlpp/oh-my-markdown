#!/usr/bin/env bash
# .claude/skills/auto-fix-pr-after-implementation/scripts/fetch-comments.sh <PR> [--since ISO8601]
#
# 拉取 PR 的所有 review 反馈，专治“Copilot 两个 endpoint login 字段不一样”导致的漏查。
# 输出 4 块：
#   1. Copilot review objects (/reviews endpoint, login = copilot-pull-request-reviewer[bot])
#   2. Copilot inline comments (/comments endpoint, login = Copilot)
#   3. 人类 inline comments
#   4. CI checks

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <PR_NUMBER> [--since ISO8601]" >&2
    exit 2
fi

PR="$1"
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
    echo "error: <PR_NUMBER> 必须是纯数字（你传的是 \"$PR\"），不要传 URL 或分支名" >&2
    exit 2
fi
SINCE=""
if [ "$#" -ge 3 ] && [ "$2" = "--since" ]; then
    SINCE="$3"
fi

OWNER_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

SINCE_FILTER_REVIEWS=""
SINCE_FILTER_COMMENTS=""
if [ -n "$SINCE" ]; then
    SINCE_FILTER_REVIEWS="| select(.submitted_at >= \"$SINCE\")"
    SINCE_FILTER_COMMENTS="| select(.created_at >= \"$SINCE\")"
fi

echo "=== [1/4] Copilot review objects (/reviews, login=copilot-pull-request-reviewer[bot]) ==="
gh api --paginate "repos/$OWNER_REPO/pulls/$PR/reviews" \
    --jq ".[] | select(.user.login == \"copilot-pull-request-reviewer[bot]\") $SINCE_FILTER_REVIEWS | \"[\(.id)] \(.submitted_at) commit=\(.commit_id[0:7]) state=\(.state)\n  body[0:200]=\(.body[0:200] | gsub(\"\n\"; \" \"))\""
echo

echo "=== [2/4] Copilot inline comments (/comments, login=Copilot) ==="
gh api --paginate "repos/$OWNER_REPO/pulls/$PR/comments?per_page=100" \
    --jq "[.[] | select(.user.login == \"Copilot\") $SINCE_FILTER_COMMENTS] | .[] | \"[\(.id)] \(.created_at) \(.path):\(.line // .original_line)\n  \(.body)\n\""
echo

echo "=== [3/4] Human inline comments (/comments, login != Copilot) ==="
gh api --paginate "repos/$OWNER_REPO/pulls/$PR/comments?per_page=100" \
    --jq "[.[] | select(.user.login != \"Copilot\") $SINCE_FILTER_COMMENTS] | .[] | \"[\(.id)] \(.user.login) @ \(.created_at) \(.path):\(.line // .original_line)\n  \(.body[0:300])\n\""
echo

echo "=== [4/4] CI checks ==="
gh pr checks "$PR" 2>&1 || true