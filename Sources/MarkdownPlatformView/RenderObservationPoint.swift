import Foundation
import Synchronization

/// A place where a component reports that its observable state can have moved.
///
/// It exists for tests: waiting for a condition to become true otherwise means
/// re-checking it on a timer, and a timer is a race against the work it is
/// timing. An observer here lets a test wait for the event it is about to assert
/// on. Signalling more often than necessary is safe — a waiter re-checks its own
/// condition — but never signalling turns a wait into a hang, so the signal
/// belongs at the state's single choke point rather than at each call site.
///
/// Production installs no observers: `signal()` then takes one uncontended lock
/// and iterates an empty dictionary.
package final class RenderObservationPoint: Sendable {
    private let observers = Mutex<[UUID: @Sendable () -> Void]>([:])

    package init() {}

    /// Multiple observers rather than one slot: a test can be waiting on the
    /// same component from two places, and a single slot would silently drop the
    /// first waiter's signal and hang it.
    package func add(_ observer: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        self.observers.withLock { $0[id] = observer }
        return id
    }

    package func remove(_ id: UUID) {
        self.observers.withLock { $0[id] = nil }
    }

    package func signal() {
        // Copied out of the lock: an observer resumes continuations, and holding
        // the lock across that invites a deadlock through a re-entrant signal.
        let current = self.observers.withLock { Array($0.values) }
        for observer in current {
            observer()
        }
    }
}
