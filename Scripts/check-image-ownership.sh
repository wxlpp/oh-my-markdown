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
        my $platform = qr/(?:UIImage|NSImage|PlatformImage)/;
        my $construct = qr/\b$platform\s*(?:\.\s*init\s*)?\(\s*(?:data|cgImage)\s*:/;
        my $collection = qr/\[\s*[\w.]+\s*:\s*$platform\s*\]|\bDictionary\s*<[^>]*$platform\s*>|\b(?:Set|Array|ContiguousArray)\s*<[^>]*$platform\s*>/;
        # Count violation-shaped tokens only: prose may name these types freely.
        my $pattern = qr/\b(?:LegacyResourceOwner|CGImageSourceCreate\w+)\b|$construct|$collection/;
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
        exit 1 if $text =~ /\b$platform\s*(?:\.\s*init\s*)?\(\s*data\s*:/s;
        # No collection of platform images outside the residency ledger, in any spelling.
        exit 1 if $text =~ /$collection/s;
        # Remote bytes are only ever downsampled; full-resolution ImageIO decoding
        # stays confined to the in-process rendered-resource path.
        if ($file ne $rendered) {
            exit 1 if $text =~ /\bCGImageSourceCreateImageAtIndex\b/s;
        }
        if ($file ne $decoder) {
            exit 1 if $text =~ /\bCGImageSourceCreateThumbnailAtIndex\b/s;
        }
        if ($file ne $materializer && $file ne $rendered) {
            exit 1 if $text =~ /\b$platform\s*(?:\.\s*init\s*)?\(\s*cgImage\s*:/s;
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

# The compiler already forces an `owner:` argument on every resolved image, so the
# load-bearing check is which owners exist at all: exactly the two accounted leases.
conformers="$(rg --no-filename --no-heading --no-line-number -o '\b\w+\s*:\s*(?:ResourceResidencyOwner|RenderedResourceOwning)\b' "$source_root" \
    | rg -v '^(?:ResourceResidencyOwner|RenderedResourceOwning)\s*:' | sort -u || test "$?" -eq 1)"
expected='ImageOwnerLease: ResourceResidencyOwner
RenderedResourceLease: RenderedResourceOwning'
if [[ "$conformers" != "$expected" ]]; then
    printf 'FAIL: residency owner inventory changed\n--- found ---\n%s\n--- expected ---\n%s\n' "$conformers" "$expected" >&2
    exit 1
fi
echo 'PASS: every published image is lease-owned and decoded through the bounded thumbnail path'
