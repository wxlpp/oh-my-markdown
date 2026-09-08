import Foundation
import MarkdownCore
@testable import MarkdownPlatformView
import MarkdownRenderKit
import Synchronization
import Testing

@MainActor final class RecordingRenderSink: RenderSessionSink {
    /// Reported on every publication and every error, so a test waits for the
    /// delivery it asserts on rather than for a timer.
    nonisolated let events = EventSignal()
    let sideEffects = RenderSideEffectProbe()
    var tokens: [RenderCommitToken] = []
    var strings: [String] = []
    var errors: [RenderSessionError] = []
    var models: [RenderDisplayModel] = []
    func replaceSnapshot(_ snapshot: RenderSnapshot, token: RenderCommitToken) {
        self.sideEffects.record()
        defer { self.events.record() }
        self.tokens.append(token)
        self.strings.append(snapshot.attributedString.string)
        self.models.append(snapshot.displayModel)
    }

    func receive(error: RenderSessionError) {
        self.sideEffects.record()
        self.errors.append(error)
        self.events.record()
    }
}

/// A call counter that is also waitable, so a test can wait for the call it
/// asserts on instead of re-checking the count on a timer.
final class RenderSideEffectProbe: Sendable {
    let events = EventSignal()
    func record() {
        self.events.record()
    }

    var count: Int {
        self.events.count
    }
}

/// Observes actor release from the generic executor while MainActor is held.
final class WeakActorLifetime<Value: Actor>: Sendable {
    private final class Storage {
        weak var value: Value?
        init(_ value: Value?) {
            self.value = value
        }
    }

    private let storage: Mutex<Storage>
    init(_ value: Value?) {
        self.storage = Mutex(Storage(value))
    }

    var value: Value? {
        self.storage.withLock { $0.value }
    }
}

@MainActor final class WeakLifetime<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) {
        self.value = value
    }
}

final class ManualRenderClock: RenderSessionClock {
    /// Reported when a sleeper registers, cancels or is released, so a test waits
    /// for the retry it asserts on rather than for a timer — which would be the
    /// very thing this clock exists to replace.
    let events = EventSignal()
    private struct State {
        var now: Duration = .zero
        var calls = 0
        var sleepers: [UUID: (Duration, CheckedContinuation<Void, any Error>)] = [:]
    }

    private let state = Mutex(State())
    func now() -> Duration {
        self.state.withLock { $0.now }
    }

    var sleepCalls: Int {
        self.state.withLock { $0.calls }
    }

    var sleepingCount: Int {
        self.state.withLock { $0.sleepers.count }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = self.state.withLock { state in
                    if Task.isCancelled { return true }
                    state.calls += 1
                    state.sleepers[id] = (state.now + duration, continuation)
                    return false
                }
                self.events.record()
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = self.state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.1.resume(throwing: CancellationError())
            self.events.record()
        }
    }

    func advance(by duration: Duration) {
        let ready = self.state.withLock { state in
            state.now += duration
            let ids = state.sleepers.compactMap { $0.value.0 <= state.now ? $0.key : nil }
            return ids.compactMap { state.sleepers.removeValue(forKey: $0)?.1 }
        }
        for continuation in ready {
            continuation.resume()
        }
        self.events.record()
    }
}

