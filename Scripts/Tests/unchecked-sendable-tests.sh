#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/oh-my-markdown-unchecked.XXXXXX")"
trap 'rm -r -- "$fixture_dir"' EXIT
mkdir -p "$fixture_dir/Scripts" "$fixture_dir/Sources/MarkdownRenderKit"
cp "$repo_root/Scripts/check-unchecked-sendable.sh" "$fixture_dir/Scripts/"
audited='package struct ImmutableCGImageBacking: @unchecked Sendable {'
source="$fixture_dir/Sources/MarkdownRenderKit/ResolvedResource.swift"
extra="$fixture_dir/Sources/Extra.swift"
failures=0
check() {
    local name="$1" expected="$2" actual=0
    bash "$fixture_dir/Scripts/check-unchecked-sendable.sh" > "$fixture_dir/output" 2>&1 || actual=$?
    if [[ "$actual" -eq "$expected" ]]; then
        printf 'PASS: %s (exit %s)\n' "$name" "$actual"
    else
        printf 'FAIL: %s expected exit %s, got %s\n' "$name" "$expected" "$actual" >&2
        failures=$((failures + 1))
    fi
}
printf '%s\n}\n' "$audited" > "$source"
check 'unique exact audited declaration' 0
variants=(
    'struct Extra: @unchecked Sendable {}'
    'struct Extra: @unchecked  Sendable {}'
    $'struct Extra: @unchecked\tSendable {}'
    'struct Extra: @unchecked /* comment */ Sendable {}'
    $'struct Extra: @unchecked\nSendable {}'
    'struct Extra: @unchecked Sendable {} // @unchecked'
)
names=('normal' 'multiple spaces' 'tab' 'comment separator' 'newline separator' 'two tokens on one line')
for index in "${!variants[@]}"; do
    printf '%s\n' "${variants[index]}" > "$extra"
    check "extra ${names[index]}" 1
done
printf '\n' > "$extra"
printf 'package struct ImmutableCGImageBackingSuffix: @unchecked Sendable {\n}\n' > "$source"
check 'name suffix' 1
printf '\n' > "$source"
printf '%s\n}\n' "$audited" > "$extra"
check 'audited name in another file' 1
printf '\n' > "$extra"
printf '%s\n}\n' "$audited" > "$fixture_dir/Sources/MarkdownRenderKit/ResolvedResourceXswift"
check 'lookalike file extension' 1
printf '\n' > "$fixture_dir/Sources/MarkdownRenderKit/ResolvedResourceXswift"
check 'no audited token' 1
printf '%s\n}\n' "$audited" > "$source"
check 'restored exact declaration' 0
if ((failures)); then exit 1; fi
printf 'All unchecked Sendable isolation cases passed.\n'
