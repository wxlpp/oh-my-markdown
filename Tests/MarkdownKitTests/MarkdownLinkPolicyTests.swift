import Foundation
import MarkdownCore
import MarkdownKit
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import SwiftUI
import Testing

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Records activations without touching any platform opener.
@MainActor final class RecordingLinkHandler: MarkdownLinkHandler {
    private(set) var opened: [URL] = []
    func open(_ url: URL) {
        self.opened.append(url)
    }
}

/// Blocks inside the pure decision so a test can replace the configuration while
/// the evaluation is in flight. This is what the protocol tells hosts not to do;
/// it is confined to this suite, which needs the window held open deliberately.
struct GatedLinkPolicy: MarkdownLinkPolicy {
    let gate = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)
    func disposition(for request: MarkdownLinkRequest) -> MarkdownLinkDisposition {
        self.entered.signal()
        _ = self.gate.wait(timeout: .now() + 10)
        return .allow(request.url)
    }

    /// Synchronous by design: `DispatchSemaphore.wait` is unavailable directly
    /// from an async context, and the point is to block a background thread.
    func waitUntilEntered() -> Bool {
        self.entered.wait(timeout: .now() + 10) == .success
    }
}

/// The most likely real-world shape: same type, different stored trust set.
struct AllowListPolicy: MarkdownLinkPolicy {
    let hosts: Set<String>
    func disposition(for request: MarkdownLinkRequest) -> MarkdownLinkDisposition {
        guard let host = request.url.host(), self.hosts.contains(host) else { return .reject }
        return .allow(request.url)
    }
}

struct AllowEverythingPolicy: MarkdownLinkPolicy {
    func disposition(for request: MarkdownLinkRequest) -> MarkdownLinkDisposition {
        .allow(request.url)
    }
}

@Suite(.serialized)
struct MarkdownLinkPolicyTests {
    private func request(_ string: String, generation: UInt64 = 0) throws -> MarkdownLinkRequest {
        try MarkdownLinkRequest(url: #require(URL(string: string)), configurationGeneration: generation)
    }

    @Test func defaultPolicyAllowsOnlyWebSchemes() throws {
        let policy = WebOnlyMarkdownLinkPolicy.default
        for allowed in ["https://example.com/a", "http://example.com/b", "HTTPS://EXAMPLE.com/c"] {
            let url = try #require(URL(string: allowed))
            #expect(try policy.disposition(for: self.request(allowed)) == .allow(url))
        }
        for rejected in [
            "mailto:someone@example.com", "file:///etc/passwd", "javascript:alert(1)",
            "ftp://example.com", "data:text/html,<b>x</b>", "myapp://open",
        ] {
            #expect(try policy.disposition(for: self.request(rejected)) == .reject)
        }
    }

    @Test func policyEvaluationIsPureAndRunsOffTheMainActor() async throws {
        // The protocol is Sendable and the decision touches no platform state, so
        // it must be callable from a non-isolated context.
        let policy = WebOnlyMarkdownLinkPolicy.default
        let request = try self.request("https://example.com/off-main")
        let decided = await Task.detached { policy.disposition(for: request) }.value
        #expect(decided == .allow(request.url))
    }

    @Test @MainActor func configurationIdentitiesAreWrapperOwnedAndCollisionFree() {
        let policy = AllowEverythingPolicy()
        let handler = RecordingLinkHandler()
        let first = MarkdownLinkConfiguration(policy: policy, handler: handler)
        let second = MarkdownLinkConfiguration(policy: policy, handler: handler)
        // Two wrappers over the same instances stay distinct by default.
        #expect(first.policyID != second.policyID)
        #expect(first.handlerID != second.handlerID)

        let shared = MarkdownConfigurationID.semantic(namespace: "host.link", version: 1)
        #expect(
            MarkdownLinkConfiguration(policy: policy, handler: handler, policyID: shared).policyID
                == MarkdownLinkConfiguration(policy: policy, handler: handler, policyID: shared).policyID
        )

        // The built-in policy has a deterministic identity; a custom handler does not.
        let web = MarkdownLinkConfiguration.webOnly(handler: handler)
        #expect(web.policyID == MarkdownLinkConfiguration.webOnly(handler: handler).policyID)
        #expect(web.handlerID != MarkdownLinkConfiguration.webOnly(handler: handler).handlerID)
    }

