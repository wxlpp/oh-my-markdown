import MarkdownCore
import Synchronization

package final class WeakParseResultSink: Sendable {
    private final class Storage {
        weak var value: (any ParseResultSink)?
        init(_ value: any ParseResultSink) {
            self.value = value
        }
    }

    private let storage: Mutex<Storage>
    package var value: (any ParseResultSink)? {
        self.storage.withLock { $0.value }
    }

    package init(_ value: any ParseResultSink) {
        self.storage = Mutex(Storage(value))
    }

    package func revoke() {
        self.storage.withLock { $0.value = nil }
    }
}

package actor ParseResultRegistry {
    /// Mutex owns the non-Sendable weak boxes. Nothing escapes except a Sendable actor.
    /// Synchronous registry operations keep executor admission/teardown non-reentrant.
    private nonisolated let sinks = Mutex<[ParseSessionToken: WeakParseResultSink]>([:])

    package nonisolated func register(_ sink: any ParseResultSink, for token: ParseSessionToken) {
        self.sinks.withLock { $0[token] = WeakParseResultSink(sink) }
    }

    package nonisolated func unregister(_ token: ParseSessionToken) {
        self.sinks.withLock { $0.removeValue(forKey: token)?.revoke() }
    }

    package nonisolated var count: Int {
        self.sinks.withLock { $0.count }
    }

    package nonisolated func delivery(for token: ParseSessionToken, removing: Bool = false) -> WeakParseResultSink? {
        self.sinks.withLock { removing ? $0.removeValue(forKey: token) : $0[token] }
    }

    package func publish(_ result: ParseExecutorResult, to token: ParseSessionToken) async {
        guard let ticket = delivery(for: token) else { return }
        await self.publish(result, using: ticket)
    }

    package func publish(_ result: ParseExecutorResult, using ticket: WeakParseResultSink) async {
        let sink = ticket.value
        // An already-promoted message cannot be recalled by unregister. The session's
        // full submission check and synchronous MainActor gate reject its side effects.
        // MarkdownRenderSession.receive is a non-suspending actor command: this
        // temporary promotion never spans parsing, retry, preparation or MainActor.
        await sink?.receive(result)
    }
}

package actor ParseExecutor {
    package static let shared = ParseExecutor(
        maxActive: 2, maxWaitingTokens: 64, parser: { MarkdownDocument(parsing: $0.source) }
    )

    private let maxActive: Int
    private let maxWaitingTokens: Int
    private let parser: SynchronousParser
    private let registry = ParseResultRegistry()
    private var states: [ParseSessionToken: ParseTokenState] = [:]
    private var waitingOrder: [ParseSessionToken] = []
    private var activeCount = 0

    package init(maxActive: Int, maxWaitingTokens: Int, parser: @escaping SynchronousParser) {
        precondition(maxActive > 0 && maxActive <= 2 && maxWaitingTokens >= 0 && maxWaitingTokens <= 64)
        self.maxActive = maxActive
        self.maxWaitingTokens = maxWaitingTokens
        self.parser = parser
    }

    /// Returns without awaiting parsing or storing a submit continuation.
    package func enqueue(_ job: ParseJob, sink: any ParseResultSink) -> ParseAdmission {
        let token = job.submission.sessionToken
        guard !token.isRevoked else { return .busy }
        switch self.states[token] {
        case .active(let active, let pending, let tombstoned):
            guard !tombstoned else { return .busy }
            self.registry.register(sink, for: token)
            self.states[token] = .active(active, latestPending: job, tombstoned: false)
            if let pending { self.publishStale(pending) }
            return pending == nil ? .queued : .replacedPending
        case .waiting(let previous):
            self.registry.register(sink, for: token)
            self.states[token] = .waiting(latest: job)
            self.publishStale(previous)
            return .replacedPending
        case nil:
            if self.activeCount < self.maxActive {
                self.registry.register(sink, for: token)
                self.start(job)
                return .started
            }
            guard self.waitingOrder.count < self.maxWaitingTokens else { return .busy }
            self.registry.register(sink, for: token)
            self.states[token] = .waiting(latest: job)
            self.waitingOrder.append(token)
            return .queued
        }
    }

    package func tombstone(_ token: ParseSessionToken) {
        token.revoke()
        self.registry.unregister(token)
        switch self.states[token] {
        case .active(let active, _, _):
            // Cancellation cannot stop cmark. Keep both handles and the capacity charge
            // until its actual completion, but discard all pending work immediately.
            self.states[token] = .active(active, latestPending: nil, tombstoned: true)
        case .waiting:
            self.states[token] = nil
            self.waitingOrder.removeAll { $0 == token }
        case nil: break
        }
    }

    package var diagnostics: ParseExecutorDiagnostics {
        .init(activeCount: self.activeCount, waitingTokenCount: self.waitingOrder.count, registryCount: self.registry.count)
    }

    private func start(_ job: ParseJob) {
        guard !job.submission.sessionToken.isRevoked else {
            self.states[job.submission.sessionToken] = nil
            self.registry.unregister(job.submission.sessionToken)
            return
        }
        let parser = parser
        let worker = Task.detached { [parser, job] in
            ParseWorkerOutput(job: job, document: parser(job))
        }
        let monitor = Task { [weak self, worker] in
            let output = await worker.value
            await self?.complete(output)
        }
        self.activeCount += 1
        self.states[job.submission.sessionToken] = .active(
            ActiveParse(worker: worker, monitor: monitor), latestPending: nil, tombstoned: false
        )
    }

    private func complete(_ output: ParseWorkerOutput) async {
        let token = output.job.submission.sessionToken
        guard case .active(_, let pending, let tombstoned) = states[token] else { return }
        self.activeCount -= 1
        self.states[token] = nil
        let live = !tombstoned && !token.isRevoked
        if live, let pending { self.start(pending) }
        while self.activeCount < self.maxActive, !self.waitingOrder.isEmpty {
            let next = self.waitingOrder.removeFirst()
            if case .waiting(let job) = states[next] { self.start(job) }
        }
        // Remove idle registry state before the first suspension, even if delivery
        // must queue on another actor. A ticket retains only a weak sink reference.
        let delivery = self.registry.delivery(for: token, removing: self.states[token] == nil)
        if live, let delivery {
            await self.registry.publish(.parsed(submission: output.job.submission, document: output.document), using: delivery)
        }
    }

    private func publishStale(_ job: ParseJob) {
        guard let delivery = registry.delivery(for: job.submission.sessionToken) else { return }
        Task { [registry, delivery] in
            await registry.publish(.stale(submission: job.submission), using: delivery)
        }
    }
}
