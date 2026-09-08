import Foundation
import MarkdownKit
@testable import MarkdownPlatformView
import SwiftUI
import Testing

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
@Suite(.timeLimit(.minutes(5)), .serialized)
struct ResourceConfigurationTests {
    private final class HandlerLifetime {}
    actor PausedLoader: MarkdownImageLoading {
        private var pending: [CheckedContinuation<MarkdownImagePayload, any Error>] = []
        /// Reported on both edges of a load, so a test waits for the call it
        /// asserts on rather than for a timer.
        nonisolated let events = EventSignal()
        private(set) var calls = 0
        private(set) var completed = 0
        func load(_ request: MarkdownImageRequest) async throws -> MarkdownImagePayload {
            self.calls += 1
            self.events.record()
            defer { self.completed += 1; self.events.record() }
            return try await withCheckedThrowingContinuation { self.pending.append($0) }
        }

        func finish(_ result: Result<MarkdownImagePayload, any Error>) {
            guard !self.pending.isEmpty else { Issue.record("No pending image request to complete"); return }
            self.pending.removeFirst().resume(with: result)
        }
    }

    @Test func cacheNamespacesAreOwnedByWrappersAndNormalizeBuiltInSettings() {
        let loader = PausedLoader()
        #expect(MarkdownRemoteImageConfiguration(loader: loader).configurationID != MarkdownRemoteImageConfiguration(loader: loader).configurationID)
        let shared = MarkdownConfigurationID.semantic(namespace: "host-image-loader", version: 2)
        #expect(MarkdownRemoteImageConfiguration(loader: loader, configurationID: shared).configurationID == MarkdownRemoteImageConfiguration(loader: loader, configurationID: shared).configurationID)
        #expect(MarkdownRemoteImageConfiguration.defaultHTTPS.configurationID == MarkdownRemoteImageConfiguration.https().configurationID)
        #expect(MarkdownRemoteImageConfiguration.https(requestTimeout: .zero, resourceTimeout: .seconds(999)).configurationID == MarkdownRemoteImageConfiguration.https(requestTimeout: .seconds(1), resourceTimeout: .seconds(120)).configurationID)
        #expect(MarkdownRemoteImageConfiguration.https(requestTimeout: .seconds(16)).configurationID != MarkdownRemoteImageConfiguration.defaultHTTPS.configurationID)
    }

    @Test func optInStartsCustomLoaderAndSameIDReplacementRejectsLateFailure() async throws {
        let loader = PausedLoader()
        let shared = MarkdownConfigurationID.semantic(namespace: "host", version: 1)
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        var failures: [MarkdownResourceFailure] = []
        view.onResourceError = { failures.append($0) }
        view.remoteImages = MarkdownRemoteImageConfiguration(loader: loader, configurationID: shared)
        view.blocks = MarkdownDocument(parsing: "![private alt](https://example.test/private.png?secret=hidden)").blocks
        // Opting in has to invoke the configured loader; if it never does, this
        // waits for an event that never comes and the suite's time limit fails it.
        await loader.events.settled { await loader.calls == 1 }
        let old = try #require(view.currentCommitToken)
        view.remoteImages = MarkdownRemoteImageConfiguration(loader: loader, configurationID: shared)
        await loader.events.settled { await loader.calls == 2 }
        let current = try #require(view.currentCommitToken)
        #expect(current.configurationGeneration == old.configurationGeneration + 1)
        await loader.finish(.failure(URLError(.badServerResponse)))
        await loader.events.settled { await loader.completed == 1 }
        #expect(failures.isEmpty)
        #expect(view.imageRequests.values.allSatisfy { $0 == .loading })
        await loader.finish(.failure(URLError(.timedOut)))
        await view.settled { failures.count == 1 }
        #expect(failures.first?.category == .timedOut)
        #expect(try failures.first?.origin == SanitizedMarkdownOrigin(url: #require(URL(string: "https://example.test"))))
    }