    @Test @MainActor func activationRunsOnTheMainActorForAllowedSchemesOnly() async throws {
        let handler = RecordingLinkHandler()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        view.linkConfiguration = MarkdownLinkConfiguration.webOnly(handler: handler)
        view.setMarkdown("[web](https://example.com/ok) and [mail](mailto:x@example.com)")
        #expect(await eventually { view.currentSnapshot != nil })

        #expect(view.activateLink(at: 0))
        #expect(await eventually { handler.opened.count == 1 })
        #expect(handler.opened.first?.absoluteString == "https://example.com/ok")

        let rendered = try #require(view.currentSnapshot).attributedString.string
        let mailStart = try #require(rendered.range(of: "mail")).lowerBound
        let offset = rendered.distance(from: rendered.startIndex, to: mailStart)
        #expect(view.activateLink(at: offset))
        for _ in 0 ..< 200 {
            await Task.yield()
        }
        #expect(handler.opened.count == 1)
    }

    @Test @MainActor func invalidDestinationsAreReadableTextAndCannotActivate() async {
        let handler = RecordingLinkHandler()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        view.linkConfiguration = MarkdownLinkConfiguration(policy: AllowEverythingPolicy(), handler: handler)
        view.setMarkdown("[broken](http://[invalid)")
        #expect(await eventually { view.currentSnapshot?.attributedString.string.contains("broken") == true })
        let text = view.currentSnapshot?.attributedString
        #expect(text?.attribute(.link, at: 0, effectiveRange: nil) == nil)
        #expect(!view.activateLink(at: 0))
        for _ in 0 ..< 200 {
            await Task.yield()
        }
        #expect(handler.opened.isEmpty)
    }

    @Test @MainActor func replacementDuringEvaluationPreventsTheOldDecisionFromActivating() async {
        let gated = GatedLinkPolicy()
        let stale = RecordingLinkHandler()
        let current = RecordingLinkHandler()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        view.linkConfiguration = MarkdownLinkConfiguration(policy: gated, handler: stale)
        view.setMarkdown("[web](https://example.com/stale)")
        #expect(await eventually { view.currentSnapshot != nil })

        #expect(view.activateLink(at: 0))
        // The decision is in flight, off the main actor.
        #expect(await Task.detached { gated.waitUntilEntered() }.value)
        view.linkConfiguration = MarkdownLinkConfiguration(policy: WebOnlyMarkdownLinkPolicy.default, handler: current)
        gated.gate.signal()
        for _ in 0 ..< 500 {
            await Task.yield()
        }
        #expect(stale.opened.isEmpty)
        #expect(current.opened.isEmpty)
    }

    /// The same requirement as `tighteningAStatefulPolicyReachesTheDriverAndIsEnforced`,
    /// one layer up. Every documented entry point is the modifier, so a guard in
    /// the representable that suppresses propagation on equal identities keeps the
    /// old policy deciding no matter what the driver and the view do. Both views
    /// carry that forward independently, and streaming updates far more often.
    @Test(arguments: [false, true]) @MainActor
    func tighteningAStatefulPolicyThroughTheModifierIsEnforced(streaming: Bool) async throws {
        let handler = RecordingLinkHandler()
        let source = "[a](https://evil.test/x)"
        let streamingSource = MarkdownStreamingSource(source)
        func content(allowing hosts: Set<String>) -> some View {
            Group {
                if streaming { MarkdownStreamingText(streamingSource) } else { MarkdownText(source) }
            }
            .markdownLinkPolicy(AllowListPolicy(hosts: hosts), handler: handler)
        }
        #if canImport(UIKit)
        let host = UIHostingController(rootView: content(allowing: ["evil.test", "good.test"]))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        #else
        let host = NSHostingView(rootView: content(allowing: ["evil.test", "good.test"]))
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        host.layoutSubtreeIfNeeded()
        #endif
        let label = try #require(await settleForLabel(in: host))
        #expect(await eventually { label.currentSnapshot != nil })

        // What a host actually writes: the allow list is view state, so tightening
        // it re-evaluates the body with the same policy type and the same handler.
        host.rootView = content(allowing: ["good.test"])
        #if canImport(UIKit)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #else
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        #endif
        let driver = try #require(label.sessionDriver)
        #expect(await eventually { (driver.linkConfiguration.policy as? AllowListPolicy)?.hosts == ["good.test"] })

        #expect(label.activateLink(at: 0))
        for _ in 0 ..< 300 {
            await Task.yield()
        }
        #expect(handler.opened.isEmpty, "the revoked host was opened through the modifier")
        withExtendedLifetime(host) {}
    }

