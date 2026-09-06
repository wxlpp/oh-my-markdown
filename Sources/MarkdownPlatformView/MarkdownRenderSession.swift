import Foundation
import MarkdownCore
import MarkdownRenderKit

package actor MarkdownRenderSession: ParseResultSink {
    package nonisolated let id: RenderSessionID
    package nonisolated let registry: RenderSessionSinkRegistry
    private nonisolated let token = ParseSessionToken()
    private let executor: ParseExecutor
    private let clock: any RenderSessionClock
    private var availableWidth: Double
    private var placeholderMode: PlaceholderMode
    private let prepareInput: RenderSessionPreparation
    private var source = ""
    private var configuration: RenderConfigurationSnapshot?
    private var suppliedDocument: MarkdownDocument?
    package private(set) var currentToken: RenderCommitToken?
    package private(set) var submission: ParseSubmission?
    private var retryTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var deadline: Duration = .zero
    private var dismantled = false

    package init(
        id: RenderSessionID = .init(rawValue: UUID()), executor: ParseExecutor = .shared,
        registry: RenderSessionSinkRegistry, clock: any RenderSessionClock = ContinuousRenderSessionClock(),
        availableWidth: Double = 320, placeholderMode: PlaceholderMode = .static,
        configuration: RenderConfigurationSnapshot? = nil,
        prepare: @escaping RenderSessionPreparation = MarkdownRenderSession.prepare
    ) {
        self.id = id
        self.executor = executor
        self.registry = registry
        self.clock = clock
        self.availableWidth = availableWidth
        self.placeholderMode = placeholderMode
        self.configuration = configuration
        self.prepareInput = prepare
    }

    deinit {
        token.revoke()
        retryTask?.cancel()
        preparationTask?.cancel()
        Task { [executor, token] in await executor.tombstone(token) }
    }

    package func handle(_ event: RenderSessionEvent) async {
        guard !self.dismantled, event.commitToken.sessionID == self.id,
              event.commitToken.sequence > (self.currentToken?.sequence ?? 0)
        else { return }
        // The driver revokes synchronously before yielding teardown. That event must
        // still enter the actor to cancel sleeping retries and remove queued work.
        if case .dismantle = event.mutation {
            self.currentToken = event.commitToken
            await self.dismantle()
            return
        }
        guard !self.token.isRevoked else { return }
        self.currentToken = event.commitToken
        self.retryTask?.cancel()
        self.retryTask = nil
        self.preparationTask?.cancel()
        self.preparationTask = nil
        self.submission = nil
        switch event.mutation {
        case .setSource(let value, let configuration):
            self.source = value
            self.configuration = configuration
            self.suppliedDocument = nil
            self.placeholderMode = .static
        case .setDocument(let document, let configuration):
            self.source = ""
            self.suppliedDocument = document
            self.configuration = configuration
        case .append(let delta):
            self.source.append(delta)
            self.suppliedDocument = nil
            self.placeholderMode = .streaming
        case .replaceConfiguration(let configuration): self.configuration = configuration
        case .replaceWidth(let width): self.availableWidth = max(1, width)
        case .dismantle:
            await self.dismantle()
            return
        }
        guard let configuration else { return }
        // A caller can reuse a configuration snapshot. The driver's generation,
        // rather than its incoming generation field, owns every prepared resource ID.
        self.configuration = RenderConfigurationSnapshot(
            id: configuration.id, typography: configuration.typography, colors: configuration.colors,
            spacing: configuration.spacing, generation: event.commitToken.configurationGeneration,
            mathScale: configuration.mathScale
        )
        self.deadline = self.clock.now() + .seconds(2)
        if let document = self.suppliedDocument {
            let submission = ParseSubmission(id: UUID(), sessionToken: token, commitToken: event.commitToken, attempt: 1)
            self.submission = submission
            self.receive(.parsed(submission: submission, document: document))
            return
        }
        await self.submit(commitToken: event.commitToken, attempt: 1)
    }

    package func dismantle() async {
        self.invalidateAdmission()
        guard !self.dismantled else { return }
        self.dismantled = true
        self.retryTask?.cancel()
        self.retryTask = nil
        self.preparationTask?.cancel()
        self.preparationTask = nil
        self.submission = nil
        self.source = ""
        self.configuration = nil
        self.suppliedDocument = nil
        await self.executor.tombstone(self.token)
    }

    /// Synchronous invalidation closes the gap before an actor teardown command runs.
    package nonisolated func invalidateAdmission() {
        self.token.revoke()
    }

    private func submit(commitToken: RenderCommitToken, attempt: UInt8) async {
        guard !self.dismantled, !self.token.isRevoked, self.currentToken == commitToken else { return }
        let next = ParseSubmission(id: UUID(), sessionToken: token, commitToken: commitToken, attempt: attempt)
        self.submission = next
        let admission = await executor.enqueue(ParseJob(submission: next, source: self.source), sink: self)
        // enqueue is short but crossing actors still permits a newer event/teardown.
        guard !self.dismantled, !self.token.isRevoked, self.submission == next, self.currentToken == commitToken else { return }
        if admission == .busy { self.receive(.busy(submission: next)) }
    }

    /// Registry promotion retains this actor only for this non-suspending command.
    /// Parsing, retry clocks, preparation and MainActor delivery are never awaited here.
    package func receive(_ result: ParseExecutorResult) {
        let received = result.submission
        guard !self.dismantled, !self.token.isRevoked, self.submission == received, self.currentToken == received.commitToken else { return }
        switch result {
        case .stale:
            break
        case .busy:
            guard self.retryTask == nil else { return }
            if received.attempt >= 3 || self.clock.now() >= self.deadline {
                self.submission = nil
                self.publish(error: .parseBusy, token: received.commitToken)
            } else {
                let clock = clock
                self.retryTask = Task { [weak self, clock, received] in
                    do { try await clock.sleep(for: .milliseconds(250)) } catch { return }
                    guard !Task.isCancelled else { return }
                    await self?.retry(received)
                }
            }
        case .parsed(_, let document):
            guard let configuration else { return }
            let input = RenderInput(
                document: document, source: suppliedDocument == nil ? self.source : nil, availableWidth: self.availableWidth,
                configuration: configuration, placeholderMode: self.placeholderMode
            )
            self.preparationTask?.cancel()
            let prepare = self.prepareInput
            self.preparationTask = Task { [weak self, prepare, input, received] in
                do {
                    let model = try await prepare(input)
                    try Task.checkCancellation()
                    await self?.publishPrepared(model, configuration: input.configuration, submission: received)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.preparationFailed(received)
                }
            }
        }
    }

    @concurrent package static func prepare(_ input: RenderInput) async throws -> RenderDisplayModel {
        try Task.checkCancellation()
        return try RenderPreparer(configuration: input.configuration).prepare(input)
    }

    private func publishPrepared(
        _ model: RenderDisplayModel, configuration: RenderConfigurationSnapshot,
        submission received: ParseSubmission
    ) {
        guard !self.dismantled, !self.token.isRevoked, self.submission == received,
              self.currentToken == received.commitToken else { return }
        self.submission = nil
        self.preparationTask = nil
        self.registry.enqueue(.snapshot(model: model, configuration: configuration), token: received.commitToken)
    }

    private func preparationFailed(_ received: ParseSubmission) {
        guard !self.dismantled, !self.token.isRevoked, self.submission == received,
              self.currentToken == received.commitToken else { return }
        self.submission = nil
        self.preparationTask = nil
        self.publish(error: .preparationFailed, token: received.commitToken)
    }

    private func retry(_ previous: ParseSubmission) async {
        guard !self.dismantled, !self.token.isRevoked, self.submission == previous, self.currentToken == previous.commitToken else { return }
        self.retryTask = nil
        if self.clock.now() >= self.deadline {
            self.submission = nil
            self.publish(error: .parseBusy, token: previous.commitToken)
        } else {
            await self.submit(commitToken: previous.commitToken, attempt: previous.attempt + 1)
        }
    }

    private func publish(error: RenderSessionError, token: RenderCommitToken) {
        self.registry.enqueue(.error(error), token: token)
    }
}