@Suite(.timeLimit(.minutes(5)), .serialized) @MainActor struct MarkdownRenderSessionTests {
    /// Deliberately holds MainActor across teardown and the weak-release assertion.
    /// The detached observer only owns a weak actor box, so it cannot mask a cycle.
    private func releaseOwnersBeforeAllowingQueuedPublication(
        queued: DispatchSemaphore, session: inout MarkdownRenderSession?,
        driver: inout MarkdownRenderSessionDriver?, sink: inout RecordingRenderSink?,
        weakSession: WeakActorLifetime<MarkdownRenderSession>, executor: ParseExecutor
    ) {
        #expect(queued.wait(timeout: .now() + 10) == .success)
        driver?.send(.dismantle)
        driver = nil
        session = nil
        sink = nil
        let released = DispatchSemaphore(value: 0)
        // The session's `deinit` tombstones through the executor, so its teardown
        // is an event this can wait on rather than a state to re-check on a timer.
        Task.detached {
            await executor.settled { weakSession.value == nil }
            released.signal()
        }
        #expect(released.wait(timeout: .now() + 12) == .success)
        #expect(weakSession.value == nil)
    }

    @Test(arguments: [false, true]) func queuedPublicationDoesNotRetainReleasedOwners(error: Bool) async throws {
        let gate = ParseGate()
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 64, parser: gate.parse)
        let clock = ManualRenderClock()
        let registry = RenderSessionSinkRegistry()
        var sink: RecordingRenderSink? = RecordingRenderSink()
        var session: MarkdownRenderSession? = MarkdownRenderSession(executor: executor, registry: registry, clock: clock)
        try registry.register(#require(sink), for: #require(session?.id))
        var driver: MarkdownRenderSessionDriver? = try MarkdownRenderSessionDriver(session: #require(session))
        let weakSession = WeakActorLifetime(session)
        let weakDriver = WeakLifetime(driver)
        let weakSink = WeakLifetime(sink)
        let probe = try #require(sink?.sideEffects)
        driver?.send(.setSource("hello", MarkdownRenderConfiguration.default.snapshot(generation: 1)))
        await gate.events.settled { gate.jobs.count == 1 }
        let old = try #require(gate.jobs.first?.submission)
        let queued = DispatchSemaphore(value: 0)
        if error {
            clock.advance(by: .seconds(2))
            Task.detached { [weak session] in await session?.receive(.busy(submission: old)) }
        } else {
            gate.release("hello")
        }
        // The observation point is a separate object that outlives the session,
        // so waiting on it does not retain the thing this test checks is released.
        let observation = session?.observation
        let observer = Task.detached { [weak session, observation] in
            await observation?.settled { await session?.submission == nil }
            queued.signal()
        }
        self.releaseOwnersBeforeAllowingQueuedPublication(
            queued: queued, session: &session, driver: &driver, sink: &sink, weakSession: weakSession,
            executor: executor
        )
        #expect(weakDriver.value == nil)
        #expect(weakSink.value == nil)
        #expect(registry.count == 0)
        // The queued message's exact authorization was revoked in the same
        // MainActor turn, so even a still-live sink could not be invoked.
        #expect(!registry.withAuthorizedSink(for: old.commitToken) { $0.receive(error: .parseBusy) })
        await observer.value
        gate.release("hello")
        await executor.settled { await executor.diagnostics.activeCount == 0 }
        await executor.settled { weakSession.value == nil }
        #expect(probe.count == 0)
        #expect(clock.sleepCalls == 0)
    }

    @Test func replacingAndReleasingSessionCancelsItsPreparationWithoutRetainingIt() async throws {
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 64) { MarkdownDocument(parsing: $0.source) }
        let preparationClock = ManualRenderClock()
        let registry = RenderSessionSinkRegistry()
        let sink = RecordingRenderSink()
        var session: MarkdownRenderSession? = MarkdownRenderSession(
            executor: executor, registry: registry, prepare: { input in
                try await preparationClock.sleep(for: .seconds(1))
                return try RenderPreparer(configuration: input.configuration).prepare(input)
            }
        )
        try registry.register(sink, for: #require(session?.id))
        var driver: MarkdownRenderSessionDriver? = try MarkdownRenderSessionDriver(session: #require(session))
        let weakSession = WeakLifetime(session)
        driver?.send(.setSource("hello", MarkdownRenderConfiguration.default.snapshot(generation: 1)))
        await preparationClock.events.settled { preparationClock.sleepingCount == 1 }
        driver?.send(.replaceConfiguration(MarkdownRenderConfiguration.default.snapshot(generation: 2)))
        await preparationClock.events.settled { preparationClock.sleepCalls == 2 && preparationClock.sleepingCount == 1 }
        session = nil
        driver = nil
        await executor.settled { weakSession.value == nil && preparationClock.sleepingCount == 0 }
        #expect(sink.tokens.isEmpty)
        #expect(sink.errors.isEmpty)
        #expect(registry.count == 0)
    }

    @Test func driverGenerationAlsoOwnsPreparedResourceIdentity() async {
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 64) { MarkdownDocument(parsing: $0.source) }
        let registry = RenderSessionSinkRegistry()
        let sink = RecordingRenderSink()
        let session = MarkdownRenderSession(executor: executor, registry: registry)
        registry.register(sink, for: session.id)
        let driver = MarkdownRenderSessionDriver(session: session)
        let reused = MarkdownRenderConfiguration.default.snapshot(generation: 99)
        driver.send(.setSource("$x$", reused))
        await sink.events.settled { sink.models.count == 1 }
        let firstLineage = sink.models[0].blocks[0].lineage
        #expect(sink.models[0].runs.first?.resourceID?.rawValue == "1:\(firstLineage):0")
        driver.send(.replaceConfiguration(reused))
        await sink.events.settled { sink.models.count == 2 }
        let secondLineage = sink.models[1].blocks[0].lineage
        #expect(secondLineage == firstLineage)
        #expect(sink.models[1].runs.first?.resourceID?.rawValue == "2:\(secondLineage):0")
        #expect(sink.models[0].runs.first?.resourceID != sink.models[1].runs.first?.resourceID)
        driver.send(.dismantle)
    }

    private func authorizeWhileMainActorIsHeld(
        _ checked: DispatchSemaphore, driver: MarkdownRenderSessionDriver
    ) {
        #expect(checked.wait(timeout: .now() + 10) == .success)
        driver.send(.replaceConfiguration(MarkdownRenderConfiguration.default.snapshot(generation: 2)))
    }

    @Test func busyAdmissionExhaustsThreeAttemptsAndOnlyUpdatesRestartIt() async {
        let gate = ParseGate()
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 0, parser: gate.parse)
        let parseSink = RecordingParseSink()
        _ = await executor.enqueue(parseJob("a"), sink: parseSink)
        _ = await executor.enqueue(parseJob("b"), sink: parseSink)
        let clock = ManualRenderClock()
        let registry = RenderSessionSinkRegistry()
        let sink = RecordingRenderSink()
        let session = MarkdownRenderSession(executor: executor, registry: registry, clock: clock)
        registry.register(sink, for: session.id)
        let driver = MarkdownRenderSessionDriver(session: session)
        driver.send(.setSource("busy", MarkdownRenderConfiguration.default.snapshot(generation: 1)))
        await clock.events.settled { clock.sleepingCount == 1 }
        clock.advance(by: .milliseconds(250))
        await clock.events.settled { clock.sleepCalls == 2 && clock.sleepingCount == 1 }
        clock.advance(by: .milliseconds(250))
        await sink.events.settled { sink.errors == [.parseBusy] }
        #expect(clock.sleepCalls == 2)
        #expect(clock.sleepingCount == 0)
        clock.advance(by: .seconds(10))
        #expect(sink.errors == [.parseBusy])
        driver.send(.replaceConfiguration(MarkdownRenderConfiguration.default.snapshot(generation: 2)))
        await clock.events.settled { clock.sleepCalls == 3 }
        driver.send(.dismantle)
        await clock.events.settled { clock.sleepingCount == 0 }
        gate.release("a", "b")
    }

    @Test func deadlineExhaustsWithoutAnotherAdmissionAndRetryDoesNotRetainSession() async throws {
        let gate = ParseGate()
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 0, parser: gate.parse)
        let parseSink = RecordingParseSink()
        _ = await executor.enqueue(parseJob("a"), sink: parseSink)
        _ = await executor.enqueue(parseJob("b"), sink: parseSink)
        let clock = ManualRenderClock()
        let registry = RenderSessionSinkRegistry()
        let sink = RecordingRenderSink()
        var session: MarkdownRenderSession? = MarkdownRenderSession(executor: executor, registry: registry, clock: clock)
        try registry.register(sink, for: #require(session?.id))
        var driver: MarkdownRenderSessionDriver? = try MarkdownRenderSessionDriver(session: #require(session))
        let weakSession = WeakLifetime(session)
        driver?.send(.setSource("busy", MarkdownRenderConfiguration.default.snapshot(generation: 1)))
        await clock.events.settled { clock.sleepingCount == 1 }
        clock.advance(by: .seconds(2))
        await sink.events.settled { sink.errors == [.parseBusy] }
        #expect(clock.sleepCalls == 1)
        driver?.send(.append("again"))
        await clock.events.settled { clock.sleepingCount == 1 }
        session = nil
        driver = nil
        await executor.settled { weakSession.value == nil && clock.sleepingCount == 0 }
        #expect(registry.count == 0)
        clock.advance(by: .seconds(2))
        #expect(sink.errors == [.parseBusy])
        gate.release("a", "b")
    }

    @Test func configurationOnlyChangeRejectsOldParse() async {
        let gate = ParseGate()
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 64, parser: gate.parse)
        let registry = RenderSessionSinkRegistry()
        let sink = RecordingRenderSink()
        let session = MarkdownRenderSession(executor: executor, registry: registry)
        registry.register(sink, for: session.id)
        let driver = MarkdownRenderSessionDriver(session: session)
        driver.send(.setSource("hello", MarkdownRenderConfiguration.default.snapshot(generation: 1)))
        await gate.events.settled { gate.entered == ["hello"] }
        driver.send(.replaceConfiguration(MarkdownRenderConfiguration.default.snapshot(generation: 2)))
        await session.settled { await session.currentToken?.configurationGeneration == 2 }
        gate.release("hello")
        await sink.events.settled { sink.tokens.count == 1 }
        #expect(sink.tokens.first?.sourceRevision == 1)
        #expect(sink.tokens.first?.configurationGeneration == 2)
        #expect(sink.strings == ["hello"])
        driver.send(.dismantle)
    }

    @Test func oldConfigurationAndWrongAttemptCannotMutateNewRetryState() async throws {
        let gate = ParseGate()
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 64, parser: gate.parse)
        let clock = ManualRenderClock()
        let registry = RenderSessionSinkRegistry()
        let sink = RecordingRenderSink()
        let session = MarkdownRenderSession(executor: executor, registry: registry, clock: clock)
        registry.register(sink, for: session.id)
        let driver = MarkdownRenderSessionDriver(session: session)
        driver.send(.setSource("hello", MarkdownRenderConfiguration.default.snapshot(generation: 1)))
        await gate.events.settled { gate.jobs.count == 1 }
        let old = gate.jobs[0].submission
        driver.send(.replaceConfiguration(MarkdownRenderConfiguration.default.snapshot(generation: 2)))
        await session.settled { await session.currentToken?.configurationGeneration == 2 }
        let current = try await #require(session.submission)
        await session.receive(.busy(submission: old))
        await session.receive(.stale(submission: old))
        let wrongAttempt = ParseSubmission(
            id: current.id,
            sessionToken: current.sessionToken,
            commitToken: current.commitToken,
            attempt: 3
        )
        let wrongID = ParseSubmission(
            id: UUID(),
            sessionToken: current.sessionToken,
            commitToken: current.commitToken,
            attempt: current.attempt
        )
        await session.receive(.busy(submission: wrongAttempt))
        await session.receive(.stale(submission: wrongID))
        #expect(await session.submission == current)
        #expect(clock.sleepCalls == 0)
        #expect(sink.errors.isEmpty)
        gate.release("hello")
        await sink.events.settled { sink.tokens.count == 1 }
        #expect(sink.tokens[0].configurationGeneration == 2)
        driver.send(.dismantle)
    }

    /// Hold MainActor, let the real session clear its submission after its actor
    /// check, then revoke that exact authorization before its queued commit can run.
    @Test(arguments: [false, true]) func newerAuthorizationRejectsAlreadyQueuedSnapshotOrError(error: Bool) async {
        let gate = ParseGate()
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 64, parser: gate.parse)
        let clock = ManualRenderClock()
        let registry = RenderSessionSinkRegistry()
        let sink = RecordingRenderSink()
        let session = MarkdownRenderSession(executor: executor, registry: registry, clock: clock)
        registry.register(sink, for: session.id)
        let driver = MarkdownRenderSessionDriver(session: session)
        driver.send(.setSource("hello", MarkdownRenderConfiguration.default.snapshot(generation: 1)))
        await gate.events.settled { gate.jobs.count == 1 }
        let old = gate.jobs[0].submission
        let checked = DispatchSemaphore(value: 0)
        if error {
            clock.advance(by: .seconds(2))
            Task.detached { await session.receive(.busy(submission: old)) }
        } else {
            gate.release("hello")
        }
        let observation = session.observation
        let observer = Task.detached { [weak session, observation] in
            await observation.settled { await session?.submission == nil }
            checked.signal()
        }
        self.authorizeWhileMainActorIsHeld(checked, driver: driver)
        await observer.value
        gate.release("hello")
        await sink.events.settled { sink.tokens.count == 1 }
        #expect(sink.tokens[0].configurationGeneration == 2)
        #expect(sink.errors.isEmpty)
        #expect(clock.sleepCalls == 0)
        driver.send(.dismantle)
    }

    @Test func rapidMutationsPublishOnlyNewestSourceAndConfiguration() async {
        let gate = ParseGate()
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 64, parser: gate.parse)
        let registry = RenderSessionSinkRegistry()
        let sink = RecordingRenderSink()
        let session = MarkdownRenderSession(executor: executor, registry: registry)
        registry.register(sink, for: session.id)
        let driver = MarkdownRenderSessionDriver(session: session)
        let config = MarkdownRenderConfiguration.default.snapshot(generation: 1)
        driver.send(.setSource("first", config))
        await gate.events.settled { gate.entered == ["first"] }
        for _ in 0 ..< 20 {
            driver.send(.append(" discarded"))
        }
        driver.send(.setSource("new", config))
        driver.send(.append("est"))
        driver.send(.replaceConfiguration(config))
        await session.settled { await session.currentToken?.sequence == 24 }
        gate.release("first", "newest")
        await sink.events.settled { sink.strings == ["newest"] }
        #expect(gate.entered == ["first", "newest"])
        #expect(sink.tokens[0].sourceRevision == 23)
        #expect(sink.tokens[0].configurationGeneration == 3)
        driver.send(.dismantle)
    }

    @Test func releasingDriverDuringBlockedParseReleasesSessionAndSink() async throws {
        let gate = ParseGate()
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 64, parser: gate.parse)
        let registry = RenderSessionSinkRegistry()
        var sink: RecordingRenderSink? = RecordingRenderSink()
        var session: MarkdownRenderSession? = MarkdownRenderSession(executor: executor, registry: registry)
        try registry.register(#require(sink), for: #require(session?.id))
        var driver: MarkdownRenderSessionDriver? = try MarkdownRenderSessionDriver(session: #require(session))
        let weakSink = WeakLifetime(sink)
        let weakSession = WeakLifetime(session)
        let weakDriver = WeakLifetime(driver)
        driver?.send(.setSource("blocked", MarkdownRenderConfiguration.default.snapshot(generation: 1)))
        await gate.events.settled { gate.entered == ["blocked"] }
        session = nil
        sink = nil
        driver = nil
        await executor.settled { weakDriver.value == nil && weakSession.value == nil && weakSink.value == nil }
        #expect(registry.count == 0)
        await executor.settled { await executor.diagnostics.registryCount == 0 }
        #expect(await executor.diagnostics.activeCount == 1)
        gate.release("blocked")
        await executor.settled { await executor.diagnostics.activeCount == 0 }
        #expect(gate.entered == ["blocked"])
    }

    @Test func synchronousAuthorizationRejectsQueuedOldCommitAndError() {
        let registry = RenderSessionSinkRegistry()
        let sink = RecordingRenderSink()
        let id = RenderSessionID(rawValue: UUID())
        registry.register(sink, for: id)
        let old = RenderCommitToken(sessionID: id, sequence: 1, sourceRevision: 1, configurationGeneration: 1)
        let new = RenderCommitToken(sessionID: id, sequence: 2, sourceRevision: 1, configurationGeneration: 2)
        registry.authorize(old)
        registry.authorize(new)
        #expect(!registry.withAuthorizedSink(for: old) { $0.receive(error: .parseBusy) })
        #expect(sink.errors.isEmpty)
        registry.revokeAndUnregister(id)
        #expect(!registry.withAuthorizedSink(for: new) { $0.receive(error: .parseBusy) })
    }

    @Test func thousandLifecycleCyclesReclaimRegistries() async {
        let gate = ParseGate()
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 64, parser: gate.parse)
        let parseSink = RecordingParseSink()
        _ = await executor.enqueue(parseJob("a"), sink: parseSink)
        _ = await executor.enqueue(parseJob("b"), sink: parseSink)
        let registry = RenderSessionSinkRegistry()
        var weakSessions: [WeakLifetime<MarkdownRenderSession>] = []
        for _ in 0 ..< 1000 {
            let session = MarkdownRenderSession(executor: executor, registry: registry)
            let sink = RecordingRenderSink()
            registry.register(sink, for: session.id)
            let driver = MarkdownRenderSessionDriver(session: session)
            weakSessions.append(WeakLifetime(session))
            driver.send(.setSource("hello", MarkdownRenderConfiguration.default.snapshot(generation: 1)))
            await executor.settled { await executor.diagnostics.registryCount == 3 }
            driver.send(.dismantle)
            await session.dismantle()
        }
        #expect(registry.count == 0)
        await executor.settled { weakSessions.allSatisfy { $0.value == nil } }
        #expect(await executor.diagnostics == .init(activeCount: 2, waitingTokenCount: 0, registryCount: 2))
        gate.release("a", "b")
        await executor.settled { await executor.diagnostics == .init(activeCount: 0, waitingTokenCount: 0, registryCount: 0) }
    }
}
