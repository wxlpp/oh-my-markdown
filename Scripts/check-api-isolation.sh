#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .artifacts/task-2
swift build > .artifacts/task-2/isolation-build.log 2>&1
BUILD_DIR="$(swift build --show-bin-path)"
MODULE_DIR="$BUILD_DIR/Modules"
FIXTURE="Tests/CompileFail/PlatformStateRequiresMainActor.swift"
COMMON=(-typecheck -swift-version 6 -strict-concurrency=complete -I "$MODULE_DIR")
# Load the transitive Clang modules exactly where SwiftPM checked them out.
for module in \
    .build/checkouts/swift-markdown/Sources/CAtomic/include \
    .build/checkouts/swift-cmark/src/include \
    .build/checkouts/swift-cmark/extensions/include; do
    test -f "$module/module.modulemap"
    COMMON+=(-I "$module")
done
swiftc "${COMMON[@]}" -D POSITIVE_ISOLATION "$FIXTURE" > .artifacts/task-2/isolation-positive.log 2>&1
swiftc "${COMMON[@]}" -D POSITIVE_ISOLATION -D UMBRELLA_CLIENT "$FIXTURE" > .artifacts/task-2/umbrella-client.log 2>&1
if swiftc "${COMMON[@]}" "$FIXTURE" > .artifacts/task-2/isolation-negative.log 2>&1; then
    echo "FAIL: synchronous detached access to platform state unexpectedly compiled" >&2
    exit 1
fi
if ! rg -q "main actor-isolated.*attributedString|attributedString.*main actor-isolated" .artifacts/task-2/isolation-negative.log; then
    echo "FAIL: negative fixture failed without the expected isolation diagnostic" >&2
    cat .artifacts/task-2/isolation-negative.log >&2
    exit 1
fi
echo "PASS: MainActor.run access compiles; synchronous detached access is rejected"
