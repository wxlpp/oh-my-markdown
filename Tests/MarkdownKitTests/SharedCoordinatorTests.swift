import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing

@MainActor
@Suite("Completed resource sharing")
struct SharedCoordinatorTests {
    @Test func explicitSemanticIdentitySharesCompletedButDefaultWrappersIsolate() async {
        let cache = RenderedResourceCache()
        let identity = MarkdownConfigurationID.semantic(namespace: "test.producer", version: 1)
        let firstProducer = ResourceSVGProducer()
        let firstConfiguration = SVGRendererConfiguration(renderer: firstProducer, configurationID: identity)
        let first = SVGBlockLoadCoordinator(cache: cache)
        first.configure(firstConfiguration)
        let key = resourceSVGKey(configuration: firstConfiguration)
        await first.load(key, isCurrent: { true }, completed: {})?.value
        let publication = first.publication(for: key)
        let secondProducer = ResourceSVGProducer()
        let secondConfiguration = SVGRendererConfiguration(renderer: secondProducer, configurationID: identity)
        let second = SVGBlockLoadCoordinator(cache: cache)
        second.configure(secondConfiguration)
        #expect(second.load(resourceSVGKey(configuration: secondConfiguration), isCurrent: { true }, completed: {}) == nil)
        let shared = second.publication(for: key)
        #expect(shared?.record === publication?.record)
        #expect(await secondProducer.calls == 0)

        for configuration in [
            SVGRendererConfiguration(renderer: secondProducer),
            SVGRendererConfiguration(renderer: secondProducer),
            SVGRendererConfiguration(renderer: secondProducer, configurationID: .semantic(namespace: "test.producer", version: 2)),
        ] {
            second.configure(configuration)
            let isolatedKey = resourceSVGKey(configuration: configuration)
            await second.load(isolatedKey, isCurrent: { true }, completed: {})?.value
            #expect(second.publication(for: isolatedKey)?.record !== publication?.record)
        }
        #expect(await secondProducer.calls == 3)
    }

    @Test func twoSessionsNeverShareInFlightEvenForEqualSemanticIdentity() async {
        let gate = ResourceRenderGate()
        let producer = ResourceMathProducer(gate: gate)
        let configuration = MathRendererConfiguration(renderer: producer, configurationID: .semantic(namespace: "same.math", version: 1))
        let cache = RenderedResourceCache()
        let first = MathLoadCoordinator(cache: cache)
        let second = MathLoadCoordinator(cache: cache)
        first.configure(configuration)
        second.configure(configuration)
        let key = resourceMathKey(configuration: configuration)
        let one = first.load(key, isCurrent: { true }, completed: {})
        let two = second.load(key, isCurrent: { true }, completed: {})
        await gate.waitForArrivals(2)
        first.cancelAll()
        await gate.open()
        await one?.value
        await two?.value
        #expect(await gate.cancellations == 1)
        #expect(await producer.calls == 2)
        #expect(second.publication(for: key) != nil)
    }
}
