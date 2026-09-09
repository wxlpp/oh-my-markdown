import Foundation
import MarkdownCore
import MarkdownRenderKit
import Synchronization

package struct ParseSessionToken: Hashable {
    private final class Lifetime: Sendable {
        let revoked = Mutex(false)
    }

    package let rawValue: UUID
    private let lifetime = Lifetime()

    /// Identity and lifetime are created together. Copy this value to refer to
    /// the same session; callers cannot reconstruct an identity with a fresh lifetime.
    package init() {
        self.rawValue = UUID()
    }

    package var isRevoked: Bool {
        self.lifetime.revoked.withLock { $0 }
    }

    package func revoke() {
        self.lifetime.revoked.withLock { $0 = true }
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(self.rawValue)
    }
}

package struct RenderSessionID: Hashable { package let rawValue: UUID }

package struct RenderCommitToken: Hashable {
    package let sessionID: RenderSessionID
    package let sequence: UInt64
    package let sourceRevision: UInt64
    package let configurationGeneration: UInt64
}

package struct RenderImageRequest: Hashable {
    package let token: RenderCommitToken
    package let source: String
}

package enum RenderImageLoadState {
    /// `deferred` is a transient residency/admission outcome that keeps the
    /// accessible placeholder without recording a deterministic failure.
    case loading, failed, deferred
}

package struct ParseSubmission: Hashable {
    package let id: UUID
    package let sessionToken: ParseSessionToken
    package let commitToken: RenderCommitToken
    package let attempt: UInt8
}

package struct ParseJob {
    package let submission: ParseSubmission
    private let suppliedSource: String?
    package let sourceBuffer: IncrementalSourceBuffer?
    package let previousParse: IncrementalParseResult?
    package let workMetrics: ParseWorkMetrics
    package let attemptRecorder: ParseAttemptRecorder
    package var source: String {
        if let suppliedSource { return suppliedSource }
        var metrics = ParseWorkMetrics()
        // Explicit compatibility facade for injected synchronous parsers. Its
        // immutable value cannot change merely because the worker was cancelled.
        // The production parser consumes sourceBuffer's measured tail directly.
        let result = (try? self.sourceBuffer?.materialize(from: 0, metrics: &metrics, cancellable: false)) ?? ""
        self.sourceBuffer?.recorder?.recordFacade(metrics)
        return result
    }

    package init(submission: ParseSubmission, source: String) {
        self.submission = submission; self.suppliedSource = source
        self.sourceBuffer = nil; self.previousParse = nil
        let recorder = ParseAttemptRecorder()
        self.attemptRecorder = recorder; self.workMetrics = .init(recording: recorder)
    }

    package init(
        submission: ParseSubmission,
        buffer: IncrementalSourceBuffer,
        previous: IncrementalParseResult?,
        metrics: ParseWorkMetrics
    ) {
        self.submission = submission; self.suppliedSource = nil
        let recorder = ParseAttemptRecorder()
        self.sourceBuffer = buffer.recordingFacades(with: ParseWorkRecorder(parent: buffer.recorder, attempt: recorder))
        self.previousParse = previous
        self.attemptRecorder = recorder; self.workMetrics = metrics.recording(recorder, seed: true)
    }
}

package enum ParseExecutorResult {
    case parsed(submission: ParseSubmission, document: MarkdownDocument)
    case busy(submission: ParseSubmission)
    case stale(submission: ParseSubmission)

    package var submission: ParseSubmission {
        switch self {
        case .parsed(let submission, _), .busy(let submission), .stale(let submission): submission
        }
    }
}

package enum ParseAdmission: Equatable {
    case started, queued, replacedPending, busy
}

package struct ParseExecutorDiagnostics: Equatable {
    package let activeCount: Int
    package let waitingTokenCount: Int
    package let registryCount: Int
}

package enum ParseAttemptDisposition { case accepted, discarded }

package struct ParseAttemptReport {
    package let submission: ParseSubmission
    package let disposition: ParseAttemptDisposition
    package let metrics: ParseWorkMetrics
}

package struct ParseAttemptDiagnostics {
    package private(set) var accepted = ParseWorkMetrics()
    package private(set) var discarded = ParseWorkMetrics()
    package private(set) var acceptedCount = 0
    package private(set) var discardedCount = 0
    package var totalAttempted: ParseWorkMetrics {
        var total = self.accepted; total.add(self.discarded); return total
    }

    package mutating func record(_ report: ParseAttemptReport) {
        switch report.disposition {
        case .accepted: self.accepted.add(report.metrics); self.acceptedCount += 1
        case .discarded: self.discarded.add(report.metrics); self.discardedCount += 1
        }
    }
}

/// Executor-instance parse work includes orphaned jobs after sink teardown.
/// Session preparation is tracked separately by each attempt recorder.
package struct ParseExecutorWorkDiagnostics {
    package var completed = ParseWorkMetrics()
    package var orphaned = ParseWorkMetrics()
    package var completedCount = 0
    package var orphanedCount = 0
    package var totalAttempted: ParseWorkMetrics {
        var total = self.completed; total.add(self.orphaned); return total
    }
}

package typealias SynchronousParser = @Sendable (ParseJob) -> MarkdownDocument
package typealias RenderSessionPreparation = @Sendable (RenderInput) async throws -> RenderDisplayModel

