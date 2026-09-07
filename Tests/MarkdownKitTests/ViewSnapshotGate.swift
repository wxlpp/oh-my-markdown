import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Observation
import Synchronization

private final class SnapshotChangeSignal: Sendable {
    private struct State {
        var fired = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())
    func fire() {
        let waiter = self.state.withLock { state in
            guard !state.fired else { return CheckedContinuation<Void, Never>?.none }
            state.fired = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = self.state.withLock { state in
                    if state.fired { return true }
                    state.waiter = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: { self.fire() }
    }
}

/// One-shot observations of the real publication boundary; no timers or polling.
@MainActor
final class ViewSnapshotGate {
    func wait(for view: MarkdownLabelView, until condition: @MainActor () -> Bool) async {
        while !Task.isCancelled {
            let signal = SnapshotChangeSignal()
            let ready = withObservationTracking {
                _ = view.currentSnapshot
                return condition()
            } onChange: { signal.fire() }
            if ready { return }
            await signal.wait()
        }
    }
}
