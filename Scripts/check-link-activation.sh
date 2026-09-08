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
# `Link` and `Text` collide with swift-markdown's `Markup.Link`/`Markup.Text` in
# exactly one file. That file is inventoried, so the names can be matched
# unconditionally everywhere else: anchoring on `import SwiftUI` instead would
# break on `internal import`, `public import` and attributed forms, which this
# package already uses.
markup="MarkdownCore/DocumentParser.swift"
for required in "$handler" "$editor" "$markup"; do
    if [[ ! -f "$source_root/$required" ]]; then
        echo "FAIL: an inventoried file is missing: $source_root/$required" >&2
        exit 1
    fi
done

openers='(?:^|[^A-Za-z0-9])(?:UIApplication|NSWorkspace|LSApplicationWorkspace|LSOpen\w*|SFSafariViewController|SFAuthenticationSession|ASWebAuthenticationSession|WKWebView|UIWindowScene|UIScene|OpenURLAction|openURL|UIDocumentInteractionController|UIActivityViewController|NSSharingService\w*|NSTask|Process|posix_spawn\w*|execv\w*|popen|NSAppleScript|NSDocumentController|NSHelpManager|SKStoreProductViewController|MFMailComposeViewController|dataDetectorTypes)\b'
# A text view opens a `.link` run by itself. `NSTextField` is the same mechanism
# reached under another name: it vends an `NSTextView` as its field editor.
# Not a leading `\b`: `\bLSOpen` does not match `_LSOpenURLsWithRole`, and
# leading-underscore identifiers are house style here. Written without
# look-behind so it works on an rg built without PCRE2.
text_views='\b(?:UITextView|NSTextView|NSTextField)\b'
# SwiftUI renders a `.link` run in an AttributedString through the environment's
# OpenURLAction, with no opener name anywhere in the source. Confining the views
# that can render one is the only lever this instrument has on that family.
swiftui_views='\b(?:Link|Text|ShareLink|TextEditor|TextField)\b'

count=0
while IFS= read -r -d '' file; do
    count=$((count + 1))
    relative="${file#"$source_root"/}"
    [[ "$relative" == "$handler" ]] && continue

    # No separate alias rule is needed: an alias names its right-hand side, so the
    # opener pattern already matches the declaration itself.
    patterns=(-e "$openers")
    [[ "$relative" == "$editor" ]] || patterns+=(-e "$text_views")
    [[ "$relative" == "$markup" ]] || patterns+=(-e "$swiftui_views")

    # Ordered blanking, strings before comments, newlines preserved: prose may
    # name these types, code may not, and line numbers stay real. The limits are
    # real and worth knowing: code inside a string interpolation, a name reached
    # through NSClassFromString, and a function-typed indirection such as
    # `var open: ((URL) -> Void)?` — which names nothing at all — are invisible
    # here. `system` is deliberately absent: the word is too common to inventory
    # without false positives. This is a regression tripwire, not a proof.
    #
    # The blanking relies on leftmost-match, not on alternation order: a `"""`
    # inside a comment cannot swallow code, because the comment alternative starts
    # earlier and therefore wins.
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
