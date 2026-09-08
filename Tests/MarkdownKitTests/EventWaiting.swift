import Foundation
@testable import MarkdownPlatformView
import Synchronization
import Testing

/// A count of observable events, and a way to wait for the next one without a
/// timer.
///
/// This is the whole of what replaced timing polls in this suite: the thing
/// under observation reports each change, and a waiter re-checks its condition
/// on each report. A condition that becomes true through an unreported change
/// therefore hangs rather than passing late — which is why the suites that use
/// it carry a `.timeLimit`. A deadline here would need a timer, and a timer is
/// the thing being removed.
final class EventSignal: Sendable {
    private struct State {
        var count = 0
        var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    init() {}

    var count: Int {
        self.state.withLock { $0.count }
    }

    func record() {
        let ready = self.state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.count += 1
            defer { state.waiters.removeAll { $0.0 <= state.count } }
            return state.waiters.filter { $0.0 <= state.count }.map(\.1)
        }
        for continuation in ready {
            continuation.resume()
        }
    }

    /// Suspends until `record()` has been called more than `count` times in
    /// total. Taking the count before the condition is checked is what closes
    /// the race: an event that lands between the check and the wait is already
    /// counted, so the wait returns rather than missing it.
    func next(after count: Int) async {
        await withCheckedContinuation { continuation in
            let alreadyPast = self.state.withLock { state in
                if state.count > count { return true }
                state.waiters.append((count + 1, continuation))
                return false
            }
            if alreadyPast { continuation.resume() }
        }
    }

    /// Re-checks `condition` on every reported event until it holds.
    ///
    /// The count is read *before* the condition, so an event that lands while
    /// the condition is being evaluated leaves the count already past `seen` and
    /// the wait returns at once. Reading it after would wait for the event after
    /// the one that made the condition true, and hang.
    ///
    /// Inherits the caller's isolation, so a condition over main-actor or
    /// actor-held state is evaluated where that state lives.
    func settled(isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async {
        var seen = self.count
        while await !condition() {
            await self.next(after: seen)
            seen = self.count
        }
    }
}

extension RenderObservationPoint {
    /// Re-checks `condition` on every reported change until it holds. Inherits
    /// the caller's isolation, so a condition over main-actor or actor-held
    /// state is evaluated where that state lives.
    func settled(isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async {
        let signal = EventSignal()
        let id = self.add { signal.record() }
        defer { self.remove(id) }
        await signal.settled(condition)
    }
}

extension MarkdownLabelView {
    /// Waits on the view's own render events until `condition` holds.
    func settled(_ condition: @MainActor () -> Bool) async {
        await self.observation.settled { condition() }
    }
}

extension ParseExecutor {
    /// Waits on the executor's admission, completion and teardown events.
    func settled(isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async {
        await self.observation.settled(condition)
    }
}

extension ImageResourceCoordinator {
    /// Waits on the coordinator's admission and queue changes, which is all its
    /// statistics are derived from.
    func settled(isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async {
        await self.observation.settled(condition)
    }
}

extension MarkdownRenderSession {
    /// Waits until the session has handled an event that makes `condition` hold.
    func settled(isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async {
        await self.observation.settled(condition)
    }
}
