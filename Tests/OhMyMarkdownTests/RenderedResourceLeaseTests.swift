import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing

@MainActor
@Suite("Rendered resource leases")
struct RenderedResourceLeaseTests {
    @Test func independentOwnersReleaseExactlyOnce() {
        let record = RenderedResourceRecord(image: PlatformImage(), baselineOffset: 0)
        let flight = record.acquireLease()
        let cache = record.acquireLease()
        var publication: RenderedResourceLease? = record.acquireLease()
        #expect(record.ownerCount == 3)
        flight.release()
        flight.release()
        #expect(record.ownerCount == 2)
        cache.release()
        #expect(record.ownerCount == 1)
        #expect(publication?.image === record.image)
        publication = nil
        #expect(record.ownerCount == 0)
    }
}

import Observation
import Synchronization

extension RenderedResourceLeaseTests {
    @Test func pendingFlightIsReleasedOnCancellationButCompletedCacheSurvives() async throws {
        let cache = RenderedResourceCache()
        let coordinator = MathLoadCoordinator(cache: cache)
        let configuration = MathRendererConfiguration(renderer: ResourceMathProducer())
        coordinator.configure(configuration)
        let key = resourceMathKey(configuration: configuration)
        await coordinator.load(key, isCurrent: { true }, completed: {})?.value
        let inspected = try #require(cache.publication(for: .math(key)))
        let record = inspected.record
        #expect(record.ownerCount == 3) // flight + cache + inspection publication
        inspected.release()
        #expect(record.ownerCount == 2)
        coordinator.cancelAll()
        #expect(record.ownerCount == 1)
        coordinator.cancelAll()
        #expect(record.ownerCount == 1)
    }

    @Test func snapshotReplacementAndTeardownReleaseOnlyPublicationOwners() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let gate = ViewSnapshotGate()
        view.mathRenderer = MathRendererConfiguration(renderer: ResourceMathProducer())
        view.setMarkdown("$x$")
        await gate.wait(for: view) { view.currentSnapshot?.resourceOwners.first is RenderedResourceLease }
        let first = try #require((view.currentSnapshot?.resourceOwners.first as? RenderedResourceLease)?.record)
        #expect(first.ownerCount == 2)
        view.setMarkdown("plain")
        await gate.wait(for: view) { view.currentSnapshot?.displayModel.source == "plain" }
        #expect(first.ownerCount == 1)
        view.setMarkdown("$x$")
        await gate.wait(for: view) { view.currentSnapshot?.resourceOwners.first is RenderedResourceLease }
        #expect((view.currentSnapshot?.resourceOwners.first as? RenderedResourceLease)?.record === first)
        #expect(first.ownerCount == 2)
        view.dismantleRenderSession()
        #expect(first.ownerCount == 1)
        #expect(view.currentSnapshot == nil)
        #expect(view.sessionDriver == nil)
    }

    @Test func snapshotObservationIsOneShotAndDoesNotRetainView() async throws {
        var view: MarkdownLabelView? = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        let gate = ViewSnapshotGate()
        view?.setMarkdown("without observers")
        try await gate.wait(for: #require(view)) { view?.currentSnapshot?.displayModel.source == "without observers" }
        let replacement = Mutex(0)
        withObservationTracking { _ = view?.currentSnapshot } onChange: { replacement.withLock { $0 += 1 } }
        view?.setMarkdown("replacement")
        try await gate.wait(for: #require(view)) { view?.currentSnapshot?.displayModel.source == "replacement" }
        #expect(replacement.withLock { $0 } == 1)
        let teardown = Mutex(0)
        withObservationTracking { _ = view?.currentSnapshot } onChange: { teardown.withLock { $0 += 1 } }
        view?.dismantleRenderSession()
        #expect(teardown.withLock { $0 } == 1)
        #expect(view?.currentSnapshot == nil)
        let orphan = Mutex(0)
        withObservationTracking { _ = view?.currentSnapshot } onChange: { orphan.withLock { $0 += 1 } }
        weak var observed = view
        view = nil
        #expect(observed == nil)
        observed = nil
        #expect(orphan.withLock { $0 } == 0)
    }
}

private final class ResourceDebounceClock: RenderSessionClock {
    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var calls = 0
        var cancelled = 0
    }

    private let state = Mutex(State())
    let arrivals: AsyncStream<Void>
    private let arrival: AsyncStream<Void>.Continuation
    init() {
        (self.arrivals, self.arrival) = AsyncStream.makeStream()
    }

    func now() -> Duration {
        .zero
    }

    var calls: Int {
        self.state.withLock { $0.calls }
    }

    var cancelled: Int {
        self.state.withLock { $0.cancelled }
    }

    func sleep(for duration: Duration) async throws {
        #expect(duration == .milliseconds(33))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = self.state.withLock { state in
                    if Task.isCancelled { return true }
                    state.calls += 1
                    state.continuation = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
                else { self.arrival.yield(()) }
            }
        } onCancel: {
            let continuation = self.state.withLock { state in
                state.cancelled += 1
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance() {
        let continuation = self.state.withLock { state in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }
}

extension RenderedResourceLeaseTests {
    @Test func oneInjectedClockTaskCoalescesKeysAndCancellationDiscardsCallbacks() async {
        let clock = ResourceDebounceClock()
        var arrivals = clock.arrivals.makeAsyncIterator()
        var owner: RenderSessionResourceTaskOwner? = RenderSessionResourceTaskOwner(clock: clock)
        let (applied, apply) = AsyncStream<String>.makeStream()
        var appliedValues = applied.makeAsyncIterator()
        owner?.deferAction(key: "height") { apply.yield("superseded") }
        owner?.deferAction(key: "height") { apply.yield("height") }
        owner?.deferAction(key: "resources") { apply.yield("resources") }
        await arrivals.next()
        #expect(clock.calls == 1)
        clock.advance()
        let values = await [appliedValues.next(), appliedValues.next()].compactMap(\.self)
        #expect(Set(values) == ["height", "resources"])
        owner?.deferAction(key: "resources") { apply.yield("cancelled") }
        await arrivals.next()
        owner?.cancelAll()
        #expect(clock.cancelled == 1)
        owner?.deferAction(key: "resources") { apply.yield("latest") }
        await arrivals.next()
        clock.advance()
        #expect(await appliedValues.next() == "latest")
        owner?.deferAction(key: "height") { apply.yield("deinit") }
        await arrivals.next()
        weak var observed = owner
        owner = nil
        #expect(observed == nil)
        observed = nil
        #expect(clock.cancelled == 2)
        apply.finish()
        #expect(await appliedValues.next() == nil)
    }
}
