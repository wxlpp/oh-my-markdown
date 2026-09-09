import Foundation
import MarkdownRenderKit

/// One MainActor materialization; owners retain independent, idempotent leases.
@MainActor
package final class RenderedResourceRecord {
    package let id = UUID()
    package let image: PlatformImage
    package let baselineOffset: Double
    package private(set) var ownerCount = 0

    package init(image: PlatformImage, baselineOffset: Double) {
        self.image = image
        self.baselineOffset = baselineOffset
    }

    package func acquireLease() -> RenderedResourceLease {
        self.ownerCount += 1
        return RenderedResourceLease(record: self)
    }

    fileprivate func relinquish() {
        precondition(self.ownerCount > 0)
        self.ownerCount -= 1
    }
}

@MainActor
package final class RenderedResourceLease: RenderedResourceOwning {
    package let record: RenderedResourceRecord
    private var released = false
    package var image: PlatformImage {
        self.record.image
    }

    package var baselineOffset: Double {
        self.record.baselineOffset
    }

    fileprivate init(record: RenderedResourceRecord) {
        self.record = record
    }

    package func acquirePublication() -> any RenderedResourceOwning {
        precondition(!self.released)
        return self.record.acquireLease()
    }

    package func release() {
        guard !self.released else { return }
        self.released = true
        self.record.relinquish()
    }

    isolated deinit {
        if !released { record.relinquish() }
    }
}

package enum RenderedResourceKey: Hashable {
    case math(MathCacheKey)
    case svg(SVGBlockCacheKey)
}

/// Shared completed residency only. Tasks always belong to a session's coordinator.
@MainActor
package final class RenderedResourceCache {
    package static let shared = RenderedResourceCache()
    private var values: [RenderedResourceKey: RenderedResourceLease] = [:]
    private var order: [RenderedResourceKey] = []
    private var negative: [RenderedResourceKey: Duration] = [:]
    private var negativeOrder: [RenderedResourceKey] = []
    private let clock: any RenderSessionClock
    package init(clock: any RenderSessionClock = ContinuousRenderSessionClock()) {
        self.clock = clock
    }

    package func publication(for key: RenderedResourceKey) -> RenderedResourceLease? {
        guard let value = self.values[key] else { return nil }
        self.order.removeAll { $0 == key }
        self.order.append(key)
        return value.record.acquireLease()
    }

    package func insert(_ lease: RenderedResourceLease, for key: RenderedResourceKey) {
        self.values.removeValue(forKey: key)?.release()
        self.values[key] = lease.record.acquireLease()
        self.order.removeAll { $0 == key }
        self.order.append(key)
        if self.order.count > 256 { self.values.removeValue(forKey: self.order.removeFirst())?.release() }
    }

    package func isNegative(_ key: RenderedResourceKey) -> Bool {
        guard let expiry = self.negative[key] else { return false }
        self.negativeOrder.removeAll { $0 == key }
        guard self.clock.now() < expiry else { self.negative[key] = nil; return false }
        self.negativeOrder.append(key)
        return true
    }

    package func insertNegative(_ key: RenderedResourceKey) {
        self.negative[key] = self.clock.now() + .seconds(60)
        self.negativeOrder.removeAll { $0 == key }
        self.negativeOrder.append(key)
        if self.negativeOrder.count > 128 { self.negative[self.negativeOrder.removeFirst()] = nil }
    }

    isolated deinit { for value in values.values {
        value.release()
    } }
}
