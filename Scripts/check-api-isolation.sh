#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .artifacts/task-2
swift build > .artifacts/task-2/isolation-build.log 2>&1
BUILD_DIR="$(swift build --show-bin-path)"
MODULE_DIR="$BUILD_DIR/Modules"
FIXTURE="Tests/CompileFail/PlatformStateRequiresMainActor.swift"
SEARCH_PATHS=(-I "$MODULE_DIR")
# Load the transitive Clang modules exactly where SwiftPM checked them out.
for module in \
    .build/checkouts/swift-markdown/Sources/CAtomic/include \
    .build/checkouts/swift-cmark/src/include \
    .build/checkouts/swift-cmark/extensions/include; do
    test -f "$module/module.modulemap"
    SEARCH_PATHS+=(-I "$module")
done
COMMON=(-typecheck -swift-version 6 -strict-concurrency=complete "${SEARCH_PATHS[@]}")
swiftc "${COMMON[@]}" -D POSITIVE_ISOLATION "$FIXTURE" > .artifacts/task-2/isolation-positive.log 2>&1
# Discover the public top-level type inventory from the compiled source modules,
# independently of Exports.swift and the hand-maintained client fixture. Include
# actors as well as classes, structs, enums, protocols, and typealiases.
INVENTORY_DIR=".artifacts/task-2/umbrella-inventory"
mkdir -p "$INVENTORY_DIR"
TARGET_TRIPLE="$(swiftc -print-target-info | jq -r '.target.triple')"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
for module in MarkdownCore MarkdownRenderKit MarkdownPlatformView; do
    xcrun swift-symbolgraph-extract -module-name "$module" -target "$TARGET_TRIPLE" -sdk "$SDK_PATH" \
        -minimum-access-level public "${SEARCH_PATHS[@]}" -output-dir "$INVENTORY_DIR" \
        > "$INVENTORY_DIR/$module.log" 2>&1
done
jq -rs '
    [.[] | .symbols[]
      | select(.pathComponents | length == 1)
      | select(.kind.identifier | test("^swift\\.(actor|class|struct|enum|protocol|typealias)$"))
      | .pathComponents[0]] | unique
    | if length == 0 then error("empty public type inventory") else . end
    | "import MarkdownKit\n@MainActor func discoveredUmbrellaTypes() {\n"
      + (map("    _ = " + . + ".self") | join("\n")) + "\n}"
' "$INVENTORY_DIR/MarkdownCore.symbols.json" \
  "$INVENTORY_DIR/MarkdownRenderKit.symbols.json" \
  "$INVENTORY_DIR/MarkdownPlatformView.symbols.json" \
  > "$INVENTORY_DIR/Client.swift"
swiftc "${COMMON[@]}" "$INVENTORY_DIR/Client.swift" > "$INVENTORY_DIR/client.log" 2>&1
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
echo "PASS: MainActor.run and discovered umbrella types compile; synchronous detached access is rejected"
