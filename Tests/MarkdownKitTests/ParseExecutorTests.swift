import Foundation
import MarkdownCore
@testable import MarkdownPlatformView
import Synchronization

#if PARSE_TOKEN_CONSTRUCTION_NEGATIVE
/// Compile this checked-in fixture with -D PARSE_TOKEN_CONSTRUCTION_NEGATIVE.
/// Equal identities must not be reconstructed with independent lifetime state.
func rejectedTokenReconstruction(_ identity: UUID) {
    _ = ParseSessionToken(rawValue: identity)
}

#elseif PARSE_TOKEN_CONSTRUCTION_POSITIVE
func acceptedTokenConstruction() -> ParseSessionToken {
    ParseSessionToken()
}
#else
import Testing

/// A synchronous parser gate. Tests release individual inputs, never infer progress from sleep.
final class ParseGate: Sendable {
    private let state = Mutex((jobs: [ParseJob](), released: Set<String>()))
    private let condition = NSCondition()
    /// Reported when a job reaches the parser, so a test waits for the arrival it
    /// asserts on rather than for a timer.
    let events = EventSignal()

    func parse(_ job: ParseJob) -> MarkdownDocument {
        self.condition.lock()
        self.state.withLock { $0.jobs.append(job) }
        self.events.record()
        while !self.state.withLock({ $0.released.contains(job.source) }) {
            self.condition.wait()
        }
        self.condition.unlock()
        return MarkdownDocument(parsing: job.source)
    }

    func release(_ sources: String...) {
        self.condition.lock()
        self.state.withLock { $0.released.formUnion(sources) }
        self.condition.broadcast()
        self.condition.unlock()
    }

    var entered: [String] {
        self.state.withLock { $0.jobs.map(\.source) }
    }

    var jobs: [ParseJob] {
        self.state.withLock { $0.jobs }
    }
}

actor RecordingParseSink: ParseResultSink {
    nonisolated let events = EventSignal()
    var results: [ParseExecutorResult] = []
    func receive(_ result: ParseExecutorResult) {
        self.results.append(result)
        self.events.record()
    }
}

actor PausedParseSink: ParseResultSink {
    nonisolated let events = EventSignal()
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func receive(_ result: ParseExecutorResult) async {
        self.entered = true
        self.events.record()
        await withCheckedContinuation { self.continuation = $0 }
    }

    func release() {
        self.continuation?.resume(); self.continuation = nil
    }
}

func parseJob(_ source: String, token: ParseSessionToken = .init()) -> ParseJob {
    ParseJob(
        submission: ParseSubmission(
            id: UUID(), sessionToken: token,
            commitToken: RenderCommitToken(
                sessionID: .init(rawValue: UUID()), sequence: 1, sourceRevision: 1,
                configurationGeneration: 1
            ), attempt: 1
        ), source: source
    )
}

