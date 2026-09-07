#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_root="${1:-Sources}"
if [[ ! -d "$source_root" ]]; then
    echo "FAIL: source root does not exist: $source_root" >&2
    exit 1
fi

# Same instrument as the image ownership gate: confine the *names*, not the
# shapes. A link can only reach the system through the one audited handler, so
# every type that can open a URL is confined to the file that declares it.
handler="MarkdownPlatformView/MarkdownLinkPolicy.swift"
if [[ ! -f "$source_root/$handler" ]]; then
    echo "FAIL: the audited link handler is missing: $source_root/$handler" >&2
    exit 1
fi

count=0
while IFS= read -r -d '' file; do
    count=$((count + 1))
    relative="${file#"$source_root"/}"
    [[ "$relative" == "$handler" ]] && continue
    if match="$(rg --no-heading --line-number -o '\b(?:UIApplication|NSWorkspace|LSApplicationWorkspace|SFSafariViewController|ASWebAuthenticationSession|openURL)\b' "$file" | head -1)"; then
        if [[ -n "$match" ]]; then
            echo "  $relative:${match%%:*}: names \`${match##*:}\`, which can open a URL; only $handler may" >&2
            echo 'FAIL: a link could reach the system outside the audited handler' >&2
            exit 1
        fi
    fi
done < <(rg --files --hidden --no-ignore -0 -g '*.swift' "$source_root")

if [[ "$count" -eq 0 ]]; then
    echo 'FAIL: empty source inventory' >&2
    exit 1
fi
echo 'PASS: only the audited link handler can reach a platform URL opener'
