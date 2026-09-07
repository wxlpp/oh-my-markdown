import Foundation
import MarkdownCore
import MarkdownRenderKit

package actor MarkdownRenderSession: ParseResultSink {
    package nonisolated let id: RenderSessionID
    package nonisolated let registry: RenderSessionSinkRegistry
    private nonisolated let token = ParseSessionToken()
    private let executor: ParseExecutor
    package nonisolated let clock: any RenderSessionClock
    private var availableWidth: Double
    private var placeholderMode: PlaceholderMode
    private let prepareInput: RenderSessionPreparation
    private let usesDefaultPreparation: Bool
    private let diagnostics: (@Sendable (ParseSubmission, ParseWorkMetrics) async -> Void)?
    private let attemptSink: (@Sendable (ParseAttemptReport) async -> Void)?
    private var attempts: [ParseSubmission: ParseAttemptRecorder] = [:]
    package private(set) var attemptDiagnostics = ParseAttemptDiagnostics()
    private let workRecorder: ParseWorkRecorder
    private var sourceBuffer: IncrementalSourceBuffer
    package var facadeMaterializationCount: Int {
        self.workRecorder.snapshot().facadeMaterializationCount
    }

    private var pendingWorkMetrics = ParseWorkMetrics()
    private var latestParse: IncrementalParseResult?
    private var incomingParse: IncrementalParseResult?
    private var previousModel: RenderDisplayModel?
    private var previousModelWitness: IncrementalSourceBuffer.Witness?
    private var previousModelConfiguration: RenderConfigurationSnapshot?
    package private(set) var deltaPreparationCount = 0
    package private(set) var lastWorkMetrics: ParseWorkMetrics?
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
        prepare: RenderSessionPreparation? = nil,
        diagnostics: (@Sendable (ParseSubmission, ParseWorkMetrics) async -> Void)? = nil,
        attemptDiagnostics: (@Sendable (ParseAttemptReport) async -> Void)? = nil
    ) {
        self.id = id
        let recorder = ParseWorkRecorder()
        self.workRecorder = recorder
        self.sourceBuffer = IncrementalSourceBuffer(recorder: recorder)
        self.executor = executor
        self.registry = registry
        self.clock = clock
        self.availableWidth = availableWidth
        self.placeholderMode = placeholderMode
        self.configuration = configuration
        self.prepareInput = prepare ?? MarkdownRenderSession.prepare
        self.usesDefaultPreparation = prepare == nil
        self.diagnostics = diagnostics
        self.attemptSink = attemptDiagnostics
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
            self.sourceBuffer = IncrementalSourceBuffer(recorder: self.workRecorder)
            self.pendingWorkMetrics = ParseWorkMetrics()
            do { try self.sourceBuffer.append(value, metrics: &self.pendingWorkMetrics) }
            catch { self.publish(error: .preparationFailed, token: event.commitToken); return }
            self.latestParse = nil
            self.configuration = configuration
            self.suppliedDocument = nil
            self.placeholderMode = .static
        case .setDocument(let document, let configuration):
            self.sourceBuffer = IncrementalSourceBuffer(recorder: self.workRecorder)
            self.latestParse = nil
            self.suppliedDocument = document
            self.configuration = configuration
        case .append(let delta):
            do { try self.sourceBuffer.append(delta, metrics: &self.pendingWorkMetrics) }
            catch { self.publish(error: .preparationFailed, token: event.commitToken); return }
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
            self.attempts[submission] = ParseAttemptRecorder()
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
        self.sourceBuffer = IncrementalSourceBuffer(recorder: self.workRecorder)
        self.latestParse = nil
        self.incomingParse = nil
        self.previousModel = nil
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
        let job = ParseJob(submission: next, buffer: self.sourceBuffer, previous: self.latestParse, metrics: self.pendingWorkMetrics)
        self.pendingWorkMetrics = ParseWorkMetrics()
        self.attempts[next] = job.attemptRecorder
        let admission = await executor.enqueue(job, sink: self)
        if admission == .busy { self.finishAttempt(next, disposition: .discarded) }
        // enqueue is short but crossing actors still permits a newer event/teardown.
        guard !self.dismantled, !self.token.isRevoked, self.submission == next, self.currentToken == commitToken else { return }
        if admission == .busy { self.receive(.busy(submission: next)) }
    }

    /// Registry promotion retains this actor only for this non-suspending command.
    /// Parsing, retry clocks, preparation and MainActor delivery are never awaited here.
    package func receive(_ result: ParseExecutorResult) {
        let received = result.submission
        guard !self.dismantled, !self.token.isRevoked, self.submission == received, self.currentToken == received.commitToken else {
            self.finishAttempt(received, disposition: .discarded)
            return
        }
        switch result {
        case .stale:
            self.finishAttempt(received, disposition: .discarded)
            self.submission = nil
        case .busy:
            self.finishAttempt(received, disposition: .discarded)
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
            guard let configuration else { self.finishAttempt(received, disposition: .discarded); return }
            let incremental = self.incomingParse
            self.incomingParse = nil
            let base = self.previousModelWitness == self.latestParse?.state.sourceWitness
                && self.previousModelConfiguration == configuration
                && self.previousModel?.availableWidth == self.availableWidth
                && self.previousModel?.placeholderMode == self.placeholderMode ? self.previousModel : nil
            if let incremental { self.latestParse = incremental }
            // Each input's explicit facades follow its attempt, including discarded
            // preparation. The parent observer keeps session-wide facade diagnostics.
            let facadeRecorder = ParseWorkRecorder(parent: self.workRecorder, attempt: self.attempts[received])
            let observedDocument = MarkdownDocument(blockStorage: document.blockStorage, recorder: facadeRecorder)
            let input = RenderInput(
                document: observedDocument, source: nil, availableWidth: self.availableWidth,
                configuration: configuration, placeholderMode: self.placeholderMode,
                previousModel: base, sourceBuffer: self.suppliedDocument == nil ? self.sourceBuffer.recordingFacades(with: facadeRecorder) : nil,
                attemptRecorder: self.attempts[received]
            )
            self.preparationTask?.cancel()
            let prepare = self.prepareInput
            let useBuiltIn = self.usesDefaultPreparation
            self.preparationTask = Task { [weak self, prepare, input, received, incremental, base, useBuiltIn] in
                do {
                    let (model, metrics, usedDelta) = try await Self.prepareUpdate(
                        input, incremental: incremental, base: base, useBuiltIn: useBuiltIn, prepare: prepare
                    )
                    try Task.checkCancellation()
                    await self?.publishPrepared(
                        model,
                        configuration: input.configuration,
                        submission: received,
                        witness: incremental?.state.sourceWitness,
                        metrics: metrics,
                        usedDelta: usedDelta
                    )
                } catch is CancellationError {
                    await self?.finishAttempt(received, disposition: .discarded)
                    return
                } catch {
                    await self?.finishAttempt(received, disposition: .discarded)
                    guard !Task.isCancelled else { return }
                    await self?.preparationFailed(received)
                }
            }
        }
    }

    @concurrent private static func prepareUpdate(
        _ input: RenderInput, incremental: IncrementalParseResult?, base: RenderDisplayModel?,
        useBuiltIn: Bool, prepare: RenderSessionPreparation
    ) async throws -> (RenderDisplayModel, ParseWorkMetrics, Bool) {
        try Task.checkCancellation()
        var metrics = input.attemptRecorder.map { $0.snapshot().recording($0) } ?? incremental?.metrics ?? ParseWorkMetrics()
        let model: RenderDisplayModel
        let usedDelta = useBuiltIn && incremental != nil && base != nil
        if usedDelta, let incremental, let base {
            let delta = try RenderPreparer(configuration: input.configuration).prepareDelta(
                input, replacing: incremental.replacedPreviousRange,
                with: incremental.changedBlockRange, metrics: &metrics
            )
            let prepared = try await delta.preparingSyntax(metrics: &metrics)
            model = prepared.applying(to: base, metrics: &metrics)
        } else if useBuiltIn {
            let bundles = try RenderPreparer(configuration: input.configuration).prepareBlocks(
                input, range: 0 ..< input.document.blockStorage.count, metrics: &metrics
            )
            let prepared = try await RenderDisplayModel.prepareSyntax(bundles, metrics: &metrics)
            model = RenderDisplayModel(bundles: prepared, input: input)
        } else {
            model = try await prepare(input)
        }
        try Task.checkCancellation()
        return (model, input.attemptRecorder.map { $0.snapshot().recording($0) } ?? metrics, usedDelta)
    }

    package func receive(_ result: ParseExecutorResult, incremental: IncrementalParseResult) {
        guard !self.dismantled, !self.token.isRevoked, self.submission == result.submission,
              self.currentToken == result.submission.commitToken else {
            self.finishAttempt(result.submission, disposition: .discarded)
            return
        }
        self.incomingParse = incremental
        self.receive(result)
    }

    @concurrent package static func prepare(_ input: RenderInput) async throws -> RenderDisplayModel {
        try Task.checkCancellation()
        return try await RenderPreparer(configuration: input.configuration).prepare(input).preparingSyntax(recorder: input.attemptRecorder)
    }

    private func publishPrepared(
        _ model: RenderDisplayModel, configuration: RenderConfigurationSnapshot,
        submission received: ParseSubmission, witness: IncrementalSourceBuffer.Witness?, metrics: ParseWorkMetrics, usedDelta: Bool
    ) async {
        guard !self.dismantled, !self.token.isRevoked, self.submission == received,
              self.currentToken == received.commitToken else {
            self.finishAttempt(received, disposition: .discarded)
            return
        }
        let metrics = metrics.withoutRecording
        self.submission = nil
        self.preparationTask = nil
        self.previousModel = model
        self.previousModelWitness = witness
        self.previousModelConfiguration = configuration
        self.lastWorkMetrics = metrics.withoutRecording
        if usedDelta { self.deltaPreparationCount += 1 }
        await self.diagnostics?(received, metrics)
        guard !self.dismantled, !self.token.isRevoked, self.currentToken == received.commitToken else {
            self.finishAttempt(received, disposition: .discarded)
            return
        }
        self.finishAttempt(received, disposition: .accepted)
        self.registry.enqueue(.snapshot(model: model, configuration: configuration), token: received.commitToken)
    }

    private func finishAttempt(_ submission: ParseSubmission, disposition: ParseAttemptDisposition) {
        guard let recorder = self.attempts.removeValue(forKey: submission) else { return }
        let report = ParseAttemptReport(submission: submission, disposition: disposition, metrics: recorder.snapshot())
        self.attemptDiagnostics.record(report)
        if let sink = self.attemptSink { Task { [sink, report] in await sink(report) } }
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

/// Owns all resource work and the single coalesced layout/publication clock task.
@MainActor
package final class RenderSessionResourceTaskOwner {
    package let math: MathLoadCoordinator
    package let svg: SVGBlockLoadCoordinator
    private let clock: any RenderSessionClock
    private var debounceTask: Task<Void, Never>?
    private var deferredActions: [String: @MainActor () -> Void] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    package init(cache: RenderedResourceCache = .shared, clock: any RenderSessionClock = ContinuousRenderSessionClock()) {
        self.math = MathLoadCoordinator(cache: cache)
        self.svg = SVGBlockLoadCoordinator(cache: cache)
        self.clock = clock
    }

    package func deferAction(key: String, _ action: @escaping @MainActor () -> Void) {
        self.deferredActions[key] = action
        guard self.debounceTask == nil else { return }
        let clock = self.clock
        self.debounceTask = Task { [weak self, clock] in
            do { try await clock.sleep(for: .milliseconds(33)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            let actions = self.deferredActions.values
            self.deferredActions.removeAll()
            for action in actions {
                action()
            }
        }
    }

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
        self.math.cancelAll()
        self.svg.cancelAll()
        self.debounceTask?.cancel()
        self.debounceTask = nil
        self.deferredActions.removeAll()
        for task in self.tasks.values {
            task.cancel()
        }
        self.tasks.removeAll()
    }

    isolated deinit {
        math.cancelAll()
        svg.cancelAll()
        debounceTask?.cancel()
        for task in tasks.values {
            task.cancel()
        }
    }
}

@MainActor
package final class MarkdownRenderSessionDriver: RenderSessionDriving {
    package let resourceTaskOwner: RenderSessionResourceTaskOwner
    private let session: MarkdownRenderSession
    private let continuation: AsyncStream<RenderSessionEvent>.Continuation
    private let pump: Task<Void, Never>
    private var sequence: UInt64 = 0
    private var sourceRevision: UInt64 = 0
    private var configurationGeneration: UInt64 = 0
    private var dismantled = false

    package init(session: MarkdownRenderSession) {
        self.resourceTaskOwner = RenderSessionResourceTaskOwner(clock: session.clock)
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
        self.resourceTaskOwner.cancelAll()
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