    /// Revoking the configuration is the third shape of the same fail-open:
    /// tightening a policy, replacing it, and taking it away entirely must all
    /// reach the view. The environment entry is public and optional, so a host
    /// can write `trusted ? config : nil` against one stable view identity.
    @Test @MainActor func clearingTheConfigurationRevertsTheViewToTheWebOnlyDefault() async throws {
        let handler = RecordingLinkHandler()
        func content(installing configuration: MarkdownLinkConfiguration?) -> some View {
            MarkdownText("[a](myapp://open)")
                .environment(\.markdownLinkConfiguration, configuration)
        }
        let permissive = MarkdownLinkConfiguration(policy: AllowEverythingPolicy(), handler: handler)
        #if canImport(UIKit)
        let host = UIHostingController(rootView: content(installing: permissive))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        #else
        let host = NSHostingView(rootView: content(installing: permissive))
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        host.layoutSubtreeIfNeeded()
        #endif
        let label = try #require(await settleForLabel(in: host))
        #expect(await eventually { label.currentSnapshot != nil })
        #expect(label.activateLink(at: 0))
        #expect(await eventually { handler.opened.count == 1 })

        host.rootView = content(installing: nil)
        #if canImport(UIKit)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #else
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        #endif
        let driver = try #require(label.sessionDriver)
        #expect(await eventually { driver.linkConfiguration.policyID == WebOnlyMarkdownLinkPolicy.identity })

        #expect(label.activateLink(at: 0))
        for _ in 0 ..< 300 {
            await Task.yield()
        }
        #expect(handler.opened.count == 1, "the revoked policy still opened a custom scheme")
        #expect(driver.linkConfiguration.handlerID == MarkdownLinkConfiguration.platformDefault.handlerID)

        // Re-installing after a revert must work too: the edge flag has to have
        // been reset, or the second install is the only one that ever lands.
        host.rootView = content(installing: permissive)
        #if canImport(UIKit)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #else
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        #endif
        #expect(await eventually { driver.linkConfiguration.handlerID == permissive.handlerID })
        #expect(label.activateLink(at: 0))
        #expect(await eventually { handler.opened.count == 2 })
        withExtendedLifetime(host) {}
    }

