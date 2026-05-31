import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing

@Suite("Shared coordinator singletons")
struct SharedCoordinatorTests {
    @Test func svgSharedSingletonReturnsSameInstance() async {
        let a = SVGBlockLoadCoordinator.shared
        let b = SVGBlockLoadCoordinator.shared
        #expect(a === b)
    }

    @Test func mathSharedSingletonReturnsSameInstance() async {
        let a = MathLoadCoordinator.shared
        let b = MathLoadCoordinator.shared
        #expect(a === b)
    }

    @Test func independentInitInstancesAreNotShared() async {
        let a = SVGBlockLoadCoordinator()
        let b = SVGBlockLoadCoordinator()
        #expect(a !== b)
        #expect(a !== SVGBlockLoadCoordinator.shared)
    }

    @Test func mathIndependentInitInstancesAreNotShared() async {
        let a = MathLoadCoordinator()
        let b = MathLoadCoordinator()
        #expect(a !== b)
        #expect(a !== MathLoadCoordinator.shared)
    }
}
