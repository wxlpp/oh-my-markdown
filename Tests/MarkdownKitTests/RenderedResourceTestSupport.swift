import CoreGraphics
import Foundation
import MarkdownCore
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing

func resourceTestImage(width: Int = 8, height: Int = 4) -> RenderedImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return try! RenderedImage(cgImage: context.makeImage()!, pointSize: CGSize(width: width, height: height))
}

actor ResourceRenderGate {
    private var arrivals = 0
    private var expectedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releases: [CheckedContinuation<Void, Never>] = []
    private(set) var cancellations = 0
    func enter() async {
        self.arrivals += 1
        let ready = self.expectedWaiters.filter { $0.0 <= self.arrivals }
        self.expectedWaiters.removeAll { $0.0 <= self.arrivals }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { self.releases.append($0) }
        if Task.isCancelled { self.cancellations += 1 }
    }

    func waitForArrivals(_ count: Int) async {
        if self.arrivals < count { await withCheckedContinuation { self.expectedWaiters.append((count, $0)) } }
    }

    func open() {
        let pending = self.releases
        self.releases.removeAll()
        pending.forEach { $0.resume() }
    }
}

actor ResourceMathProducer: MathRendering {
    let outcome: MathRenderOutcome
    let gate: ResourceRenderGate?
    private(set) var calls = 0
    init(outcome: MathRenderOutcome = .rendered(try! RenderedMath(image: resourceTestImage(), baselineOffsetEx: -0.25)), gate: ResourceRenderGate? = nil) {
        self.outcome = outcome
        self.gate = gate
    }

    func render(latex: String, display: Bool, pointSize: CGFloat, scale: CGFloat, colorHex: String) async -> MathRenderOutcome {
        self.calls += 1
        await self.gate?.enter()
        return self.outcome
    }
}

actor ResourceSVGProducer: SVGBlockRendering {
    let outcome: SVGBlockOutcome
    let gate: ResourceRenderGate?
    private(set) var calls = 0
    init(outcome: SVGBlockOutcome = .rendered(RenderedSVG(image: resourceTestImage())), gate: ResourceRenderGate? = nil) {
        self.outcome = outcome
        self.gate = gate
    }

    func render(svg: String, availableWidth: CGFloat, scale: CGFloat) async -> SVGBlockOutcome {
        self.calls += 1
        await self.gate?.enter()
        return self.outcome
    }
}

actor BaselineValidationProducer: MathRendering {
    let baseline: CGFloat
    init(baseline: CGFloat) {
        self.baseline = baseline
    }

    func render(latex: String, display: Bool, pointSize: CGFloat, scale: CGFloat, colorHex: String) async -> MathRenderOutcome {
        do {
            return try .rendered(RenderedMath(image: resourceTestImage(), baselineOffsetEx: self.baseline))
        } catch {
            return .failed
        }
    }
}

@MainActor
func resourceMathKey(_ source: String = "x", configuration: MathRendererConfiguration) -> MathCacheKey {
    MathCacheKey(latex: source, display: false, pointSize: 16, colorHex: "#000000", rasterScale: 2, configurationID: configuration.configurationID)
}

@MainActor
func resourceSVGKey(_ source: String = "<svg/>", configuration: SVGRendererConfiguration) -> SVGBlockCacheKey {
    SVGBlockCacheKey(svg: source, availableWidth: 100, rasterScale: 2, configurationID: configuration.configurationID)
}
