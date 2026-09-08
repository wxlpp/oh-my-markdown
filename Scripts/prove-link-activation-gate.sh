#!/usr/bin/env bash
# Each probe drops a file into a fixture Sources tree; the gate must fail (or
# pass, for controls). Prefix a body with FILE:<name>@@ to write it into that
# inventoried file instead of a fresh one.
set -uo pipefail
root="$1"; gate="$PWD/Scripts/check-link-activation.sh"
# This script rm -rf's $root on every probe. Refuse anything that is not a
# disposable path under the scratchpad: passing a repository here destroys it.
case "$root" in
    /private/tmp/claude-501/*|/tmp/claude-501/*) ;;
    *) echo "refusing to use '$root' as a fixture root: must be under the scratchpad" >&2; exit 64 ;;
esac
if [[ -e "$root" && ! -f "$root/.probe-fixture" ]]; then
    echo "refusing to reuse '$root': not a probe fixture created by this script" >&2; exit 64
fi
mkdir -p "$root" && touch "$root/.probe-fixture"
verified=0; unexpected=0
probe() {
    local name="$1" expect="$2" body="$3" target
    rm -rf "$root"; mkdir -p "$root/MarkdownPlatformView" "$root/MarkdownCore"; touch "$root/.probe-fixture"
    printf 'let auditedHandler = 0\n' > "$root/MarkdownPlatformView/MarkdownLinkPolicy.swift"
    printf 'let editor = 0\n' > "$root/MarkdownPlatformView/MarkdownEditorTextView.swift"
    printf 'let parser = 0\n' > "$root/MarkdownCore/DocumentParser.swift"
    if [[ "$body" == FILE:* ]]; then
        target="${body#FILE:}"; target="${target%%@@*}"
        printf '%s\n' "${body#*@@}" > "$root/MarkdownPlatformView/$target"
    else
        printf '%s\n' "$body" > "$root/MarkdownPlatformView/Probe.swift"
    fi
    if "$gate" "$root" >/dev/null 2>&1; then got=pass; else got=fail; fi
    if [[ "$got" == "$expect" ]]; then verified=$((verified+1)); printf '  ok   %-46s (%s)\n' "$name" "$got"
    else unexpected=$((unexpected+1)); printf '  LEAK %-46s (expected %s, got %s)\n' "$name" "$expect" "$got"; fi
}

echo "== families the gate already claimed to catch =="
probe "UIApplication.shared.open"            fail 'func f(u: URL) { UIApplication.shared.open(u) }'
probe "NSWorkspace.shared.open"              fail 'func f(u: URL) { NSWorkspace.shared.open(u) }'
probe "typealias alias of an opener"         fail 'typealias Opener = UIApplication'
echo "== round-2 families =="
probe "internal import SwiftUI + Link"       fail 'internal import SwiftUI
let v = Link("t", destination: u)'
probe "@preconcurrency import + Link"        fail '@preconcurrency import SwiftUI
let v = Link("t", destination: u)'
probe "UIWindowScene.open"                   fail 'func f(s: UIWindowScene, u: URL) { s.open(u, options: nil) }'
probe "UIScene via delegate"                 fail 'func f(s: UIScene) { _ = s }'
echo "== round-3 families =="
probe "NSTextField + .link attributed"       fail 'let f = NSTextField(labelWithAttributedString: s)'
probe "SwiftUI Text with .link run"          fail 'var body: some View { Text(attributed) }'
probe "Process + /usr/bin/open"              fail 'let p = Process()'
probe "posix_spawn"                          fail 'func f() { _ = posix_spawn(&pid, "/usr/bin/open", nil, nil, a, e) }'
probe "UIDocumentInteractionController"      fail 'let c = UIDocumentInteractionController(url: u)'
probe "UIActivityViewController"             fail 'let c = UIActivityViewController(activityItems: [u], applicationActivities: nil)'
probe "SFAuthenticationSession"              fail 'let s = SFAuthenticationSession(url: u, callbackURLScheme: nil) { _, _ in }'
probe "NSSharingService"                     fail 'NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [u])'
probe "NSSharingServicePicker"               fail 'let p = NSSharingServicePicker(items: [u])'
probe "NSTask (pre-rename Process)"          fail 'let t = NSTask()'
echo "== round-4 families =="
probe "NSAppleScript open location"          fail 'let s = NSAppleScript(source: script)'
probe "NSDocumentController"                 fail 'NSDocumentController.shared.openDocument(withContentsOf: u, display: true) { _, _, _ in }'
probe "NSHelpManager"                        fail 'NSHelpManager.shared.openHelpAnchor("a", inBook: nil)'
probe "_LSOpenURLsWithRole (underscore)"     fail 'func f() { _ = _LSOpenURLsWithRole(urls, role, nil, nil, nil, 0) }'
probe "SKStoreProductViewController"         fail 'let c = SKStoreProductViewController()'
probe "MFMailComposeViewController"          fail 'let c = MFMailComposeViewController()'
probe "dataDetectorTypes in exempt editor"   fail 'FILE:MarkdownEditorTextView.swift@@self.dataDetectorTypes = .link'
echo "== round-5 families =="
probe "popen(\"open …\")"                      fail 'let f = popen("open https://evil.test", "r")'
probe "ShareLink(item:)"                     fail 'var body: some View { ShareLink(item: u) }'
probe "TextEditor bound to AttributedString" fail 'var body: some View { TextEditor(text: $attributed) }'
probe "TextField bound to AttributedString"  fail 'var body: some View { TextField("x", text: $attributed) }'
probe "NSAppleEventDescriptor"               fail 'let d = NSAppleScript(source: s)'
probe "isAutomaticLinkDetection in editor"   fail 'FILE:MarkdownEditorTextView.swift@@self.textView.dataDetectorTypes = .link'
echo "== negative controls (must pass) =="
probe "prose naming an opener in a comment"  pass '// Deliberately avoids UIApplication.shared.open and NSTextField.
let x = 1'
probe "opener name inside a string literal"  pass 'let note = "we do not call UIApplication.shared.open here"'
probe "MarkdownText / linkConfiguration"     pass 'struct MarkdownText { var linkConfiguration: Int = 0 }'
probe "ProcessInfo is not Process"           pass 'let n = ProcessInfo.processInfo.processorCount'
probe "editor defensive disable assignment"  pass 'FILE:MarkdownEditorTextView.swift@@allowsEditingTextAttributes = false'
probe "UITextView inside the exempt editor"  pass 'FILE:MarkdownEditorTextView.swift@@final class E: UITextView {}'
printf '\nverified: %d, unexpected: %d\n' "$verified" "$unexpected"
[[ "$unexpected" -eq 0 ]]
