#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_root="${1:-Sources}"

# Enumerating forbidden spellings does not work: a regex that pins how code looks
# is defeated by rewriting it (aliases, `.init`, `[T]` vs `Array<T>`, a conformance
# listed second, a different decoder API). So the rules below pin *names* against
# an inventory instead. Naming a platform image type at all, in any spelling and
# including prose, is confined to the audited files listed here; adding a file to
# this list is the review control point.
platform_image_files="
MarkdownKit/Exports.swift
MarkdownMath/SVGRasterizer.swift
MarkdownPlatformView/ImageResidencyLedger.swift
MarkdownPlatformView/MathLoadCoordinator.swift
MarkdownPlatformView/RenderedResourceLease.swift
MarkdownPlatformView/SVGBlockLoadCoordinator.swift
MarkdownRenderKit/PlatformTypes.swift
MarkdownRenderKit/RenderedImage.swift
MarkdownRenderKit/RenderMaterializer.swift
MarkdownRenderKit/ResolvedResource.swift
"
# <api regex>;<comma-separated files allowed to name it>. Empty means nowhere.
decode_apis="
CGImageSourceCreateThumbnailAtIndex;MarkdownPlatformView/ImageDecoder.swift
CGImageSourceCreateImageAtIndex;MarkdownRenderKit/RenderedImage.swift
CGImageSourceCreate(?:WithData|Incremental);MarkdownPlatformView/ImageDecoder.swift,MarkdownPlatformView/ValidatedImageFactory.swift,MarkdownRenderKit/RenderedImage.swift
CGDataProvider;MarkdownRenderKit/ResolvedResource.swift
NSBitmapImageRep;
CIImage;
CIContext;
UIGraphicsImageRenderer;
UIGraphicsBeginImageContext;
"
# Only these may turn a CGImage into a platform image.
cgimage_files="MarkdownRenderKit/RenderMaterializer.swift MarkdownRenderKit/RenderedImage.swift"
# Only these may declare a residency owner.
owner_inventory="ImageOwnerLease RenderedResourceLease RenderedResourceOwning"

for relative in $platform_image_files $cgimage_files; do
    if [[ ! -f "$source_root/$relative" ]]; then
        echo "FAIL: allowlisted file is missing: $source_root/$relative" >&2
        exit 1
    fi
done

count=0
while IFS= read -r -d '' file; do
    count=$((count + 1))
    relative="${file#"$source_root"/}"
    if ! PLATFORM_FILES="$platform_image_files" DECODE_APIS="$decode_apis" \
         CGIMAGE_FILES="$cgimage_files" OWNERS="$owner_inventory" RELATIVE="$relative" \
         perl -0777 -e '
        use strict; use warnings;
        my $file = $ARGV[0];
        my $relative = $ENV{RELATIVE};
        open(my $handle, "<", $file) or exit 1;
        my $text = do { local $/; <$handle> };
        my %platform_files = map { $_ => 1 } split /\s+/, $ENV{PLATFORM_FILES};
        my %cgimage_files = map { $_ => 1 } split /\s+/, $ENV{CGIMAGE_FILES};
        my %owners = map { $_ => 1 } split /\s+/, $ENV{OWNERS};
        my $platform = qr/(?:UIImage|NSImage|PlatformImage)/;

        # The retention bridge is gone; every image owner is a residency lease.
        exit 1 if $text =~ /\bLegacyResourceOwner\b/s;

        # Naming a platform image type is confined to the audited inventory.
        exit 1 if $text =~ /\b$platform\b/s && !$platform_files{$relative};

        # Each decoding API is confined to the files that may name it.
        for my $rule (split /\n/, $ENV{DECODE_APIS}) {
            next unless length $rule;
            my ($api, $allowed) = split /;/, $rule, 2;
            $allowed = "" unless defined $allowed;
            my %ok = map { $_ => 1 } grep { length } split /,/, $allowed;
            exit 1 if $text =~ /\b(?:$api)\b/s && !$ok{$relative};
        }

        # Bytes, files and Core Image never become a platform image.
        exit 1 if $text =~ /\b$platform\s*(?:\.\s*init\s*)?\(\s*(?:data|ciImage|contentsOf|contentsOfFile)\s*:/s;
        # Only the audited converters wrap an immutable CGImage.
        exit 1 if $text =~ /\b$platform\s*(?:\.\s*init\s*)?\(\s*cgImage\s*:/s && !$cgimage_files{$relative};
        # No *second* name for a platform image type; re-exporting the same name is fine.
        while ($text =~ /\btypealias\s+(\w+)\s*=\s*(?:\w+\s*\.\s*)?$platform\b/gs) {
            exit 1 unless $1 =~ /\A(?:UIImage|NSImage|PlatformImage)\z/;
        }
        # Residency owners are an inventory: the conformance may sit anywhere in an
        # inheritance clause and may span lines.
        while ($text =~ /\b(?:class|struct|enum|actor|protocol|extension)\s+(\w+)\s*:[^{]*?\b(?:ResourceResidencyOwner|RenderedResourceOwning)\b/gs) {
            exit 1 unless $owners{$1};
        }
        exit 0;
    ' "$file"; then
        echo "FAIL: unowned or unbounded image handling: $file" >&2
        exit 1
    fi
done < <(rg --files --hidden --no-ignore -0 -g '*.swift' "$source_root")

if [[ "$count" -eq 0 ]]; then
    echo 'FAIL: empty source inventory' >&2
    exit 1
fi
echo 'PASS: platform images, decoders and residency owners all match their audited inventories'
