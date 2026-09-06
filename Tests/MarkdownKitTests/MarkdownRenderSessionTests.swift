import Foundation
import MarkdownCore
@testable import MarkdownPlatformView
import MarkdownRenderKit
import Synchronization
import Testing

@MainActor final class RecordingRenderSink: RenderSessionSink {
    var tokens: [RenderCommitToken] = []
    var strings: [String] = []
    var errors: [RenderSessionError] = []
    var models: [RenderDisplayModel] = []
    func replaceSnapshot(_ snapshot: RenderSnapshot, token: RenderCommitToken) {
        self.tokens.append(token)
        self.strings.append(snapshot.attributedString.string)
        self.models.append(snapshot.displayModel)
    }

    func receive(error: RenderSessionError) {
        self.errors.append(error)
    }
}

@MainActor final class WeakLifetime<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) {
        self.value = value
    }
}

final class ManualRenderClock: RenderSessionClock {
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
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = self.state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.1.resume(throwing: CancellationError())
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
    }
}

@Suite(.serialized) @MainActor struct MarkdownRenderSessionTests {
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
        #expect(await eventually { preparationClock.sleepingCount == 1 })
        driver?.send(.replaceConfiguration(MarkdownRenderConfiguration.default.snapshot(generation: 2)))
        #expect(await eventually { preparationClock.sleepCalls == 2 && preparationClock.sleepingCount == 1 })
        session = nil
        driver = nil
        #expect(await eventually { weakSession.value == nil && preparationClock.sleepingCount == 0 })
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
        #expect(await eventually { sink.models.count == 1 })
        #expect(sink.models[0].runs.first?.resourceID?.rawValue == "1:0:0")
        driver.send(.replaceConfiguration(reused))
        #expect(await eventually { sink.models.count == 2 })
        #expect(sink.models[1].runs.first?.resourceID?.rawValue == "2:0:0")
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
        #expect(await eventually { clock.sleepingCount == 1 })
        clock.advance(by: .milliseconds(250))
        #expect(await eventually { clock.sleepCalls == 2 && clock.sleepingCount == 1 })
        clock.advance(by: .milliseconds(250))
        #expect(await eventually { sink.errors == [.parseBusy] })
        #expect(clock.sleepCalls == 2)
        #expect(clock.sleepingCount == 0)
        clock.advance(by: .seconds(10))
        #expect(sink.errors == [.parseBusy])
        driver.send(.replaceConfiguration(MarkdownRenderConfiguration.default.snapshot(generation: 2)))
        #expect(await eventually { clock.sleepCalls == 3 })
        driver.send(.dismantle)
        #expect(await eventually { clock.sleepingCount == 0 })
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
        #expect(await eventually { clock.sleepingCount == 1 })
        clock.advance(by: .seconds(2))
        #expect(await eventually { sink.errors == [.parseBusy] })
        #expect(clock.sleepCalls == 1)
        driver?.send(.append("again"))
        #expect(await eventually { clock.sleepingCount == 1 })
        session = nil
        driver = nil
        #expect(await eventually { weakSession.value == nil && clock.sleepingCount == 0 })
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
        #expect(await eventually { gate.entered == ["hello"] })
        driver.send(.replaceConfiguration(MarkdownRenderConfiguration.default.snapshot(generation: 2)))
        #expect(await eventually { await session.currentToken?.configurationGeneration == 2 })
        gate.release("hello")
        #expect(await eventually { sink.tokens.count == 1 })
        #expect(sink.tokens.first?.sourceRevision == 1)
        #expect(sink.tokens.first?.configurationGeneration == 2)
        #expect(sink.strings == ["hello\n"])
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
        #expect(await eventually { gate.jobs.count == 1 })
        let old = gate.jobs[0].submission
        driver.send(.replaceConfiguration(MarkdownRenderConfiguration.default.snapshot(generation: 2)))
        #expect(await eventually { await session.currentToken?.configurationGeneration == 2 })
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
        #expect(await eventually { sink.tokens.count == 1 })
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
        #expect(await eventually { gate.jobs.count == 1 })
        let old = gate.jobs[0].submission
        let checked = DispatchSemaphore(value: 0)
        if error {
            clock.advance(by: .seconds(2))
            Task.detached { await session.receive(.busy(submission: old)) }
        } else {
            gate.release("hello")
        }
        let observer = Task.detached {
            let reached = await eventually { await session.submission == nil }
            checked.signal()
            return reached
        }
        self.authorizeWhileMainActorIsHeld(checked, driver: driver)
        #expect(await observer.value)
        gate.release("hello")
        #expect(await eventually { sink.tokens.count == 1 })
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
        #expect(await eventually { gate.entered == ["first"] })
        for _ in 0 ..< 20 {
            driver.send(.append(" discarded"))
        }
        driver.send(.setSource("new", config))
        driver.send(.append("est"))
        driver.send(.replaceConfiguration(config))
        #expect(await eventually { await session.currentToken?.sequence == 24 })
        gate.release("first", "newest")
        #expect(await eventually { sink.strings == ["newest\n"] })
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
        #expect(await eventually { gate.entered == ["blocked"] })
        session = nil
        sink = nil
        driver = nil
        #expect(await eventually { weakDriver.value == nil && weakSession.value == nil && weakSink.value == nil })
        #expect(registry.count == 0)
        #expect(await eventually { await executor.diagnostics.registryCount == 0 })
        #expect(await executor.diagnostics.activeCount == 1)
        gate.release("blocked")
        #expect(await eventually { await executor.diagnostics.activeCount == 0 })
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
            #expect(await eventually { await executor.diagnostics.registryCount == 3 })
            driver.send(.dismantle)
            await session.dismantle()
        }
        #expect(registry.count == 0)
        #expect(await eventually { weakSessions.allSatisfy { $0.value == nil } })
        #expect(await executor.diagnostics == .init(activeCount: 2, waitingTokenCount: 0, registryCount: 2))
        gate.release("a", "b")
        #expect(await eventually { await executor.diagnostics == .init(activeCount: 0, waitingTokenCount: 0, registryCount: 0) })
    }
}
