import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Synchronization
import Testing

@MainActor
@Suite("MathLoadCoordinator")
struct MathLoadCoordinatorTests {
    @Test func malformedEncodedResultIsDeterministicAndNeverAcquiresResidency() async {
        let image = RenderedImage(encodedData: Data([0]), pointSize: CGSize(width: 2, height: 2))
        let configuration = MathRendererConfiguration(renderer: ResourceMathProducer(outcome: .rendered(RenderedMath(image: image, baselineOffsetEx: 0))))
        let cache = RenderedResourceCache()
        let coordinator = MathLoadCoordinator(cache: cache)
        coordinator.configure(configuration)
        let key = resourceMathKey(configuration: configuration)
        var publications = 0
        await coordinator.load(key, isCurrent: { true }, completed: { publications += 1 })?.value
        #expect(cache.isNegative(.math(key)))
        #expect(cache.publication(for: .math(key)) == nil)
        #expect(publications == 0)
    }

    @Test func nilRendererNoDispatch() {
        let configuration = MathRendererConfiguration(renderer: ResourceMathProducer())
        #expect(MathLoadCoordinator(cache: RenderedResourceCache()).load(resourceMathKey(configuration: configuration), isCurrent: { true }, completed: {}) == nil)
    }

    @Test func renderedCachedOnce() async {
        let producer = ResourceMathProducer()
        let configuration = MathRendererConfiguration(renderer: producer)
        let cache = RenderedResourceCache()
        let coordinator = MathLoadCoordinator(cache: cache)
        coordinator.configure(configuration)
        let key = resourceMathKey(configuration: configuration)
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
        let producer = ResourceMathProducer(gate: gate)
        let configuration = MathRendererConfiguration(renderer: producer)
        let cache = RenderedResourceCache()
        let coordinator = MathLoadCoordinator(cache: cache)
        coordinator.configure(configuration)
        let key = resourceMathKey(configuration: configuration)
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
        #expect(cache.isNegative(.math(key)) == false)
    }

    @Test func staleCompletionCannotWriteCacheOrPublish() async {
        let gate = ResourceRenderGate()
        let configuration = MathRendererConfiguration(renderer: ResourceMathProducer(gate: gate))
        let cache = RenderedResourceCache()
        let coordinator = MathLoadCoordinator(cache: cache)
        coordinator.configure(configuration)
        let key = resourceMathKey(configuration: configuration)
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
        for outcome in [MathRenderOutcome.cancelled, .transientFailure] {
            let producer = ResourceMathProducer(outcome: outcome)
            let configuration = MathRendererConfiguration(renderer: producer)
            let cache = RenderedResourceCache()
            let coordinator = MathLoadCoordinator(cache: cache)
            coordinator.configure(configuration)
            let key = resourceMathKey(configuration: configuration)
            await coordinator.load(key, isCurrent: { true }, completed: {})?.value
            await coordinator.load(key, isCurrent: { true }, completed: {})?.value
            #expect(await producer.calls == 2)
            #expect(cache.isNegative(.math(key)) == false)
        }
    }

    @Test func negativeCacheIsBoundedLRUAndExpiresAtSixtySeconds() async {
        let clock = ManualRenderClock()
        let cache = RenderedResourceCache(clock: clock)
        let producer = ResourceMathProducer(outcome: .failed)
        let configuration = MathRendererConfiguration(renderer: producer)
        let coordinator = MathLoadCoordinator(cache: cache)
        coordinator.configure(configuration)
        for index in 0 ..< 128 {
            await coordinator.load(resourceMathKey("bad\(index)", configuration: configuration), isCurrent: { true }, completed: {})?.value
        }
        let oldest = resourceMathKey("bad0", configuration: configuration)
        #expect(cache.isNegative(.math(oldest)))
        await coordinator.load(resourceMathKey("bad128", configuration: configuration), isCurrent: { true }, completed: {})?.value
        #expect(cache.isNegative(.math(resourceMathKey("bad1", configuration: configuration))) == false)
        #expect(cache.isNegative(.math(oldest)))
        clock.advance(by: .seconds(59))
        #expect(cache.isNegative(.math(oldest)))
        clock.advance(by: .seconds(1))
        #expect(cache.isNegative(.math(oldest)) == false)
        await coordinator.load(oldest, isCurrent: { true }, completed: {})?.value
        #expect(await producer.calls == 130)
    }

    @Test func evictionDoesNotReleasePublication() async throws {
        let configuration = MathRendererConfiguration(renderer: ResourceMathProducer())
        let coordinator = MathLoadCoordinator(cache: RenderedResourceCache())
        coordinator.configure(configuration)
        let first = resourceMathKey("0", configuration: configuration)
        await coordinator.load(first, isCurrent: { true }, completed: {})?.value
        let publication = try #require(coordinator.publication(for: first))
        for index in 1 ... 256 {
            let key = resourceMathKey("\(index)", configuration: configuration)
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
