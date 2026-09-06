#!/bin/bash

set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/markdownkit-delivery-gates.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
failures=0

expect_success() {
    local name="$1"
    shift
    if "$@" >"$fixture_root/output.log" 2>&1; then
        printf 'PASS: %s\n' "$name"
    else
        printf 'FAIL: %s (expected success)\n' "$name"
        sed 's/^/  /' "$fixture_root/output.log"
        failures=$((failures + 1))
    fi
}

expect_failure() {
    local name="$1"
    shift
    if "$@" >"$fixture_root/output.log" 2>&1; then
        printf 'FAIL: %s (expected failure)\n' "$name"
        sed 's/^/  /' "$fixture_root/output.log"
        failures=$((failures + 1))
    else
        printf 'PASS: %s\n' "$name"
    fi
}

mkdir -p "$fixture_root/bin"

printf '%s\n' '#!/bin/bash' \
    'printf '\''{"platforms":[{"platformName":"ios","version":"%s"},{"platformName":"macos","version":"%s"}]}\n'\'' "${FAKE_IOS_FLOOR:-18.0}" "${FAKE_MACOS_FLOOR:-15.0}"' \
    >"$fixture_root/bin/swift"
printf '%s\n' '#!/bin/bash' \
    'printf '\''    IPHONEOS_DEPLOYMENT_TARGET = %s\n'\'' "${FAKE_IOS_FLOOR:-18.0}"' \
    'printf '\''    MACOSX_DEPLOYMENT_TARGET = %s\n'\'' "${FAKE_MACOS_FLOOR:-15.0}"' \
    >"$fixture_root/bin/xcodebuild"
printf '%s\n' '#!/bin/bash' \
    'bundle="${@: -1}"' \
    'case "$bundle" in' \
    '  *package*) printf '\''%s\n'\'' '\''{"testNodes":[{"nodeType":"Unit test bundle","name":"MarkdownKitTests","children":[{"nodeType":"Test Case","name":"Parsed blocks include stable source fingerprints","result":"Passed"}]},{"nodeType":"Unit test bundle","name":"MarkdownMathTests","children":[{"nodeType":"Test Case","name":"合法公式 → .rendered，尺寸为正","result":"Passed"}]}]}'\'' ;;' \
    '  *example*) printf '\''%s\n'\'' '\''{"testNodes":[{"nodeType":"Unit test bundle","name":"ExampleTests","children":[{"nodeType":"Test Case","name":"Smoke markdown parses one heading","result":"Passed"}]},{"nodeType":"UI test bundle","name":"ExampleUITests","children":[{"nodeType":"Test Case","name":"testRootDemoIsAccessible()","result":"Passed"}]}]}'\'' ;;' \
    '  *skipped*) printf '\''%s\n'\'' '\''{"testNodes":[{"nodeType":"Unit test bundle","name":"RequiredTarget","children":[{"nodeType":"Test Case","name":"requiredCase","result":"Skipped"}]}]}'\'' ;;' \
    '  *failed*) printf '\''%s\n'\'' '\''{"testNodes":[{"nodeType":"Unit test bundle","name":"RequiredTarget","children":[{"nodeType":"Test Case","name":"requiredCase","result":"Failed"}]}]}'\'' ;;' \
    '  *zero*) printf '\''%s\n'\'' '\''{"testNodes":[{"nodeType":"Unit test bundle","name":"RequiredTarget","children":[]}]}'\'' ;;' \
    '  *) printf '\''%s\n'\'' '\''{"testNodes":[]}'\'' ;;' \
    'esac' >"$fixture_root/bin/xcrun"
chmod +x "$fixture_root/bin/swift" "$fixture_root/bin/xcodebuild" "$fixture_root/bin/xcrun"

printf '%s\n' \
    '{"ios18":{"requiredTargets":["MarkdownKitTests","MarkdownMathTests","ExampleTests","ExampleUITests"],' \
    '"requiredTests":["Parsed blocks include stable source fingerprints","合法公式 → .rendered，尺寸为正",' \
    '"Smoke markdown parses one heading","testRootDemoIsAccessible()"]},' \
    '"failureFixture":{"requiredTargets":["RequiredTarget"],"requiredTests":["requiredCase"]}}' \
    >"$fixture_root/manifest.json"

expect_success "exact platform floors pass" env SWIFT_BIN="$fixture_root/bin/swift" \
    XCODEBUILD_BIN="$fixture_root/bin/xcodebuild" "$repo_root/Scripts/check-platform-floors.sh"
expect_failure "wrong iOS floor fails" env FAKE_IOS_FLOOR=17.0 \
    SWIFT_BIN="$fixture_root/bin/swift" XCODEBUILD_BIN="$fixture_root/bin/xcodebuild" \
    "$repo_root/Scripts/check-platform-floors.sh"
expect_success "tests distributed across bundles pass" env PATH="$fixture_root/bin:$PATH" \
    RUNTIME_TEST_MANIFEST="$fixture_root/manifest.json" \
    "$repo_root/Scripts/assert-xcresult-tests.sh" ios18 package.xcresult example.xcresult
expect_failure "missing required test fails" env PATH="$fixture_root/bin:$PATH" \
    RUNTIME_TEST_MANIFEST="$fixture_root/manifest.json" \
    "$repo_root/Scripts/assert-xcresult-tests.sh" ios18 package.xcresult
expect_failure "skipped test fails" env PATH="$fixture_root/bin:$PATH" \
    RUNTIME_TEST_MANIFEST="$fixture_root/manifest.json" \
    "$repo_root/Scripts/assert-xcresult-tests.sh" failureFixture skipped.xcresult
expect_failure "unexpected failure fails" env PATH="$fixture_root/bin:$PATH" \
    RUNTIME_TEST_MANIFEST="$fixture_root/manifest.json" \
    "$repo_root/Scripts/assert-xcresult-tests.sh" failureFixture failed.xcresult
expect_failure "zero executed tests fails" env PATH="$fixture_root/bin:$PATH" \
    RUNTIME_TEST_MANIFEST="$fixture_root/manifest.json" \
    "$repo_root/Scripts/assert-xcresult-tests.sh" failureFixture zero.xcresult

if ((failures > 0)); then
    printf '%d delivery gate test(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'All delivery gate tests passed.\n'
