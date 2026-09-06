#!/bin/bash

set -euo pipefail

if (($# != 1)); then
    printf 'usage: %s <artifact-directory>\n' "$0" >&2
    exit 64
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
artifact_dir="$1"
swift_bin="${SWIFT_BIN:-swift}"
swiftformat_bin="${SWIFTFORMAT_BIN:-swiftformat}"
mkdir -p "$artifact_dir"
cd "$repo_root"

"$swiftformat_bin" --lint . 2>&1 | tee "$artifact_dir/swiftformat.log"
Scripts/check-platform-floors.sh 2>&1 | tee "$artifact_dir/platform-floors.log"
"$swift_bin" test 2>&1 | tee "$artifact_dir/swift-test.log"
"$swift_bin" build -c release -Xswiftc -warnings-as-errors 2>&1 \
    | tee "$artifact_dir/swift-release.log"
