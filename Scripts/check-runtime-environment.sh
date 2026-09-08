#!/bin/bash

set -euo pipefail

if (($# != 1)); then
    printf 'usage: %s <ios18|macos15>\n' "$0" >&2
    exit 64
fi

section="$1"
# A minimum, not an exact version: `Package.swift` declares tools 6.2, and
# pinning the toolchain to exactly 6.2 made the gate fail on the Xcode 26.4
# toolchain the package is developed with (Swift 6.3). The release evidence
# records the toolchain a given run actually used.
swift --version | grep -E 'Apple Swift version 6\.([2-9]|[1-9][0-9])([ .]|$)'
xcodebuild -version | head -1 | grep -E '^Xcode 26([.]|$)'

case "$section" in
    ios18)
        xcrun simctl list runtimes available | grep -E '^iOS 18\.0 '
        xcrun simctl list devices available | awk '
            /^-- iOS 18\.0 --$/ { in_runtime = 1; next }
            /^-- / { in_runtime = 0 }
            in_runtime && /^    iPhone 16 Pro \(/ { found = 1 }
            END { exit !found }
        '
        printf 'Runtime environment: iOS 18.0 on iPhone 16 Pro\n'
        ;;
    macos15)
        sw_vers -productVersion | grep -E '^15\.'
        printf 'Runtime environment: macOS %s\n' "$(sw_vers -productVersion)"
        ;;
    *)
        printf 'unknown runtime environment: %s\n' "$section" >&2
        exit 64
        ;;
esac