    @Test @MainActor func replacementBumpsTheConfigurationGenerationOnTheRealDriver() async throws {
        let handler = RecordingLinkHandler()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        view.setMarkdown("[web](https://example.com/gen)")
        #expect(await eventually { view.currentSnapshot != nil })
        let before = try #require(view.currentCommitToken)
        view.linkConfiguration = MarkdownLinkConfiguration(policy: AllowEverythingPolicy(), handler: handler)
        #expect(await eventually {
            view.currentCommitToken?.configurationGeneration == before.configurationGeneration + 1
        })
        let driver = try #require(view.sessionDriver)
        #expect(driver.linkConfiguration.handlerID == view.linkConfiguration.handlerID)
    }

    @Test @MainActor func swiftUIModifierReachesTheProductionView() async throws {
        let handler = RecordingLinkHandler()
        let configuration = MarkdownLinkConfiguration(policy: AllowEverythingPolicy(), handler: handler)
        let content = MarkdownText("[custom](myapp://open)")
            .markdownLinkConfiguration(configuration)
        #if canImport(UIKit)
        let host = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        #else
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        host.layoutSubtreeIfNeeded()
        #endif
        let label = try #require(await settleForLabel(in: host))
        #expect(await eventually { label.currentSnapshot != nil })
        #expect(label.linkConfiguration.handlerID == configuration.handlerID)
        // A custom scheme activates only because this policy permits it.
        #expect(label.activateLink(at: 0))
        #expect(await eventually { handler.opened.first?.scheme == "myapp" })
        withExtendedLifetime(host) {}
    }

    /// SwiftUI rebuilds a body many times. Installing the same policy again must
    /// not look like a replacement: a generation bump cancels math/SVG work,
    /// resubmits the whole document, changes every ResourceID, and silently
    /// discards any link activation that is mid-flight.
    @Test @MainActor func repeatedIdenticalInstallsDoNotBumpTheGeneration() async throws {
        let handler = RecordingLinkHandler()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        view.linkConfiguration = MarkdownLinkConfiguration(policy: AllowEverythingPolicy(), handler: handler)
        view.setMarkdown("[web](https://example.com/stable) ![img](https://images.test/a.png)")
        #expect(await eventually { view.currentSnapshot != nil })
        let before = try #require(view.currentCommitToken)
        let resourcesBefore = try resourceIdentifiers(of: #require(view.currentSnapshot))

        let installed = view.linkConfiguration
        for _ in 0 ..< 5 {
            view.linkConfiguration = installed
        }
        for _ in 0 ..< 200 {
            await Task.yield()
        }
        #expect(view.currentCommitToken?.configurationGeneration == before.configurationGeneration)
        #expect(try resourceIdentifiers(of: #require(view.currentSnapshot)) == resourcesBefore)
    }

    @Test @MainActor func theModifierIsStableAcrossBodyEvaluations() {
        let policy = AllowEverythingPolicy()
        let handler = RecordingLinkHandler()
        // Two evaluations of the same modifier must produce the same identities,
        // or every SwiftUI update reads as a configuration replacement.
        let first = MarkdownLinkConfiguration.derived(policy: policy, handler: handler)
        let second = MarkdownLinkConfiguration.derived(policy: policy, handler: handler)
        #expect(first.policyID == second.policyID)
        #expect(first.handlerID == second.handlerID)
        #expect(
            MarkdownLinkConfiguration.derived(policy: policy, handler: RecordingLinkHandler()).handlerID
                != first.handlerID
        )
        #expect(
            MarkdownLinkConfiguration.derived(policy: WebOnlyMarkdownLinkPolicy.default, handler: handler).policyID
                != first.policyID
        )
    }

    /// The identity check exists to avoid a needless generation bump. It must not
    /// decide whether the configuration reaches the driver at all: a host that
    /// tightens a stateful policy keeps the same policy type, so suppressing
    /// propagation would leave the old, more permissive policy deciding.
    @Test @MainActor func tighteningAStatefulPolicyReachesTheDriverAndIsEnforced() async throws {
        let handler = RecordingLinkHandler()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        view.linkConfiguration = .derived(policy: AllowListPolicy(hosts: ["evil.test", "good.test"]), handler: handler)
        view.setMarkdown("[a](https://evil.test/x)")
        #expect(await eventually { view.currentSnapshot != nil })

        // Same policy type, narrower allow list: the identities are equal by design.
        let tightened = MarkdownLinkConfiguration.derived(policy: AllowListPolicy(hosts: ["good.test"]), handler: handler)
        #expect(tightened.policyID == view.linkConfiguration.policyID)
        view.linkConfiguration = tightened
        let driver = try #require(view.sessionDriver)
        #expect((driver.linkConfiguration.policy as? AllowListPolicy)?.hosts == ["good.test"])

        #expect(view.activateLink(at: 0))
        for _ in 0 ..< 300 {
            await Task.yield()
        }
        #expect(handler.opened.isEmpty, "the revoked host was opened by the superseded policy")
    }

    /// A decision made under the previous configuration must not land after a
    /// replacement, even when the replacement reuses the same identities.
    @Test @MainActor func anInFlightDecisionDoesNotSurviveAnEqualIdentityReplacement() async {
        let gated = GatedLinkPolicy()
        let stale = RecordingLinkHandler()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        let shared = MarkdownConfigurationID.semantic(namespace: "equal.identity", version: 1)
        view.linkConfiguration = MarkdownLinkConfiguration(
            policy: gated, handler: stale, policyID: shared, handlerID: shared
        )
        view.setMarkdown("[web](https://example.com/inflight)")
        #expect(await eventually { view.currentSnapshot != nil })
        #expect(view.activateLink(at: 0))
        #expect(await Task.detached { gated.waitUntilEntered() }.value)
        view.linkConfiguration = MarkdownLinkConfiguration(
            policy: WebOnlyMarkdownLinkPolicy.default, handler: stale, policyID: shared, handlerID: shared
        )
        gated.gate.signal()
        for _ in 0 ..< 500 {
            await Task.yield()
        }
        #expect(stale.opened.isEmpty)
    }

    /// C1 lived on the modifier path: a *freshly derived* configuration per body
    /// evaluation. Assigning one identical value repeatedly, as an earlier test
    /// did, would have passed before the fix too.
    @Test @MainActor func freshlyDerivedInstallsDoNotBumpTheGenerationButDoTakeEffect() async throws {
        let handler = RecordingLinkHandler()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        view.linkConfiguration = .derived(policy: AllowEverythingPolicy(), handler: handler)
        view.setMarkdown("[web](https://example.com/frames) ![img](https://images.test/a.png)")
        #expect(await eventually { view.currentSnapshot != nil })
        let before = try #require(view.currentCommitToken)
        let resourcesBefore = try resourceIdentifiers(of: #require(view.currentSnapshot))

        for _ in 0 ..< 5 {
            view.linkConfiguration = .derived(policy: AllowEverythingPolicy(), handler: handler)
        }
        for _ in 0 ..< 200 {
            await Task.yield()
        }
        #expect(view.currentCommitToken?.configurationGeneration == before.configurationGeneration)
        #expect(try resourceIdentifiers(of: #require(view.currentSnapshot)) == resourcesBefore)

        // Negative case: a genuinely different handler must reach the driver.
        let other = RecordingLinkHandler()
        view.linkConfiguration = .derived(policy: AllowEverythingPolicy(), handler: other)
        let driver = try #require(view.sessionDriver)
        #expect(driver.linkConfiguration.handlerID == view.linkConfiguration.handlerID)
        #expect(await eventually {
            view.currentCommitToken?.configurationGeneration == before.configurationGeneration + 1
        })
    }

    @Test @MainActor func repeatedSwiftUIUpdatesThroughTheModifierAreStable() async throws {
        let handler = RecordingLinkHandler()
        let source = MarkdownStreamingSource("[web](https://example.com/swiftui)")
        var revisions = 0
        let content = MarkdownStreamingText(source)
            .markdownLinkPolicy(AllowEverythingPolicy(), handler: handler)
        #if canImport(UIKit)
        let host = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        #else
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        host.layoutSubtreeIfNeeded()
        #endif
        let label = try #require(await settleForLabel(in: host))
        #expect(await eventually { label.currentSnapshot != nil })
        let before = try #require(label.currentCommitToken)
        for chunk in [" one", " two", " three"] {
            source.append(chunk)
            revisions += 1
            #if canImport(UIKit)
            host.view.layoutIfNeeded()
            #else
            host.layoutSubtreeIfNeeded()
            #endif
            for _ in 0 ..< 100 {
                await Task.yield()
            }
        }
        #expect(revisions == 3)
        // Streaming appends move the source revision, never the configuration
        // generation: the link modifier must not turn each chunk into a replacement.
        #expect(label.currentCommitToken?.configurationGeneration == before.configurationGeneration)
        withExtendedLifetime(host) {}
    }
}

