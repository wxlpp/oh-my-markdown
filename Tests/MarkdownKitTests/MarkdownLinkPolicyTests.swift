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
/// the evaluation is in flight. Runs off the main actor, so blocking is safe.
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

struct AllowEverythingPolicy: MarkdownLinkPolicy {
    func disposition(for request: MarkdownLinkRequest) -> MarkdownLinkDisposition {
        .allow(request.url)
    }
}

@Suite(.serialized)
struct MarkdownLinkPolicyTests {
    private func request(_ string: String, generation: UInt64 = 0) throws -> MarkdownLinkRequest {
        try MarkdownLinkRequest(url: #require(URL(string: string)), sourceRange: nil, sessionGeneration: generation)
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
}

@MainActor
private func settleForLabel(in root: Any) async -> MarkdownLabelView? {
    for _ in 0 ..< 200 {
        if let found = firstLabel(in: root) { return found }
        await Task.yield()
    }
    return firstLabel(in: root)
}

@MainActor
private func firstLabel(in root: Any) -> MarkdownLabelView? {
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
