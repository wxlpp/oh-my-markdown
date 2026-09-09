#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tokens="$(rg --hidden --no-ignore -n -o '@unchecked' Sources || test "$?" -eq 1)"
matches="$(rg --hidden --no-ignore -n '@unchecked' Sources || test "$?" -eq 1)"
expected='^Sources/MarkdownRenderKit/ResolvedResource\.swift:[0-9]+:[[:blank:]]*package struct ImmutableCGImageBacking: @unchecked Sendable \{$'
if [[ "$(printf '%s\n' "$tokens" | wc -l | tr -d ' ')" != 1 ]] || ! printf '%s\n' "$matches" | rg -q "$expected"; then
    printf 'FAIL: production unchecked Sendable inventory changed\n%s\n' "$matches" >&2
    exit 1
fi
if rg -n 'LegacyResourceOwner' Sources; then
    printf 'FAIL: the retention bridge is gone; every resource owner is a lease\n' >&2
    exit 1
fi
echo 'PASS: only ImmutableCGImageBacking is unchecked; no retention bridge remains'
