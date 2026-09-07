import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Synchronization
import Testing

@MainActor
@Suite("SVGBlockLoadCoordinator")
struct SVGBlockLoadCoordinatorTests {
    @Test func nilRendererNoDispatch() {
        let configuration = SVGRendererConfiguration(renderer: ResourceSVGProducer())
        #expect(SVGBlockLoadCoordinator(cache: RenderedResourceCache()).load(resourceSVGKey(configuration: configuration), isCurrent: { true }, completed: {}) == nil)
    }

    @Test func renderedCachedOnce() async {
        let producer = ResourceSVGProducer()
        let configuration = SVGRendererConfiguration(renderer: producer)
        let cache = RenderedResourceCache()
        let coordinator = SVGBlockLoadCoordinator(cache: cache)
        coordinator.configure(configuration)
        let key = resourceSVGKey(configuration: configuration)
        await coordinator.load(key, isCurrent: { true }, completed: {})?.value
        let publication = coordinator.publication(for: key)
        #expect(publication?.image.size.width == 8)
        #expect(publication?.record.ownerCount == 2)
        #expect(coordinator.load(key, isCurrent: { true }, completed: {}) == nil)
        #expect(await producer.calls == 1)
        let hit = coordinator.publication(for: key)
        #expect(hit?.record === publication?.record)
        #expect(hit?.record.ownerCount == 3)
        hit?.release()
        publication?.release()
        #expect(publication?.record.ownerCount == 1)
    }

    @Test func replacementCancelsProducer() async {
        let gate = ResourceRenderGate()
        let producer = ResourceSVGProducer(gate: gate)
        let configuration = SVGRendererConfiguration(renderer: producer)
        let cache = RenderedResourceCache()
        let coordinator = SVGBlockLoadCoordinator(cache: cache)
        coordinator.configure(configuration)
        let key = resourceSVGKey(configuration: configuration)
        var publications = 0
        let task = coordinator.load(key, isCurrent: { true }, completed: { publications += 1 })
        await gate.waitForArrivals(1)
        let generation = coordinator.generation
        coordinator.configure(nil)
        #expect(coordinator.generation == generation + 1)
        await gate.open()
        await task?.value
        #expect(await gate.cancellations == 1)
        #expect(publications == 0)
        #expect(coordinator.publication(for: key) == nil)
        #expect(cache.isNegative(.svg(key)) == false)
    }

    @Test func staleCompletionCannotWriteCacheOrPublish() async {
        let gate = ResourceRenderGate()
        let configuration = SVGRendererConfiguration(renderer: ResourceSVGProducer(gate: gate))
        let cache = RenderedResourceCache()
        let coordinator = SVGBlockLoadCoordinator(cache: cache)
        coordinator.configure(configuration)
        let key = resourceSVGKey(configuration: configuration)
        let current = Mutex(true)
        var publications = 0
        let task = coordinator.load(key, isCurrent: { current.withLock { $0 } }, completed: { publications += 1 })
        await gate.waitForArrivals(1)
        current.withLock { $0 = false }
        await gate.open()
        await task?.value
        #expect(coordinator.publication(for: key) == nil)
        #expect(publications == 0)
    }

    @Test func cancellationAndTransientFailureRemainRetryable() async {
        for outcome in [SVGBlockOutcome.cancelled, .transientFailure] {
            let producer = ResourceSVGProducer(outcome: outcome)
            let configuration = SVGRendererConfiguration(renderer: producer)
            let cache = RenderedResourceCache()
            let coordinator = SVGBlockLoadCoordinator(cache: cache)
            coordinator.configure(configuration)
            let key = resourceSVGKey(configuration: configuration)
            await coordinator.load(key, isCurrent: { true }, completed: {})?.value
            await coordinator.load(key, isCurrent: { true }, completed: {})?.value
            #expect(await producer.calls == 2)
            #expect(cache.isNegative(.svg(key)) == false)
        }
    }

    @Test func negativeCacheIsBoundedLRUAndExpiresAtSixtySeconds() async {
        let clock = ManualRenderClock()
        let cache = RenderedResourceCache(clock: clock)
        let producer = ResourceSVGProducer(outcome: .failed)
        let configuration = SVGRendererConfiguration(renderer: producer)
        let coordinator = SVGBlockLoadCoordinator(cache: cache)
        coordinator.configure(configuration)
        for index in 0 ..< 128 {
            await coordinator.load(resourceSVGKey("bad\(index)", configuration: configuration), isCurrent: { true }, completed: {})?.value
        }
        let oldest = resourceSVGKey("bad0", configuration: configuration)
        #expect(cache.isNegative(.svg(oldest)))
        await coordinator.load(resourceSVGKey("bad128", configuration: configuration), isCurrent: { true }, completed: {})?.value
        #expect(cache.isNegative(.svg(resourceSVGKey("bad1", configuration: configuration))) == false)
        #expect(cache.isNegative(.svg(oldest)))
        clock.advance(by: .seconds(59))
        #expect(cache.isNegative(.svg(oldest)))
        clock.advance(by: .seconds(1))
        #expect(cache.isNegative(.svg(oldest)) == false)
        await coordinator.load(oldest, isCurrent: { true }, completed: {})?.value
        #expect(await producer.calls == 130)
    }

    @Test func evictionDoesNotReleasePublication() async throws {
        let configuration = SVGRendererConfiguration(renderer: ResourceSVGProducer())
        let coordinator = SVGBlockLoadCoordinator(cache: RenderedResourceCache())
        coordinator.configure(configuration)
        let first = resourceSVGKey("0", configuration: configuration)
        await coordinator.load(first, isCurrent: { true }, completed: {})?.value
        let publication = try #require(coordinator.publication(for: first))
        for index in 1 ... 256 {
            let key = resourceSVGKey("\(index)", configuration: configuration)
            await coordinator.load(key, isCurrent: { true }, completed: {})?.value
            coordinator.publication(for: key)?.release()
        }
        #expect(coordinator.publication(for: first) == nil)
        #expect(publication.record.ownerCount == 1)
        #expect(publication.image.size.width == 8)
        publication.release()
        #expect(publication.record.ownerCount == 0)
    }
}
