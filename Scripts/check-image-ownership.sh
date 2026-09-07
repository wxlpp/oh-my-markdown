#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_root="${1:-Sources}"
materializer="$source_root/MarkdownRenderKit/RenderMaterializer.swift"
decoder="$source_root/MarkdownPlatformView/ImageDecoder.swift"
# Task 4C's math/SVG path decodes images its own host renderer produced in-process.
# Task 7 governs untrusted remote bytes, so that file keeps its full decode.
rendered="$source_root/MarkdownRenderKit/RenderedImage.swift"
for required in "$materializer" "$decoder" "$rendered"; do
    if [[ ! -f "$required" ]]; then
        echo "FAIL: missing required file $required" >&2
        exit 1
    fi
done

count=0
while IFS= read -r -d '' file; do
    count=$((count + 1))
    if ! perl -0777 -e '
        use strict; use warnings;
        my ($file, $materializer, $decoder, $rendered) = @ARGV[0, 1, 2, 3];
        open(my $handle, "<", $file) or exit 1;
        my $text = do { local $/; <$handle> };
        # Count constructor-shaped tokens only: prose may name these types freely.
        my $pattern = qr/\b(?:LegacyResourceOwner|CGImageSourceCreate\w+)\b|\b(?:UIImage|NSImage|PlatformImage)\s*\(\s*(?:data|cgImage)\s*:/;
        my $before = () = $text =~ /$pattern/g;
        1 while $text =~ s{/\*(?:(?!/\*|\*/).)*\*/}{ }gs;
        $text =~ s{//[^\n]*}{ }g;
        my $after = () = $text =~ /$pattern/g;
        # Token loss through comment-like trivia fails closed.
        exit 1 if $before != $after;
        $text =~ s/`//g;
        # The retention bridge is gone; every image owner is a residency lease.
        exit 1 if $text =~ /\bLegacyResourceOwner\b/s;
        # No platform image may be built straight from untrusted encoded bytes.
        exit 1 if $text =~ /\b(?:UIImage|NSImage|PlatformImage)\s*\(\s*data\s*:/s;
        # No cache of platform images keyed outside the residency ledger.
        exit 1 if $text =~ /\[\s*\w+\s*:\s*(?:UIImage|NSImage|PlatformImage)\s*\]/s;
        # Remote bytes are only ever downsampled; full-resolution ImageIO decoding
        # stays confined to the in-process rendered-resource path.
        if ($file ne $rendered) {
            exit 1 if $text =~ /\bCGImageSourceCreateImageAtIndex\b/s;
        }
        if ($file ne $decoder) {
            exit 1 if $text =~ /\bCGImageSourceCreateThumbnailAtIndex\b/s;
        }
        if ($file ne $materializer && $file ne $rendered) {
            exit 1 if $text =~ /\b(?:UIImage|NSImage|PlatformImage)\s*\(\s*cgImage\s*:/s;
        }
        # Every resolved image resource is published with an explicit owner.
        for my $line (split /\n/, $text) {
            next unless $line =~ /=\s*\.image\s*\(/;
            exit 1 unless $line =~ /\bowner\s*:/;
        }
        exit 0;
    ' "$file" "$materializer" "$decoder" "$rendered"; then
        echo "FAIL: unowned or unbounded image construction: $file" >&2
        exit 1
    fi
done < <(rg --files --hidden --no-ignore -0 -g '*.swift' "$source_root")

if [[ "$count" -eq 0 ]]; then
    echo 'FAIL: empty source inventory' >&2
    exit 1
fi
echo 'PASS: every published image is lease-owned and decoded through the bounded thumbnail path'
