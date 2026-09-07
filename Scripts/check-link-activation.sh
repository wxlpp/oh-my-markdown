#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_root="${1:-Sources}"
if [[ ! -d "$source_root" ]]; then
    echo "FAIL: source root does not exist: $source_root" >&2
    exit 1
fi

# Same instrument as the image ownership gate: confine the *names*, because a
# rule that pins how code looks can be rewritten around. Every name that can put
# a URL in front of the system is confined to the one audited handler.
handler="MarkdownPlatformView/MarkdownLinkPolicy.swift"
# The Markdown *editor* is a genuine text-view subclass showing raw source, not
# rendered links, so the text-view names are inventoried there rather than banned.
editor="MarkdownPlatformView/MarkdownEditorTextView.swift"
for required in "$handler" "$editor"; do
    if [[ ! -f "$source_root/$required" ]]; then
        echo "FAIL: an inventoried file is missing: $source_root/$required" >&2
        exit 1
    fi
done

openers='\b(?:UIApplication|NSWorkspace|LSApplicationWorkspace|LSOpen\w*|SFSafariViewController|ASWebAuthenticationSession|WKWebView|OpenURLAction|openURL)\b'
text_views='\b(?:UITextView|NSTextView)\b'
# `Link` collides with swift-markdown's `Markup.Link`, so it counts only in a
# file that imports SwiftUI. Scoped rather than dropped.
swiftui_openers='\bLink\b'

count=0
while IFS= read -r -d '' file; do
    count=$((count + 1))
    relative="${file#"$source_root"/}"
    [[ "$relative" == "$handler" ]] && continue

    patterns=(-e "$openers" -e "typealias\s+\w+\s*=\s*(?:\w+\s*\.\s*)?$openers")
    [[ "$relative" == "$editor" ]] || patterns+=(-e "$text_views")
    if rg --quiet '^[[:space:]]*import[[:space:]]+SwiftUI\b' "$file" 2>/dev/null; then
        patterns+=(-e "$swiftui_openers")
    fi

    # Ordered blanking, strings before comments, newlines preserved: prose may
    # name these types, code may not, and line numbers stay real.
    blanked="$(perl -0777 -e '
        open(my $handle, "<", $ARGV[0]) or exit 1;
        my $text = do { local $/; <$handle> };
        $text =~ s{
            ( """ (?: \\. | "(?!"") | [^"\\] )* """ | \#+" .*? "\#+ | " (?: \\. | [^"\\\n] )* " )
          | ( /\* .*? \*/ )
          | ( // [^\n]* )
        }{
            my $matched = defined $1 ? $1 : (defined $2 ? $2 : $3);
            my $newlines = ($matched =~ tr/\n//);
            " " . ("\n" x $newlines)
        }gsex;
        print $text;
    ' "$file")" || {
        echo "  $relative: could not be read" >&2
        echo 'FAIL: the link gate could not scan every source file' >&2
        exit 1
    }

    # Never branch on a pipeline's exit status: a SIGPIPE from a downstream
    # `head`, a permission error, or any other rg failure would all read as
    # "clean". Capture, then branch on rg's own status.
    match="$(rg --no-heading --line-number --max-count 1 -o "${patterns[@]}" <<<"$blanked")" && status=0 || status=$?
    if ((status > 1)); then
        echo "  $relative: rg exited $status while scanning" >&2
        echo 'FAIL: the link gate could not scan every source file' >&2
        exit 1
    fi
    if [[ -n "$match" ]]; then
        echo "  $relative:${match%%:*}: names \`${match##*:}\`, which can put a URL in front of the system; only $handler may" >&2
        echo 'FAIL: a link could reach the system outside the audited handler' >&2
        exit 1
    fi
done < <(rg --files --follow --hidden --no-ignore -0 -g '*.swift' "$source_root")

if [[ "$count" -eq 0 ]]; then
    echo 'FAIL: empty source inventory' >&2
    exit 1
fi
# Scope is deliberately the library: tests and the Example app are not it.
echo "PASS: in $source_root, only the audited handler can reach a URL opener"
