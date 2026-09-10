#!/bin/bash

set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/oh-my-markdown-delivery-gates.XXXXXX")"
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
    'printf '\''%s\n'\'' "$*" >> "${FAKE_COMMAND_LOG:-/dev/null}"' \
    'if [[ "$*" == *"package dump-package"* ]]; then' \
    '  printf '\''{"platforms":[{"platformName":"ios","version":"%s"},{"platformName":"macos","version":"%s"}]}\n'\'' "${FAKE_IOS_FLOOR:-18.0}" "${FAKE_MACOS_FLOOR:-15.0}"' \
    'elif [[ "$*" == "--version" ]]; then' \
    '  printf '\''Apple Swift version %s\n'\'' "${FAKE_SWIFT_VERSION:-6.2}"' \
    'fi' \
    >"$fixture_root/bin/swift"
printf '%s\n' '#!/bin/bash' \
    'printf '\''%s\n'\'' "$*" >> "${FAKE_COMMAND_LOG:-/dev/null}"' \
    'if [[ "$*" == "-version" ]]; then printf '\''Xcode %s\nBuild version TEST\n'\'' "${FAKE_XCODE_VERSION:-26.0}"; exit 0; fi' \
    'ios="${FAKE_IOS_FLOOR:-18.0}"' \
    'if [[ " $* " == *" -target ExampleTests "* && " $* " == *" -configuration Release "* ]]; then ios="${FAKE_DRIFT_IOS_FLOOR:-$ios}"; fi' \
    'printf '\''    IPHONEOS_DEPLOYMENT_TARGET = %s\n'\'' "$ios"' \
    'printf '\''    MACOSX_DEPLOYMENT_TARGET = %s\n'\'' "${FAKE_MACOS_FLOOR:-15.0}"' \
    >"$fixture_root/bin/xcodebuild"
printf '%s\n' '#!/bin/bash' \
    'printf '\''%s\n'\'' "$*" >> "${FAKE_COMMAND_LOG:-/dev/null}"' \
    >"$fixture_root/bin/swiftformat"
printf '%s\n' '#!/bin/bash' \
    'if [[ "$1" == "simctl" ]]; then' \
    '  if [[ "$*" == *"runtimes"* ]]; then printf '\''iOS %s (fixture)\n'\'' "${FAKE_SIM_RUNTIME:-18.0}"; exit 0; fi' \
    '  printf '\''%s\n'\'' '\''-- iOS 18.0 --'\''' \
    '  if [[ "${FAKE_DEVICE_AVAILABLE:-1}" == 1 ]]; then printf '\''    iPhone 16 Pro (FIXTURE) (Shutdown)\n'\''; fi' \
    '  exit 0' \
    'fi' \
    'bundle="${@: -1}"' \
    'case "$bundle" in' \
    '  *package*) printf '\''%s\n'\'' '\''{"testNodes":[{"nodeType":"Unit test bundle","name":"OhMyMarkdownTests","children":[{"nodeType":"Test Case","name":"Parsed blocks include stable source fingerprints","result":"Passed"}]},{"nodeType":"Unit test bundle","name":"MarkdownMathTests","children":[{"nodeType":"Test Case","name":"合法公式 → .rendered，尺寸为正","result":"Passed"}]}]}'\'' ;;' \
    '  *example*) printf '\''%s\n'\'' '\''{"testNodes":[{"nodeType":"Unit test bundle","name":"ExampleTests","children":[{"nodeType":"Test Case","name":"Smoke markdown parses one heading","result":"Passed"}]},{"nodeType":"UI test bundle","name":"ExampleUITests","children":[{"nodeType":"Test Case","name":"testRootDemoIsAccessible()","result":"Passed"}]}]}'\'' ;;' \
    '  *suite-failed*) printf '\''%s\n'\'' '\''{"testNodes":[{"nodeType":"Unit test bundle","name":"RequiredTarget","result":"Passed","children":[{"nodeType":"Test Suite","name":"RequiredSuite","result":"Failed","children":[{"nodeType":"Test Case","name":"requiredCase","result":"Passed"}]}]}]}'\'' ;;' \
    '  *suite-missing*) printf '\''%s\n'\'' '\''{"testNodes":[{"nodeType":"Unit test bundle","name":"RequiredTarget","result":"Passed","children":[{"nodeType":"Test Suite","name":"RequiredSuite","result":null,"children":[{"nodeType":"Test Case","name":"requiredCase","result":"Passed"}]}]}]}'\'' ;;' \
    '  *bundle-skipped*) printf '\''%s\n'\'' '\''{"testNodes":[{"nodeType":"Unit test bundle","name":"RequiredTarget","result":"Skipped","children":[{"nodeType":"Test Case","name":"requiredCase","result":"Passed"}]}]}'\'' ;;' \
    '  *skipped*) printf '\''%s\n'\'' '\''{"testNodes":[{"nodeType":"Unit test bundle","name":"RequiredTarget","children":[{"nodeType":"Test Case","name":"requiredCase","result":"Skipped"}]}]}'\'' ;;' \
    '  *failed*) printf '\''%s\n'\'' '\''{"testNodes":[{"nodeType":"Unit test bundle","name":"RequiredTarget","children":[{"nodeType":"Test Case","name":"requiredCase","result":"Failed"}]}]}'\'' ;;' \
    '  *zero*) printf '\''%s\n'\'' '\''{"testNodes":[{"nodeType":"Unit test bundle","name":"RequiredTarget","children":[]}]}'\'' ;;' \
    '  *) printf '\''%s\n'\'' '\''{"testNodes":[]}'\'' ;;' \
    'esac' >"$fixture_root/bin/xcrun"