    @Test func sanitizedFailuresDoNotCarryURLSecrets() throws {
        let first = try MarkdownResourceFailure(category: .transport, origin: SanitizedMarkdownOrigin(url: #require(URL(string: "https://user:password@EXAMPLE.test:443/path-secret?query-secret#fragment-secret"))))
        let second = try MarkdownResourceFailure(category: .transport, origin: SanitizedMarkdownOrigin(url: #require(URL(string: "https://example.test/different"))))
        #expect(first == second)
        #expect(first.origin?.port == nil)
        let rendered = String(reflecting: first)
        for secret in ["user", "password", "path-secret", "query-secret", "fragment-secret"] {
            #expect(!rendered.contains(secret))
        }
        #expect(try SanitizedMarkdownOrigin(url: #require(URL(string: "https://example.test:8443/a")))?.port == 8443)
    }

    @Test(arguments: [false, true])
    func pendingFailureUsesTheCurrentHandlerOrHonorsRemoval(removeHandler: Bool) async throws {
        let loader = PausedLoader()
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        var oldCalls = 0
        var currentCalls = 0
        var owner: HandlerLifetime? = HandlerLifetime()
        weak var oldOwner = owner
        view.onResourceError = { [owner] _ in withExtendedLifetime(owner) { oldCalls += 1 } }
        owner = nil
        view.remoteImages = .init(loader: loader)
        view.blocks = MarkdownDocument(parsing: "![alt](https://example.test/image)").blocks
        await loader.events.settled { await loader.calls == 1 }
        let token = try #require(view.currentCommitToken)
        if removeHandler { view.onResourceError = nil }
        else { view.onResourceError = { _ in currentCalls += 1 } }
        #expect(oldOwner == nil)
        await loader.finish(.failure(MarkdownResourceError.transport))
        await view.settled { view.imageRequests.values.contains(.failed) }
        #expect(view.currentCommitToken == token)
        #expect(oldCalls == 0)
        #expect(currentCalls == (removeHandler ? 0 : 1))
    }

    @Test func disablingDuringLoadDropsLateValidBytes() async throws {
        let loader = PausedLoader()
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        var failures: [MarkdownResourceFailure] = []
        view.onResourceError = { failures.append($0) }
        view.remoteImages = .init(loader: loader)
        view.blocks = MarkdownDocument(parsing: "![alt](https://example.test/image)").blocks
        await loader.events.settled { await loader.calls == 1 }
        let prior = try #require(view.currentCommitToken)
        view.remoteImages = .disabled
        await view.settled { view.currentCommitToken?.configurationGeneration == prior.configurationGeneration + 1 }
        await loader.finish(.success(.init(data: MarkdownImageLoaderTests.png, declaredMIMEType: "image/png")))
        await loader.events.settled { await loader.completed == 1 }
        #expect(view.currentSnapshot?.attributedString.string == "🖼 alt")
        #expect(view.imageRequests.isEmpty)
        #expect(failures.isEmpty)
    }

    @Test func customPayloadCannotBypassValidationInPlatformRendering() async {
        let loader = PausedLoader()
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        var failures: [MarkdownResourceFailure] = []
        view.onResourceError = { failures.append($0) }
        view.remoteImages = .init(loader: loader)
        view.blocks = MarkdownDocument(parsing: "![alt](https://example.test/private?secret)").blocks
        await loader.events.settled { await loader.calls == 1 }
        await loader.finish(.success(.init(data: MarkdownImageLoaderTests.png, declaredMIMEType: "image/jpeg")))
        await view.settled { failures.count == 1 }
        #expect(failures.first?.category == .typeMismatch)
        #expect(view.currentSnapshot?.attributedString.string == "🖼 alt")
        #expect(view.imageRequests.values.allSatisfy { $0 == .failed })
    }

    @Test func configuredTimeoutsReachTheRealPlatformRequest() async {
        let url = MarkdownImageLoaderTests.route { proto in
            #expect(proto.request.timeoutInterval == 75)
            proto.respond()
        }
        defer { MarkdownImageLoaderTests.ControlledProtocol.routes.withLock { $0[url.path] = nil } }
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        view.remoteImages = .init(loader: DefaultHTTPSImageLoader(requestTimeout: .seconds(75), resourceTimeout: .seconds(95), protocolClasses: [MarkdownImageLoaderTests.ControlledProtocol.self]))
        view.blocks = MarkdownDocument(parsing: "![alt](\(url.absoluteString))").blocks
        await view.settled { view.currentSnapshot?.attributedString.string == "\u{FFFC}" }
    }

    @Test(arguments: [false, true])
    func SwiftUIModifiersConfigureTheActualStaticAndStreamingView(streaming: Bool) async {
        let loader = PausedLoader()
        let configuration = MarkdownRemoteImageConfiguration(loader: loader)
        let source = "![alt](https://example.test/private)"
        let streamingSource = MarkdownStreamingSource(source)
        let content = Group {
            if streaming { MarkdownStreamingText(streamingSource) }
            else { MarkdownText(source) }
        }.markdownRemoteImages(configuration).onMarkdownResourceError { _ in }
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
        await loader.events.settled { await loader.calls > 0 }
        while await loader.calls > loader.completed {
            let completed = await loader.completed
            await loader.finish(.failure(MarkdownResourceError.transport))
            await loader.events.settled { await loader.completed > completed }
        }
        withExtendedLifetime(host) {}
    }

    @Test func defaultRenderingLeavesRemoteImagePlaceholderWithoutResourceWork() async {
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        view.blocks = MarkdownDocument(parsing: "![private alt](https://127.0.0.1:1/private.png?secret=never-send)").blocks
        await view.settled { view.currentSnapshot != nil }
        #expect(view.currentSnapshot?.attributedString.string == "🖼 private alt")
        #expect(view.imageRequests.isEmpty)
        #expect(view.sessionDriver?.resourceTaskOwner.count == 0)
    }
}

/// `.defaultHTTPS` builds a fresh value on every access, and a SwiftUI body is
/// evaluated whenever anything around it changes — including the `@State` a host
/// updates from `onMarkdownResourceError`. Keying the reinstall on the instance
/// therefore closed a loop: reinstall, restart the loads, fail, record, evaluate
/// the body, reinstall. Found by watching the Example's failure list grow without
/// bound with one unreachable image on screen.
@MainActor
@Suite(.timeLimit(.minutes(5)), .serialized)
struct RemoteImageReinstallTests {
    private actor CountingLoader: MarkdownImageLoading {
        nonisolated let events = EventSignal()
        private(set) var calls = 0
        func load(_ request: MarkdownImageRequest) async throws -> MarkdownImagePayload {
            self.calls += 1
            self.events.record()
            throw URLError(.cannotFindHost)
        }
    }

    /// The host shape that closes the loop: a failure updates state, which
    /// re-evaluates the body, which rebuilds the configuration value.
    private struct FailureRecordingHost: View {
        let loader: any MarkdownImageLoading
        let configurationID: MarkdownConfigurationID
        @State private var failures = 0

        var body: some View {
            VStack {
                Text("failures: \(self.failures)")
                MarkdownText("![alt](https://example.invalid/x.png)")
                    .markdownRemoteImages(
                        MarkdownRemoteImageConfiguration(loader: self.loader, configurationID: self.configurationID)
                    )
                    .onMarkdownResourceError { _ in self.failures += 1 }
            }
        }
    }

    @Test func aRecordedFailureDoesNotRestartTheLoad() async throws {
        let loader = CountingLoader()
        let content = FailureRecordingHost(
            loader: loader, configurationID: .semantic(namespace: "reinstall-test", version: 1)
        )
        #if canImport(UIKit)
        let host = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        #else
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        #endif
        let label = try #require(await settleForLabel(in: host))
        await loader.events.settled { await loader.calls >= 1 }
        // Long enough for a loop to run away: each turn of the broken cycle is one
        // failure, one state write and one body evaluation, all on this actor.
        for _ in 0 ..< 400 {
            #if canImport(UIKit)
            host.view.layoutIfNeeded()
            #else
            host.layoutSubtreeIfNeeded()
            #endif
            await Task.yield()
        }
        #expect(await loader.calls == 1, "a recorded failure restarted the load")
        withExtendedLifetime((host, label)) {}
    }
}
