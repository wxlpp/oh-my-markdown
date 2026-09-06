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

    /// Construct once per logical session, then copy the token. Reconstructing the
    /// same UUID would create a different lifetime and is not a supported operation.
    package init(rawValue: UUID) {
        self.rawValue = rawValue
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

package struct ParseSubmission: Hashable {
    package let id: UUID
    package let sessionToken: ParseSessionToken
    package let commitToken: RenderCommitToken
    package let attempt: UInt8
}

package struct ParseJob {
    package let submission: ParseSubmission
    package let source: String
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

package typealias SynchronousParser = @Sendable (ParseJob) -> MarkdownDocument
package typealias RenderSessionPreparation = @Sendable (RenderInput) async throws -> RenderDisplayModel

package struct ParseWorkerOutput {
    package let job: ParseJob
    package let document: MarkdownDocument
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
}

package enum RenderSessionMutation {
    case setSource(String, RenderConfigurationSnapshot)
    case append(String)
    case replaceConfiguration(RenderConfigurationSnapshot)
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

@MainActor
package protocol RenderSessionSink: AnyObject {
    func replaceSnapshot(_ snapshot: RenderSnapshot, token: RenderCommitToken)
    func receive(error: RenderSessionError)
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