package struct ParseWorkerOutput {
    package let job: ParseJob
    package let document: MarkdownDocument?
    package let incremental: IncrementalParseResult?
}

package struct ActiveParse {
    package let worker: Task<ParseWorkerOutput, Never>
    package let monitor: Task<Void, Never>
}

package enum ParseTokenState {
    case waiting(latest: ParseJob)
    case active(ActiveParse, latestPending: ParseJob?, tombstoned: Bool)
}

package protocol ParseResultSink: Actor {
    func receive(_ result: ParseExecutorResult) async
    func receive(_ result: ParseExecutorResult, incremental: IncrementalParseResult) async
}

extension ParseResultSink {
    package func receive(_ result: ParseExecutorResult, incremental: IncrementalParseResult) async {
        await self.receive(result)
    }
}

package enum RenderSessionMutation {
    case setSource(String, RenderConfigurationSnapshot)
    case setDocument(MarkdownDocument, RenderConfigurationSnapshot)
    case append(String)
    case replaceConfiguration(RenderConfigurationSnapshot)
    case replaceImageConfiguration(MarkdownImageConfiguration)
    /// Carries nothing: the policy, the handler and their identities all live on
    /// the main-actor driver, which is also what activation revalidates against.
    /// Shipping copies into the session would be a second source of truth.
    case replaceLinkConfiguration
    case replaceWidth(Double)
    case dismantle
}

package struct RenderSessionEvent {
    package let mutation: RenderSessionMutation
    package let commitToken: RenderCommitToken
}

package enum RenderSessionError: Error, Equatable {
    case parseBusy
    case preparationFailed
}

/// A delivery owns only immutable render values, never the session or its sink.
package enum RenderSessionDelivery {
    case snapshot(model: RenderDisplayModel, configuration: RenderConfigurationSnapshot)
    case error(RenderSessionError)
}

@MainActor
package protocol RenderSessionSink: AnyObject {
    func replaceSnapshot(_ snapshot: RenderSnapshot, token: RenderCommitToken)
    func receive(error: RenderSessionError)
}

/// Production platform sinks supply their MainActor-owned compatibility caches.
@MainActor
package protocol RenderSessionResourceProviding: AnyObject {
    func resolvedResources(for model: RenderDisplayModel, configuration: RenderConfigurationSnapshot) -> ResolvedResourceSnapshot
    /// Admits the new owners, materializes and installs, all without suspension.
    func installSnapshot(model: RenderDisplayModel, configuration: RenderConfigurationSnapshot, token: RenderCommitToken)
}

@MainActor
package final class WeakRenderSessionSink {
    package weak var value: (any RenderSessionSink)?
    package init(_ value: any RenderSessionSink) {
        self.value = value
    }
}

@MainActor
package final class RenderSessionSinkRegistry {
    private var sinks: [RenderSessionID: WeakRenderSessionSink] = [:]
    private var authorizedTokens: [RenderSessionID: RenderCommitToken] = [:]

    package init() {}
    package var count: Int {
        self.sinks.count
    }

    package func register(_ sink: any RenderSessionSink, for id: RenderSessionID) {
        self.sinks[id] = WeakRenderSessionSink(sink)
    }

    package func authorize(_ token: RenderCommitToken) {
        guard self.sinks[token.sessionID]?.value != nil else {
            self.revokeAndUnregister(token.sessionID)
            return
        }
        self.authorizedTokens[token.sessionID] = token
    }

    /// Queue a value-only delivery without making the session wait for MainActor.
    /// The task owns this registry (which has weak sinks), never a session, driver
    /// or promoted sink. Authorization and all effects share one synchronous turn.
    package nonisolated func enqueue(_ delivery: RenderSessionDelivery, token: RenderCommitToken) {
        Task { @MainActor [registry = self, delivery, token] in
            registry.withAuthorizedSink(for: token) { sink in
                switch delivery {
                case .snapshot(let model, let configuration):
                    if let provider = sink as? any RenderSessionResourceProviding {
                        provider.installSnapshot(model: model, configuration: configuration, token: token)
                    } else {
                        sink.replaceSnapshot(
                            RenderMaterializer(configuration: configuration).materialize(model, resources: .init(values: [:])),
                            token: token
                        )
                    }
                case .error(let error):
                    sink.receive(error: error)
                }
            }
        }
    }

    /// Authorization, weak promotion and every side effect form one MainActor turn.
    /// An old actor message may arrive, but cannot cross this synchronous gate.
    @discardableResult
    package func withAuthorizedSink(
        for token: RenderCommitToken,
        _ body: @MainActor (any RenderSessionSink) throws -> Void
    ) rethrows -> Bool {
        guard self.authorizedTokens[token.sessionID] == token,
              let sink = sinks[token.sessionID]?.value
        else { return false }
        try body(sink)
        return true
    }

    package func revokeAndUnregister(_ id: RenderSessionID) {
        self.authorizedTokens[id] = nil
        self.sinks[id] = nil
    }
}

package protocol RenderSessionClock: Sendable {
    func now() -> Duration
    func sleep(for duration: Duration) async throws
}

package struct ContinuousRenderSessionClock: RenderSessionClock {
    private let origin = ContinuousClock.now
    package init() {}
    package func now() -> Duration {
        self.origin.duration(to: .now)
    }

    package func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