@Suite(.timeLimit(.minutes(5)), .serialized) struct ParseExecutorTests {
    @Test func tokenCopiesShareRevocationAndDictionaryIdentity() {
        let original = ParseSessionToken()
        let copy = original
        let independent = ParseSessionToken()
        var entries = [original: "original"]
        entries[copy] = "replacement"
        #expect(entries.count == 1)
        #expect(entries[original] == "replacement")
        #expect(original.rawValue == copy.rawValue)
        #expect(original != independent)
        #expect(original.rawValue != independent.rawValue)
        copy.revoke()
        #expect(original.isRevoked)
        #expect(copy.isRevoked)
        #expect(!independent.isRevoked)
        #expect(entries.keys.first?.isRevoked == true)
    }

    @Test func absentTokenTombstoneRejectsLateAdmissionWithoutPermanentRegistryEntry() async {
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 64) { MarkdownDocument(parsing: $0.source) }
        let job = parseJob("too late")
        let sink = RecordingParseSink()
        await executor.tombstone(job.submission.sessionToken)
        #expect(await executor.enqueue(job, sink: sink) == .busy)
        #expect(await executor.diagnostics == .init(activeCount: 0, waitingTokenCount: 0, registryCount: 0))
    }

    @Test func synchronousRevocationPreventsPendingAndWaitingStartBeforeActorTombstone() async {
        let gate = ParseGate()
        let executor = ParseExecutor(maxActive: 1, maxWaitingTokens: 64, parser: gate.parse)
        let sink = RecordingParseSink()
        let active = parseJob("active")
        let waiting = parseJob("waiting")
        _ = await executor.enqueue(active, sink: sink)
        _ = await executor.enqueue(parseJob("pending", token: active.submission.sessionToken), sink: sink)
        _ = await executor.enqueue(waiting, sink: sink)
        active.submission.sessionToken.revoke()
        waiting.submission.sessionToken.revoke()
        gate.release("active")
        await executor.settled { await executor.diagnostics == .init(activeCount: 0, waitingTokenCount: 0, registryCount: 0) }
        #expect(gate.entered == ["active"])
        #expect(await sink.results.isEmpty)
    }

    @Test func completedTokenUnregistersBeforeSuspendedDeliveryReturns() async {
        let sink = PausedParseSink()
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 64) { MarkdownDocument(parsing: $0.source) }
        _ = await executor.enqueue(parseJob("hello"), sink: sink)
        await sink.events.settled { await sink.entered }
        #expect(await executor.diagnostics.registryCount == 0)
        await sink.release()
    }

    @Test func waitingTokenReplacementPreservesOneSlotAndLatestInput() async {
        let gate = ParseGate()
        let executor = ParseExecutor(maxActive: 1, maxWaitingTokens: 1, parser: gate.parse)
        let sink = RecordingParseSink()
        _ = await executor.enqueue(parseJob("active"), sink: sink)
        let queued = parseJob("old")
        _ = await executor.enqueue(queued, sink: sink)
        #expect(await executor.enqueue(parseJob("new", token: queued.submission.sessionToken), sink: sink) == .replacedPending)
        #expect(await executor.diagnostics.waitingTokenCount == 1)
        await sink.events.settled { await sink.results.count == 1 }
        gate.release("active")
        await gate.events.settled { gate.entered == ["active", "new"] }
        gate.release("new")
        await executor.settled { await executor.diagnostics.registryCount == 0 }
    }

    @Test func unregisterPreventsNewPromotionButCannotRecallAnInFlightMessage() async {
        let registry = ParseResultRegistry()
        let sink = PausedParseSink()
        let job = parseJob("hello")
        registry.register(sink, for: job.submission.sessionToken)
        #expect(registry.count == 1)
        let delivery = Task { await registry.publish(.busy(submission: job.submission), to: job.submission.sessionToken) }
        await sink.events.settled { await sink.entered }
        registry.unregister(job.submission.sessionToken)
        #expect(registry.count == 0)
        // This returns even though the earlier message is still deliberately paused.
        await registry.publish(.busy(submission: job.submission), to: job.submission.sessionToken)
        await sink.release()
        await delivery.value
    }

    /// Removing either global admission bound would start a third blocked parser or retain a 65th waiter.
    @Test func globalBoundAndImmediateAdmission() async {
        let gate = ParseGate()
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 64, parser: gate.parse)
        let sink = RecordingParseSink()
        #expect(await executor.enqueue(parseJob("active-a"), sink: sink) == .started)
        #expect(await executor.enqueue(parseJob("active-b"), sink: sink) == .started)
        var waiting: [ParseSessionToken] = []
        for index in 0 ..< 64 {
            let job = parseJob("waiting-\(index)")
            waiting.append(job.submission.sessionToken)
            #expect(await executor.enqueue(job, sink: sink) == .queued)
        }
        #expect(await executor.enqueue(parseJob("overflow"), sink: sink) == .busy)
        await gate.events.settled { gate.entered.count == 2 }
        #expect(await executor.diagnostics == .init(activeCount: 2, waitingTokenCount: 64, registryCount: 66))
        for token in waiting {
            await executor.tombstone(token)
        }
        #expect(await executor.diagnostics.registryCount == 2)
        gate.release("active-a", "active-b")
        await executor.settled { await executor.diagnostics.registryCount == 0 }
    }

    /// Replacing an active token's pending slot must not launch overlapping or intermediate work.
    @Test func activeTokenCoalescesExactlyOneFollowUp() async {
        let gate = ParseGate()
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 64, parser: gate.parse)
        let sink = RecordingParseSink()
        let token = ParseSessionToken()
        #expect(await executor.enqueue(parseJob("first", token: token), sink: sink) == .started)
        #expect(await executor.enqueue(parseJob("middle", token: token), sink: sink) == .queued)
        #expect(await executor.enqueue(parseJob("latest", token: token), sink: sink) == .replacedPending)
        await gate.events.settled { gate.entered == ["first"] }
        #expect(await executor.diagnostics.activeCount == 1)
        gate.release("first")
        await gate.events.settled { gate.entered == ["first", "latest"] }
        gate.release("latest")
        await executor.settled { await executor.diagnostics.registryCount == 0 }
        await sink.events.settled { await sink.results.count == 3 }
        let results = await sink.results
        #expect(results.contains { if case .stale(let submission) = $0 { return submission.sessionToken == token }; return false })
    }

    @Test func tombstoneDropsActiveAndPendingAndRegistrationImmediately() async {
        let gate = ParseGate()
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 64, parser: gate.parse)
        let sink = RecordingParseSink()
        let token = ParseSessionToken()
        _ = await executor.enqueue(parseJob("blocked", token: token), sink: sink)
        _ = await executor.enqueue(parseJob("never", token: token), sink: sink)
        await executor.tombstone(token)
        #expect(await executor.diagnostics == .init(activeCount: 1, waitingTokenCount: 0, registryCount: 0))
        #expect(await executor.enqueue(parseJob("also-never", token: token), sink: sink) == .busy)
        gate.release("blocked")
        await executor.settled { await executor.diagnostics.activeCount == 0 }
        #expect(gate.entered == ["blocked"])
        #expect(await sink.results.isEmpty)
    }
}
#endif
