import Foundation
import MarkdownRenderKit

/// Session-owned task admission. The injected cache contains completed leases only.
@MainActor
package final class SVGBlockLoadCoordinator {
    private let cache: RenderedResourceCache
    private var tasks: [SVGBlockCacheKey: Task<Void, Never>] = [:]
    private var pending: [SVGBlockCacheKey: RenderedResourceLease] = [:]
    private var epoch: UInt64 = 0
    package private(set) var generation: UInt64 = 0
    package private(set) var configuration: SVGRendererConfiguration?

    package init(cache: RenderedResourceCache = .shared) {
        self.cache = cache
    }

    package func configure(_ configuration: SVGRendererConfiguration?) {
        guard self.configuration?.configurationID != configuration?.configurationID else { return }
        self.cancelAll()
        self.configuration = configuration
        self.generation += 1
    }

    package func cancelAll() {
        self.epoch += 1
        for task in self.tasks.values {
            task.cancel()
        }
        self.tasks.removeAll()
        for lease in self.pending.values {
            lease.release()
        }
        self.pending.removeAll()
    }

    package func publication(for key: SVGBlockCacheKey) -> RenderedResourceLease? {
        guard let lease = self.pending.removeValue(forKey: key) else { return self.cache.publication(for: .svg(key)) }
        let publication = lease.record.acquireLease()
        lease.release()
        return publication
    }

    @discardableResult
    package func load(
        _ key: SVGBlockCacheKey, isCurrent: @escaping @MainActor () -> Bool,
        completed: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>? {
        guard let configuration, configuration.configurationID == key.configurationID,
              isCurrent(), !self.cache.isNegative(.svg(key)) else { return nil }
        if let cached = self.cache.publication(for: .svg(key)) {
            cached.release()
            return nil
        }
        if let task = self.tasks[key] { return task }
        let renderer = configuration.renderer
        let epoch = self.epoch
        let task = Task { [weak self] in
            let outcome = await renderer.render(svg: key.svg, availableWidth: key.availableWidth, scale: key.rasterScale)
            guard let self, self.epoch == epoch else { return }
            self.tasks[key] = nil
            guard !Task.isCancelled, isCurrent() else { return }
            switch outcome {
            case .rendered(let result):
                let image: PlatformImage
                do { image = try result.image.materialize() }
                catch {
                    if (error as? RenderedImage.Failure)?.isDeterministic == true { self.cache.insertNegative(.svg(key)) }
                    return
                }
                let flight = RenderedResourceRecord(image: image, baselineOffset: 0).acquireLease()
                self.cache.insert(flight, for: .svg(key))
                self.pending.removeValue(forKey: key)?.release()
                self.pending[key] = flight
                completed()
            case .failed: self.cache.insertNegative(.svg(key))
            case .transientFailure, .cancelled: break
            }
        }
        self.tasks[key] = task
        return task
    }

    isolated deinit {
        for task in tasks.values {
            task.cancel()
        }
        for lease in pending.values {
            lease.release()
        }
    }
}
