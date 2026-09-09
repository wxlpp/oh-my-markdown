#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_root="${1:-Sources}"
factory="$source_root/MarkdownPlatformView/ValidatedImageFactory.swift"
if [[ ! -f "$factory" ]]; then
    echo 'FAIL: validated image factory is missing' >&2
    exit 1
fi
count=0
while IFS= read -r -d '' file; do
    count=$((count + 1))
    [[ "$file" == "$factory" ]] && continue
    if ! perl -0777 -e '
        use strict; use warnings;
        my $text = <>;
        my $before = () = $text =~ /\bMarkdownEncodedImage\b/g;
        # Strip nested block comments from the inside out, then line comments.
        1 while $text =~ s{/\*(?:(?!/\*|\*/).)*\*/}{ }gs;
        $text =~ s{//[^\n]*}{ }g;
        my $after = () = $text =~ /\bMarkdownEncodedImage\b/g;
        # Ambiguous token loss (including comment-like string contents) fails
        # closed instead of allowing a constructor to hide behind trivia.
        exit 1 if $before != $after;
        $text =~ s/`//g;
        exit 1 if $text =~ /\bMarkdownEncodedImage\s*(?:\(|\.\s*init\b)/s;
        exit 1 if $text =~ /\bextension\s+(?:\w+\s*\.\s*)?MarkdownEncodedImage\b/s;
        exit 1 if $text =~ /\btypealias\b[^;=]*=\s*(?:\w+\s*\.\s*)?MarkdownEncodedImage\b/s;
        exit 1 if $text =~ /\bvalidatedData\s*:/s;
        exit 0;
    ' "$file"; then
        echo "FAIL: validated image construction or alias outside factory: $file" >&2
        exit 1
    fi
done < <(rg --files --hidden --no-ignore -0 -g '*.swift' "$source_root")
if [[ "$count" -eq 0 ]]; then
    echo 'FAIL: empty source inventory' >&2
    exit 1
fi
echo 'PASS: validated image construction is confined to its factory'