printf '%s\n' '#!/bin/bash' \
    'printf '\''%s\n'\'' "${FAKE_HOST_OS:-15.0}"' \
    >"$fixture_root/bin/sw_vers"
chmod +x "$fixture_root/bin/swift" "$fixture_root/bin/xcodebuild" "$fixture_root/bin/xcrun" \
    "$fixture_root/bin/swiftformat" "$fixture_root/bin/sw_vers"

printf '%s\n' \
    '{"ios18":{"requiredTargets":["OhMyMarkdownTests","MarkdownMathTests","ExampleTests","ExampleUITests"],' \
    '"requiredTests":["Parsed blocks include stable source fingerprints","合法公式 → .rendered，尺寸为正",' \
    '"Smoke markdown parses one heading","testRootDemoIsAccessible()"]},' \
    '"failureFixture":{"requiredTargets":["RequiredTarget"],"requiredTests":["requiredCase"]}}' \
    >"$fixture_root/manifest.json"

expect_success "exact platform floors pass" env SWIFT_BIN="$fixture_root/bin/swift" \
    XCODEBUILD_BIN="$fixture_root/bin/xcodebuild" "$repo_root/Scripts/check-platform-floors.sh"
expect_failure "wrong iOS floor fails" env FAKE_IOS_FLOOR=17.0 \
    SWIFT_BIN="$fixture_root/bin/swift" XCODEBUILD_BIN="$fixture_root/bin/xcodebuild" \
    "$repo_root/Scripts/check-platform-floors.sh"
expect_failure "wrong macOS floor fails" env FAKE_MACOS_FLOOR=14.0 \
    SWIFT_BIN="$fixture_root/bin/swift" XCODEBUILD_BIN="$fixture_root/bin/xcodebuild" \
    "$repo_root/Scripts/check-platform-floors.sh"
expect_failure "one target configuration drift fails" env FAKE_DRIFT_IOS_FLOOR=17.0 \
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
expect_failure "suite-level failure fails" env PATH="$fixture_root/bin:$PATH" \
    RUNTIME_TEST_MANIFEST="$fixture_root/manifest.json" \
    "$repo_root/Scripts/assert-xcresult-tests.sh" failureFixture suite-failed.xcresult
expect_failure "suite-level missing status fails" env PATH="$fixture_root/bin:$PATH" \
    RUNTIME_TEST_MANIFEST="$fixture_root/manifest.json" \
    "$repo_root/Scripts/assert-xcresult-tests.sh" failureFixture suite-missing.xcresult
expect_failure "bundle-level skip fails" env PATH="$fixture_root/bin:$PATH" \
    RUNTIME_TEST_MANIFEST="$fixture_root/manifest.json" \
    "$repo_root/Scripts/assert-xcresult-tests.sh" failureFixture bundle-skipped.xcresult
expect_failure "zero executed tests fails" env PATH="$fixture_root/bin:$PATH" \
    RUNTIME_TEST_MANIFEST="$fixture_root/manifest.json" \
    "$repo_root/Scripts/assert-xcresult-tests.sh" failureFixture zero.xcresult

expect_success "iOS runtime environment requires exact runtime and device" env PATH="$fixture_root/bin:$PATH" \
    "$repo_root/Scripts/check-runtime-environment.sh" ios18
expect_failure "iOS runtime environment fails without exact device" env PATH="$fixture_root/bin:$PATH" \
    FAKE_DEVICE_AVAILABLE=0 "$repo_root/Scripts/check-runtime-environment.sh" ios18
expect_success "macOS runtime environment accepts macOS 15" env PATH="$fixture_root/bin:$PATH" \
    "$repo_root/Scripts/check-runtime-environment.sh" macos15
expect_failure "macOS runtime environment rejects another host" env PATH="$fixture_root/bin:$PATH" \
    FAKE_HOST_OS=26.0 "$repo_root/Scripts/check-runtime-environment.sh" macos15

metadata="$fixture_root/runtime-metadata.txt"
expect_success "runtime metadata writer emits evidence" env PATH="$fixture_root/bin:$PATH" \
    GITHUB_SHA=fixture-sha "$repo_root/Scripts/write-runtime-metadata.sh" ios18 passed "$metadata"
expect_success "runtime metadata contains exactly seven fields" python3 - "$metadata" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
keys = [line.partition("=")[0] for line in lines]
expected = ["host_os", "xcode_version", "swift_version", "simulator_runtime", "scheme", "git_sha", "result"]
if keys != expected:
    raise SystemExit(f"expected {expected}, observed {keys}")
PY

command_log="$fixture_root/commands.log"
expect_success "static gate runs format, tests, and warnings-as-errors release build" env \
    PATH="$fixture_root/bin:$PATH" FAKE_COMMAND_LOG="$command_log" \
    SWIFT_BIN="$fixture_root/bin/swift" XCODEBUILD_BIN="$fixture_root/bin/xcodebuild" \
    "$repo_root/Scripts/run-static-gates.sh" "$fixture_root/static-artifacts"
expect_success "static gate invoked required commands" python3 - "$command_log" <<'PY'
import sys

commands = open(sys.argv[1], encoding="utf-8").read().splitlines()
required = ["--lint .", "test", "build -c release -Xswiftc -warnings-as-errors"]
missing = [command for command in required if command not in commands]
if missing:
    raise SystemExit("missing commands: " + ", ".join(missing))
PY

if ((failures > 0)); then
    printf '%d delivery gate test(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'All delivery gate tests passed.\n'
