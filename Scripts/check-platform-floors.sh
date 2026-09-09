#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
swift_bin="${SWIFT_BIN:-swift}"
xcodebuild_bin="${XCODEBUILD_BIN:-xcodebuild}"
expected_ios="18.0"
expected_macos="15.0"

package_json="$("$swift_bin" package dump-package --package-path "$repo_root")"
python3 - "$expected_ios" "$expected_macos" "$package_json" <<'PY'
import json
import sys

expected = {"ios": sys.argv[1], "macos": sys.argv[2]}
actual = {item["platformName"].lower(): item["version"] for item in json.loads(sys.argv[3])["platforms"]}
for platform, floor in expected.items():
    observed = actual.get(platform)
    if observed != floor:
        raise SystemExit(f"Package.swift {platform} floor: expected {floor}, observed {observed!r}")
print(f"Package floors: iOS {actual['ios']}, macOS {actual['macos']}")
PY

read_setting() {
    local settings="$1"
    local key="$2"
    awk -v key="$key" '$1 == key && $2 == "=" { value = $3 } END { print value }' <<<"$settings"
}

for target in Example ExampleTests ExampleUITests; do
    for configuration in Debug Release; do
        settings="$("$xcodebuild_bin" -project "$repo_root/Example/Example.xcodeproj" \
            -target "$target" -configuration "$configuration" -sdk iphonesimulator -showBuildSettings)"
        observed_ios="$(read_setting "$settings" IPHONEOS_DEPLOYMENT_TARGET)"
        observed_macos="$(read_setting "$settings" MACOSX_DEPLOYMENT_TARGET)"
        if [[ "$observed_ios" != "$expected_ios" || "$observed_macos" != "$expected_macos" ]]; then
            printf '%s %s floors: expected iOS %s/macOS %s, observed iOS %s/macOS %s\n' \
                "$target" "$configuration" "$expected_ios" "$expected_macos" \
                "${observed_ios:-missing}" "${observed_macos:-missing}" >&2
            exit 1
        fi
        printf '%s %s floors: iOS %s, macOS %s\n' \
            "$target" "$configuration" "$observed_ios" "$observed_macos"
    done
done

printf 'All platform floors match.\n'
