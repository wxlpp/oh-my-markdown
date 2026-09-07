import CoreGraphics
import Foundation
import ImageIO
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

/// Test-only owner for materialization fixtures that never enter the residency ledger.
@MainActor final class TestResourceOwner: ResourceResidencyOwner {
    let retainedObject: AnyObject
    private(set) var releaseCount = 0
    init(retaining object: AnyObject) {
        self.retainedObject = object
    }

    func release() {
        self.releaseCount += 1
    }
}

func encodedPNG(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@MainActor
func decodedTestBacking(width: Int = 4, height: Int = 4) throws -> DecodedImage {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    return try DecodedImage(backing: ImmutableCGImageBacking(frames: [#require(context.makeImage())]), decodedPixelSize: 4096)
}

/// Promotes one real backing through the ledger so tests own a genuine lease.
@MainActor
func ownedTestImage(_ ledger: ImageResidencyLedger, width: Int = 4, height: Int = 4) throws -> OwnedImage {
    let decoded = try decodedTestBacking(width: width, height: height)
    let reservation = try #require(ledger.reserveDecodedPixelBytes(decoded.backing.accountedPixelBytes))
    return try #require(reservation.promote(decoded))
}

/// Private residency instances. Suites run in parallel, so sharing the process
/// budgets would let one suite's held transfers starve another's.
@MainActor
func isolatedImageResidency(
    hardLimit: Int = 192 << 20, cacheLimit: Int = 128 << 20,
    maxPixelSize: Int = ImageDecoder.maxOutputSide,
    clock: any RenderSessionClock = ContinuousRenderSessionClock()
) -> ImageResidencyConfiguration {
    ImageResidencyConfiguration(
        ledger: ImageResidencyLedger(hardLimit: hardLimit, cacheLimit: cacheLimit, clock: clock),
        permits: ImageResourceCoordinator(), maxPixelSize: maxPixelSize
    )
}

@MainActor
func imageTestView(
    frame: CGRect, residency: ImageResidencyConfiguration = isolatedImageResidency(),
    clock: (any RenderSessionClock)? = nil, executor: ParseExecutor? = nil
) -> MarkdownLabelView {
    let view = MarkdownLabelView(frame: frame)
    view.sessionOverrides = RenderSessionOverrides(
        executor: executor ?? .shared, clock: clock ?? ContinuousRenderSessionClock(), residency: residency
    )
    return view
}

/// Drives the session's coalescing debounce forward deterministically and lets the
/// resulting MainActor work run, instead of waiting on a real 33 ms sleep.
@MainActor
func flushCoalescedResources(_ clock: ManualRenderClock, rounds: Int = 6) async {
    for _ in 0 ..< rounds {
        clock.advance(by: .milliseconds(40))
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }
}

/// A real PNG padded with trailing bytes to an exact encoded size. ImageIO reports
/// `statusComplete` for it, so it survives Task 6 validation and can drive genuine
/// multi-megabyte encoded bodies without fabricating pixels.
func paddedEncodedPNG(byteCount: Int) throws -> Data {
    var data = try encodedPNG(width: 8, height: 8)
    #expect(data.count < byteCount)
    data.append(Data(repeating: 0, count: byteCount - data.count))
    return data
}

/// Waits on an injected session clock instead of the wall clock: each round drives
/// the 33 ms coalescing debounce forward and lets the resulting MainActor work run.
/// Bounded by rounds rather than by a wall clock, so it stays deterministic; the
/// budget has to cover a real image resolution on a loaded machine, which 40
/// rounds intermittently did not.
func settle(
    _ clock: ManualRenderClock, rounds: Int = 400,
    isolation: isolated (any Actor)? = #isolation,
    until predicate: () async -> Bool
) async -> Bool {
    for _ in 0 ..< rounds {
        if await predicate() { return true }
        clock.advance(by: .milliseconds(40))
        for _ in 0 ..< 10 {
            await Task.yield()
        }
    }
    return await predicate()
}

/// Yields without advancing the injected clock, so pending work settles while the
/// coalescing debounce stays closed. Callers flush it once afterwards instead of
/// paying for one full re-materialization per intermediate batch.
func quiesce(
    rounds: Int = 400, isolation: isolated (any Actor)? = #isolation,
    until predicate: () async -> Bool
) async -> Bool {
    for _ in 0 ..< rounds {
        if await predicate() { return true }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
    }
    return await predicate()
}
