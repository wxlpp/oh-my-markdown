#!/bin/bash

set -euo pipefail

if (($# != 3)); then
    printf 'usage: %s <ios18|macos15> <result> <output-path>\n' "$0" >&2
    exit 64
fi

section="$1"
result="$2"
output_path="$3"

case "$section" in
    ios18)
        simulator_runtime="iOS 18.0"
        scheme="oh-my-markdown-Package,Example"
        ;;
    macos15)
        simulator_runtime="not_applicable"
        scheme="oh-my-markdown-Package"
        ;;
    *)
        printf 'unknown runtime metadata section: %s\n' "$section" >&2
        exit 64
        ;;
esac

mkdir -p "$(dirname "$output_path")"
host_os="$(sw_vers -productVersion 2>&1 || true)"
xcode_version="$(xcodebuild -version 2>&1 | head -1 || true)"
swift_version="$(swift --version 2>&1 | head -1 || true)"
git_sha="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || true)}"

{
    printf 'host_os=%s\n' "${host_os:-unavailable}"
    printf 'xcode_version=%s\n' "${xcode_version:-unavailable}"
    printf 'swift_version=%s\n' "${swift_version:-unavailable}"
    printf 'simulator_runtime=%s\n' "$simulator_runtime"
    printf 'scheme=%s\n' "$scheme"
    printf 'git_sha=%s\n' "${git_sha:-unavailable}"
    printf 'result=%s\n' "$result"
} >"$output_path"

printf 'Runtime metadata: %s\n' "$output_path"
