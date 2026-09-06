#!/bin/bash

set -euo pipefail

if (($# < 2)); then
    printf 'usage: %s <manifest-section> <xcresult> [xcresult ...]\n' "$0" >&2
    exit 64
fi

section="$1"
shift
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
manifest="${RUNTIME_TEST_MANIFEST:-$repo_root/Tests/runtime-test-manifest.json}"
artifacts_root="${HARDENING_ARTIFACTS_DIR:-$repo_root/.artifacts}"
mkdir -p "$artifacts_root"
report_dir="$(mktemp -d "$artifacts_root/xcresult-assert.XXXXXX")"

reports=()
bundle_index=0
for bundle in "$@"; do
    report="$report_dir/result-$bundle_index.json"
    xcrun xcresulttool get test-results tests --compact --path "$bundle" >"$report"
    reports+=("$report")
    bundle_index=$((bundle_index + 1))
done

python3 - "$manifest" "$section" "${reports[@]}" <<'PY'
import json
import sys
from pathlib import Path

manifest_path, section, *report_paths = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as stream:
    manifest = json.load(stream)
if section not in manifest:
    raise SystemExit(f"Unknown runtime manifest section: {section}")

nodes = []
def visit(node):
    if isinstance(node, dict):
        if "nodeType" in node and "name" in node:
            nodes.append(node)
        for value in node.values():
            visit(value)
    elif isinstance(node, list):
        for value in node:
            visit(value)

for report_path in report_paths:
    with open(report_path, encoding="utf-8") as stream:
        visit(json.load(stream))

bundle_types = {"Unit test bundle", "UI test bundle"}
targets = sorted({node["name"].removesuffix(".xctest") for node in nodes if node["nodeType"] in bundle_types})
case_nodes = [node for node in nodes if node["nodeType"] == "Test Case"]
cases = sorted({node["name"] for node in case_nodes})
results = [node.get("result") for node in case_nodes]
executed = len(case_nodes)
passed = sum(result == "Passed" for result in results)
skipped = sum(result == "Skipped" for result in results)
failed = sum(result in {"Failed", "unknown", None} for result in results)
expected_failures = sum(result == "Expected Failure" for result in results)

required = manifest[section]
missing_targets = sorted(set(required["requiredTargets"]) - set(targets))
missing_cases = sorted(set(required["requiredTests"]) - set(cases))

print(f"section={section}")
print(f"executed={executed} passed={passed} skipped={skipped} failed={failed} expected_failures={expected_failures}")
print("targets=" + (", ".join(targets) or "<none>"))
print("tests=" + (", ".join(cases) or "<none>"))
print("reports=" + ", ".join(str(Path(path)) for path in report_paths))

errors = []
if executed == 0:
    errors.append("zero tests executed")
if missing_targets:
    errors.append("missing required targets: " + ", ".join(missing_targets))
if missing_cases:
    errors.append("missing required tests: " + ", ".join(missing_cases))
if skipped:
    errors.append(f"{skipped} skipped test result(s)")
if failed:
    errors.append(f"{failed} unexpected failed/unknown test result(s)")
if errors:
    raise SystemExit("xcresult assertion failed: " + "; ".join(errors))
PY

printf 'xcresult evidence: %s\n' "$report_dir"
