#!/bin/bash

set -uo pipefail

if (($# != 1)); then
    printf 'usage: %s <artifact-directory>\n' "$0" >&2
    exit 64
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
artifact_dir="$1"
swift_bin="${SWIFT_BIN:-swift}"
swiftformat_bin="${SWIFTFORMAT_BIN:-swiftformat}"
mkdir -p "$artifact_dir" || exit 1
cd "$repo_root" || exit 1

# Every gate runs and every log is produced even when an earlier one fails; the
# script reports which ones failed and exits non-zero once, at the end.
failed=()
run_gate() {
    local name="$1"
    shift
    if ! "$@" 2>&1 | tee "$artifact_dir/$name.log"; then
        failed+=("$name")
    fi
}

run_gate platform-floors Scripts/check-platform-floors.sh
run_gate image-ownership Scripts/check-image-ownership.sh
run_gate link-activation Scripts/check-link-activation.sh
run_gate swift-test "$swift_bin" test
run_gate swift-release "$swift_bin" build -c release -Xswiftc -warnings-as-errors
run_gate swiftformat "$swiftformat_bin" --lint .

if ((${#failed[@]})); then
    # The repository still carries one known SwiftFormat debt file assigned to
    # Task 12, so `swiftformat` alone failing is the expected state today; any
    # other name here, or swiftformat plus another, is new.
    printf 'FAIL: %d gate(s) failed: %s\n' "${#failed[@]}" "${failed[*]}" >&2
    exit 1
fi
echo 'PASS: every static gate succeeded'