@MainActor
package protocol RenderSessionDriving: AnyObject {
    func send(_ mutation: RenderSessionMutation)
    var resourceTaskOwner: RenderSessionResourceTaskOwner { get }
}

/// Owns compatibility wrapper work until the resource coordinators are replaced.
/// Cancelling a wrapper does not claim cancellation of legacy glyph producers.
@MainActor
package final class RenderSessionResourceTaskOwner {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    package var count: Int {
        self.tasks.count
    }

    @discardableResult
    package func start(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [weak self] in
            defer { self?.tasks[id] = nil }
            guard !Task.isCancelled else { return }
            await operation()
        }
        self.tasks[id] = task
        return task
    }

    package func cancelAll() {
        for task in self.tasks.values {
            task.cancel()
        }
        self.tasks.removeAll()
    }

    isolated deinit {
        for task in tasks.values {
            task.cancel()
        }
    }
}

@MainActor
package final class MarkdownRenderSessionDriver: RenderSessionDriving {
    package let resourceTaskOwner = RenderSessionResourceTaskOwner()
    private let session: MarkdownRenderSession
    private let continuation: AsyncStream<RenderSessionEvent>.Continuation
    private let pump: Task<Void, Never>
    private var sequence: UInt64 = 0
    private var sourceRevision: UInt64 = 0
    private var configurationGeneration: UInt64 = 0
    private var dismantled = false

    package init(session: MarkdownRenderSession) {
        self.session = session
        let (stream, continuation) = AsyncStream<RenderSessionEvent>.makeStream()
        self.continuation = continuation
        self.pump = Task { [weak session] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                // The optional promotion ends with this one short command, before next().
                await session?.handle(event)
            }
        }
    }

    package func send(_ mutation: RenderSessionMutation) {
        guard !self.dismantled else { return }
        self.sequence += 1
        switch mutation {
        case .setSource, .setDocument:
            self.sourceRevision += 1
            self.configurationGeneration += 1
        case .append: self.sourceRevision += 1
        case .replaceConfiguration, .replaceWidth: self.configurationGeneration += 1
        case .dismantle:
            self.dismantled = true
            self.resourceTaskOwner.cancelAll()
            self.session.invalidateAdmission()
            self.session.registry.revokeAndUnregister(self.session.id)
        }
        let token = RenderCommitToken(
            sessionID: session.id, sequence: self.sequence, sourceRevision: self.sourceRevision,
            configurationGeneration: self.configurationGeneration
        )
        if !self.dismantled { self.session.registry.authorize(token) }
        self.continuation.yield(RenderSessionEvent(mutation: mutation, commitToken: token))
        if self.dismantled { self.continuation.finish() }
    }

    isolated deinit {
        resourceTaskOwner.cancelAll()
        session.invalidateAdmission()
        session.registry.revokeAndUnregister(session.id)
        continuation.finish()
        pump.cancel()
    }
}