@MainActor
private func resourceIdentifiers(of snapshot: RenderSnapshot) -> Set<String> {
    var identifiers: Set<String> = []
    for resource in snapshot.displayModel.resourceValues {
        switch resource {
        case .image(let id, _, _), .math(let id, _, _), .svg(let id, _): identifiers.insert(id.rawValue)
        }
    }
    return identifiers
}

@MainActor
func settleForLabel(in root: Any) async -> MarkdownLabelView? {
    for _ in 0 ..< 200 {
        if let found = firstLabel(in: root) { return found }
        await Task.yield()
    }
    return firstLabel(in: root)
}

@MainActor
func firstLabel(in root: Any) -> MarkdownLabelView? {
    #if canImport(UIKit)
    guard let view = (root as? UIViewController)?.view ?? root as? UIView else { return nil }
    if let label = view as? MarkdownLabelView { return label }
    for child in view.subviews {
        if let found = firstLabel(in: child) { return found }
    }
    #else
    guard let view = root as? NSView else { return nil }
    if let label = view as? MarkdownLabelView { return label }
    for child in view.subviews {
        if let found = firstLabel(in: child) { return found }
    }
    #endif
    return nil
}

/// `check-link-activation.sh` exempts `MarkdownEditorTextView.swift` from the
/// text-view inventory because that view shows raw source, not rendered links.
/// The exemption is only sound while the storage it displays carries no `.link`
/// run — a text view opens one by itself, outside the audited handler.
@Suite(.serialized)
struct MarkdownEditorLinkAttributeTests {
    @MainActor @Test func theEditorStorageNeverCarriesALinkAttribute() throws {
        let source = """
        [inline](https://evil.test/a) and <https://evil.test/autolink>
        https://evil.test/bare and [ref][r] and ![img](https://evil.test/i.png)

        [r]: https://evil.test/ref
        `https://evil.test/code`
        """
        #if canImport(UIKit)
        let editor = MarkdownEditorTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        editor.setMarkdown(source)
        let storage = editor.textStorage
        // Nothing sets this today; a text view with it linkifies raw source itself.
        #expect(editor.dataDetectorTypes.isEmpty)
        // Rich-text editing would let a paste carry a `.link` run into the storage.
        #expect(!editor.allowsEditingTextAttributes)
        // However a run got there, the system action for it is suppressed. This
        // class is the text view on iOS, so a host can set dataDetectorTypes on it.
        // UIKit dispatches this optional delegate method through respondsToSelector,
        // so implementing it is exactly what the assertion needs to pin.
        #expect(editor.responds(to: #selector(UITextViewDelegate.textView(_:primaryActionFor:defaultAction:))))
        #else
        let editor = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        editor.setMarkdown(source)
        let scrollView = try #require(editor.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        let storage = try #require(textView.textStorage)
        #expect(!textView.isRichText)
        // `isRichText` does not gate link detection: with detection on, typing a
        // URL into a plain-text view produces a real `.link` run.
        #expect(!textView.isAutomaticLinkDetectionEnabled)
        #expect(textView.enabledTextCheckingTypes & NSTextCheckingResult.CheckingType.link.rawValue == 0)
        // Edit > Substitutions > Smart Links must not be able to turn it back on.
        textView.toggleAutomaticLinkDetection(nil)
        #expect(!textView.isAutomaticLinkDetectionEnabled)
        // And however a run got there, the click is consumed rather than opened.
        #expect(try editor.textView(textView, clickedOnLink: #require(URL(string: "https://evil.test/x")), at: 0))
        #endif
        #expect(storage.length > 0)
        var found: [NSRange] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { found.append(range) }
        }
        #expect(found.isEmpty, "the editor's storage carries a .link run, which a text view opens by itself")
    }
}
