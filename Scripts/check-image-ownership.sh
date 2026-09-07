#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_root="${1:-Sources}"
if [[ ! -d "$source_root" ]]; then
    echo "FAIL: source root does not exist: $source_root" >&2
    exit 1
fi

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
CGImageSourceCreateThumbnail;MarkdownPlatformView/ImageDecoder.swift
CGImageSourceCreateImage;MarkdownRenderKit/RenderedImage.swift
CGImageSourceCreateWith;MarkdownPlatformView/ImageDecoder.swift,MarkdownPlatformView/ValidatedImageFactory.swift,MarkdownRenderKit/RenderedImage.swift
CGImageSourceCreateIncremental;MarkdownPlatformView/ValidatedImageFactory.swift
CGDataProvider;MarkdownRenderKit/ResolvedResource.swift
CGContext;MarkdownRenderKit/ResolvedResource.swift,MarkdownRenderKit/RenderedImage.swift,MarkdownMath/SVGRasterizer.swift,MarkdownPlatformView/MarkdownLabelDecorations.swift
CGAnimateImageData;
UIImageReader;
NSImageRep;
NSCustomImageRep;
NSBitmapImageRep;
NSPDFImageRep;
NSEPSImageRep;
NSCIImageRep;
CIImage;
CIContext;
UIGraphicsImageRenderer;
UIGraphicsBeginImageContext;
UIGraphicsGetImageFromCurrentImageContext;
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
        my %platform_files = map { $_ => 1 } grep { length } split /\s+/, $ENV{PLATFORM_FILES};
        my %cgimage_files = map { $_ => 1 } grep { length } split /\s+/, $ENV{CGIMAGE_FILES};
        my %owners = map { $_ => 1 } grep { length } split /\s+/, $ENV{OWNERS};
        my $platform = qr/(?:UIImage|NSImage|PlatformImage)/;
        # Every failure prints the symbol, its line and the inventory it broke, so
        # the reader never has to go and measure anything to know what to do.
        my $line = sub { my $upto = substr($text, 0, $-[0]); 1 + ($upto =~ tr/\n//) };
        my $fail = sub { print STDERR "  $relative:$_[0]: $_[1]\n"; exit 1 };

        # The retention bridge is gone; every image owner is a residency lease.
        if ($text =~ /\bLegacyResourceOwner\b/s) {
            $fail->($line->(), "names LegacyResourceOwner, which no longer exists");
        }

        # Naming a platform image type is confined to the audited inventory.
        if ($text =~ /\b($platform)\b/s && !$platform_files{$relative}) {
            my $count = scalar keys %platform_files;
            $fail->($line->(), "names `$1`, but the platform-image inventory has $count files and this is not one of them");
        }

        # Each decoding API is confined to the files that may name it.
        for my $rule (split /\n/, $ENV{DECODE_APIS}) {
            next unless length $rule;
            my ($api, $allowed) = split /;/, $rule, 2;
            $allowed = "" unless defined $allowed;
            my %ok = map { $_ => 1 } grep { length } split /,/, $allowed;
            # Prefix match: a suffixed sibling is the same capability.
            next unless $text =~ /\b($api\w*)\b/s;
            next if $ok{$relative};
            my $where = %ok ? join(", ", sort keys %ok) : "no file";
            $fail->($line->(), "names `$1`, allowed only in: $where");
        }

        # Bytes, files and Core Image never become a platform image.
        if ($text =~ /\b($platform\s*(?:\.\s*init\s*)?\(\s*(?:data|dataIgnoringOrientation|ciImage|contentsOf|contentsOfFile|byReferencing|byReferencingFile|pasteboard)\s*:)/s) {
            $fail->($line->(), "builds a platform image from bytes or a file: `$1`");
        }
        # Only the audited converters wrap an immutable CGImage.
        if ($text =~ /\b($platform\s*(?:\.\s*init\s*)?\(\s*cgImage\s*:)/s && !$cgimage_files{$relative}) {
            $fail->($line->(), "wraps a CGImage: `$1`, allowed only in: " . join(", ", sort keys %cgimage_files));
        }
        # No *second* name for a platform image type or a residency protocol;
        # re-exporting the same name is fine. Aliasing defeats every rule above.
        while ($text =~ /\btypealias\s+(\w+)\s*=\s*(?:\w+\s*\.\s*)?($platform|ResourceResidencyOwner|RenderedResourceOwning)\b/gs) {
            my ($alias, $target) = ($1, $2);
            # A platform image may keep its own names across modules; anything else
            # is a second name that routes around every rule above.
            next if $target !~ /\A(?:UIImage|NSImage|PlatformImage)\z/ ? 0
                : $alias =~ /\A(?:UIImage|NSImage|PlatformImage)\z/;
            $fail->($line->(), "gives `$target` a second name `$alias`");
        }
        # Residency owners are an inventory. Scanned twice: once raw, once with
        # comments blanked, because a brace inside a comment can end an inheritance
        # clause early while a string literal holding comment markers can make the
        # blanking swallow a real declaration. Neither pass alone is sound; the two
        # together catch both. Blanking preserves newlines so lines stay accurate.
        my $blanked = $text;
        $blanked =~ s{/\*(.*?)\*/}{ my $c = $1; $c =~ tr/\n//cd; $c }gse;
        $blanked =~ s{//[^\n]*}{}g;
        for my $pass ($text, $blanked) {
            while ($pass =~ /\b(?:class|struct|enum|actor|protocol|extension)\s+(\w+)\s*(?:<[^>]*>)?\s*:[^{]*?\b(?:ResourceResidencyOwner|RenderedResourceOwning)\b/gs) {
                next if $owners{$1};
                my $upto = substr($pass, 0, $-[0]);
                my $at = 1 + ($upto =~ tr/\n//);
                print STDERR "  $relative:$at: declares `$1` as a residency owner; the inventory is: " . join(", ", sort keys %owners) . "\n";
                exit 1;
            }
        }
        exit 0;
    ' "$file"; then
        echo "FAIL: unowned or unbounded image handling (reason above)" >&2
        exit 1
    fi
done < <(rg --files --hidden --no-ignore -0 -g '*.swift' "$source_root")

if [[ "$count" -eq 0 ]]; then
    echo 'FAIL: empty source inventory' >&2
    exit 1
fi
echo 'PASS: platform images, decoders and residency owners all match their audited inventories'
