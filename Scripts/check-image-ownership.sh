#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_root="${1:-Sources}"
materializer="$source_root/MarkdownRenderKit/RenderMaterializer.swift"
decoder="$source_root/MarkdownPlatformView/ImageDecoder.swift"
# Task 4C's math/SVG path decodes images its own host renderer produced in-process.
# Task 7 governs untrusted remote bytes, so that file keeps its full decode.
rendered="$source_root/MarkdownRenderKit/RenderedImage.swift"
# The one file allowed to name a platform image type: aliasing it anywhere else
# would let every rule below be evaded by indirection.
platformtypes="$source_root/MarkdownRenderKit/PlatformTypes.swift"
for required in "$materializer" "$decoder" "$rendered" "$platformtypes"; do
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
        my ($file, $materializer, $decoder, $rendered, $platformtypes) = @ARGV[0, 1, 2, 3, 4];
        open(my $handle, "<", $file) or exit 1;
        my $text = do { local $/; <$handle> };
        my $platform = qr/(?:UIImage|NSImage|PlatformImage)/;
        # Every initializer that turns bytes, a file or a raw image into a platform
        # image, in either the bare or the explicit `.init` spelling.
        my $construct = qr/\b$platform\s*(?:\.\s*init\s*)?\(\s*(?:data|cgImage|ciImage|contentsOf|contentsOfFile)\s*:/;
        my $alias = qr/\btypealias\s+\w+\s*=\s*(?:\w+\s*\.\s*)?$platform\b/;
        my $collection = qr/\[\s*[\w.]+\s*:\s*$platform\s*\]|\bDictionary\s*<[^>]*$platform\s*>|\b(?:Set|Array|ContiguousArray)\s*<[^>]*$platform\s*>/;
        # Count violation-shaped tokens only: prose may name these types freely.
        my $pattern = qr/\b(?:LegacyResourceOwner|CGImageSourceCreate\w+)\b|$construct|$collection|$alias/;
        my $before = () = $text =~ /$pattern/g;
        1 while $text =~ s{/\*(?:(?!/\*|\*/).)*\*/}{ }gs;
        $text =~ s{//[^\n]*}{ }g;
        my $after = () = $text =~ /$pattern/g;
        # Token loss through comment-like trivia fails closed.
        exit 1 if $before != $after;
        $text =~ s/`//g;
        # The retention bridge is gone; every image owner is a residency lease.
        exit 1 if $text =~ /\bLegacyResourceOwner\b/s;
        # No platform image may be built straight from bytes or a file path.
        exit 1 if $text =~ /\b$platform\s*(?:\.\s*init\s*)?\(\s*(?:data|ciImage|contentsOf|contentsOfFile)\s*:/s;
        # No *second* name for a platform image type: aliasing would defeat every
        # rule here. Re-exporting the same name under a new module is fine.
        while ($text =~ /\btypealias\s+(\w+)\s*=\s*(?:\w+\s*\.\s*)?$platform\b/gs) {
            exit 1 unless $1 =~ /\A(?:UIImage|NSImage|PlatformImage)\z/;
        }
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
        # Residency owners are an inventory, not a shape: the conformance may sit
        # anywhere in an inheritance clause and may span lines.
        my %allowed = map { $_ => 1 } qw(ImageOwnerLease RenderedResourceLease RenderedResourceOwning);
        while ($text =~ /\b(?:class|struct|enum|actor|protocol|extension)\s+(\w+)\s*:[^{]*?\b(?:ResourceResidencyOwner|RenderedResourceOwning)\b/gs) {
            exit 1 unless $allowed{$1};
        }
        exit 0;
    ' "$file" "$materializer" "$decoder" "$rendered" "$platformtypes"; then
        echo "FAIL: unowned or unbounded image construction: $file" >&2
        exit 1
    fi
done < <(rg --files --hidden --no-ignore -0 -g '*.swift' "$source_root")

if [[ "$count" -eq 0 ]]; then
    echo 'FAIL: empty source inventory' >&2
    exit 1
fi

echo 'PASS: every published image is lease-owned and decoded through the bounded thumbnail path'
