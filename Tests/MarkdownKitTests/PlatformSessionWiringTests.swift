import Foundation
import ImageIO
import MarkdownCore
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor private final class RecordingSessionDriver: RenderSessionDriving {
    let resourceTaskOwner = RenderSessionResourceTaskOwner()
    var events: [String] = []
    func send(_ mutation: RenderSessionMutation) {
        switch mutation {
        case .setSource(let source, _): self.events.append("set:\(source)")
        case .append(let source): self.events.append("append:\(source)")
        case .replaceConfiguration: self.events.append("configuration")
        case .replaceWidth(let width): self.events.append("width:\(Int(width))")
        case .setDocument: self.events.append("document")
        case .dismantle: self.events.append("dismantle")
        }
    }
}

@MainActor
struct PlatformSessionWiringTests {
    private actor PausedImageLoader {
        enum Failure: Error { case failed }
        private var continuations: [Int: CheckedContinuation<Data, any Error>] = [:]
        private(set) var sources: [URL] = []
        private(set) var completed = 0
        private(set) var cancelledCompletions = 0
        func load(_ url: URL) async throws -> Data {
            let index = self.sources.count
            self.sources.append(url)
            defer {
                self.completed += 1
                if Task.isCancelled { self.cancelledCompletions += 1 }
            }
            return try await withCheckedThrowingContinuation { self.continuations[index] = $0 }
        }

        func finish(_ index: Int, result: Result<Data, any Error>) {
            self.continuations.removeValue(forKey: index)?.resume(with: result)
        }
    }

    private func imageData(width: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: 10, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test(arguments: ["success", "failure", "cancellation"])
    func currentTokenCanLoadSameImageWhileOldTokenIsPending(oldOutcome: String) async throws {
        let loader = PausedImageLoader()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 120, height: 400))
        view.imageLoader = { try await loader.load($0) }
        view.setMarkdown("A ![alt](https://example.com/image.png)")
        #expect(await eventually { await loader.sources.count == 1 })
        let oldToken = try #require(view.currentCommitToken)
        view.setMarkdown("B ![alt](https://example.com/image.png)")
        #expect(await eventually { await loader.sources.count == 2 })
        let current = try #require(view.currentCommitToken)
        let owner = try #require(view.sessionDriver?.resourceTaskOwner)
        #expect(current != oldToken)
        #expect(view.imageRequests.count == 1)
        #expect(view.imageRequests.keys.first?.token == current)
        let oldResult: Result<Data, any Error> = switch oldOutcome {
        case "success": try .success(self.imageData(width: 10))
        case "failure": .failure(PausedImageLoader.Failure.failed)
        default: .failure(CancellationError())
        }
        await loader.finish(0, result: oldResult)
        #expect(await eventually { await loader.completed == 1 })
        #expect(await eventually { owner.count == 1 })
        #expect(view.currentCommitToken == current)
        #expect(view.currentSnapshot?.attributedString.string == "B 🖼 alt")
        #expect(view.imageRequests.count == 1)
        #expect(view.imageRequests[RenderImageRequest(token: current, source: "https://example.com/image.png")] == .loading)
        try await loader.finish(1, result: .success(self.imageData(width: 20)))
        #expect(await eventually { view.currentSnapshot?.attributedString.string == "B \u{FFFC}" })
        let text = try #require(view.currentSnapshot?.attributedString)
        let attachment = try #require(text.attribute(.attachment, at: 2, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.bounds == CGRect(x: 0, y: -4, width: 20, height: 10))
        #expect(view.imageRequests.isEmpty)
        #expect(view.lastRenderError == nil)
        view.dismantleRenderSession()
    }

    @Test(arguments: ["success", "failure", "cancellation"])
    func teardownClearsImageBookkeepingAndLateCompletionCannotMutate(oldOutcome: String) async throws {
        let loader = PausedImageLoader()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 120, height: 400))
        view.imageLoader = { try await loader.load($0) }
        view.setMarkdown("![alt](https://example.com/image.png)")
        #expect(await eventually { await loader.sources.count == 1 })
        #expect(view.imageRequests.count == 1)
        let token = view.currentCommitToken
        let owner = try #require(view.sessionDriver?.resourceTaskOwner)
        view.dismantleRenderSession()
        #expect(view.imageRequests.isEmpty)
        #expect(owner.count == 0)
        let result: Result<Data, any Error> = switch oldOutcome {
        case "success": try .success(self.imageData(width: 10))
        case "failure": .failure(PausedImageLoader.Failure.failed)
        default: .failure(CancellationError())
        }
        await loader.finish(0, result: result)
        #expect(await eventually { await loader.completed == 1 })
        #expect(await loader.cancelledCompletions == 1)
        #expect(view.imageRequests.isEmpty)
        #expect(view.currentSnapshot == nil)
        #expect(view.currentCommitToken == token)
        #expect(view.lastRenderError == nil)
    }

    @Test func overflowPlatformOverlayConsumesCurrentSnapshotAndPreservesScrollView() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 120, height: 400))
        view.setMarkdown("| A | B |\n|---|---|\n| old | value |")
        #expect(await eventually { view._tableOverlays[0] != nil })
        let first = try #require(view._tableOverlays[0])
        let firstData = try #require(view.currentSnapshot?.tableOverlays[0])
        #expect(first.data === firstData)
        #expect(first.content.frame.height == firstData.height)
        #expect(first.content.frame.width == firstData.naturalWidth)
        view.setMarkdown("| A | B |\n|---|---|\n| new | value |")
        #expect(await eventually { view.currentSnapshot?.tableOverlays[0]?.attributedString.string.contains("new") == true })
        let second = try #require(view._tableOverlays[0])
        #expect(first.scroll === second.scroll)
        #expect(second.data === view.currentSnapshot?.tableOverlays[0])
        #expect(second.data.attributedString.string == "\tA\tB\n\tnew\tvalue")
        view.dismantleRenderSession()
        #expect(view._tableOverlays.isEmpty)
    }

    @Test func overflowImageResolutionPublishesOwnedCellAttachment() async throws {
        let loader = PausedImageLoader()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 120, height: 400))
        view.imageLoader = { try await loader.load($0) }
        view.setMarkdown("| Photo | Text |\n|---|---|\n| ![alt](https://example.com/image.png) | value |")
        #expect(await eventually { await loader.sources.count == 1 })
        #expect(view.currentSnapshot?.attributedString.string == "\u{00A0}")
        try await loader.finish(0, result: .success(self.imageData(width: 20)))
        #expect(await eventually { view.currentSnapshot?.tableOverlays[0]?.attributedString.string == "\tPhoto\tText\n\t\u{FFFC}\tvalue" })
        weak var overlay = view.currentSnapshot?.tableOverlays[0]
        #expect(view._tableOverlays[0]?.data === overlay)
        #expect(view._tableOverlays[0]?.content.frame.height == overlay?.height)
        #expect(view.imageRequests.isEmpty)
        view.dismantleRenderSession()
        #expect(overlay == nil)
    }

    @Test func currentImageFailureIsRecordedWithoutPublishingOrRetryLoop() async throws {
        let loader = PausedImageLoader()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 120, height: 400))
        view.imageLoader = { try await loader.load($0) }
        view.setMarkdown("![alt](https://example.com/image.png)")
        #expect(await eventually { await loader.sources.count == 1 })
        let token = try #require(view.currentCommitToken)
        let request = RenderImageRequest(token: token, source: "https://example.com/image.png")
        await loader.finish(0, result: .failure(PausedImageLoader.Failure.failed))
        #expect(await eventually { view.imageRequests[request] == .failed })
        #expect(view.currentCommitToken == token)
        #expect(view.currentSnapshot?.attributedString.string == "🖼 alt")
        #expect(await loader.sources.count == 1)
        view.dismantleRenderSession()
        #expect(view.imageRequests.isEmpty)
    }

    @Test func resourceTaskOwnerCancelsPendingOperationsAtTeardown() async {
        let registry = RenderSessionSinkRegistry()
        let session = MarkdownRenderSession(registry: registry)
        let driver = MarkdownRenderSessionDriver(session: session)
        let owner = driver.resourceTaskOwner
        let clock = ManualRenderClock()
        var observedCancellation = false
        let task = owner.start {
            do { try await clock.sleep(for: .seconds(1)) }
            catch { observedCancellation = true }
        }
        #expect(await eventually { clock.sleepingCount == 1 })
        driver.send(.dismantle)
        #expect(owner.count == 0)
        #expect(task.isCancelled)
        await task.value
        #expect(observedCancellation)
        #expect(clock.sleepingCount == 0)
    }

    private final class MissingMathRenderer: MathRendering {
        let calls = RenderSideEffectProbe()
        func render(latex: String, display: Bool, pointSize: CGFloat, scale: CGFloat, color: PlatformColor) async -> MathRenderOutcome {
            self.calls.record()
            return .failed
        }
    }

    private final class MissingSVGRenderer: SVGBlockRendering {
        let calls = RenderSideEffectProbe()
        func render(svg: String, availableWidth: CGFloat, scale: CGFloat) async -> SVGBlockOutcome {
            self.calls.record()
            return .failed
        }
    }

    private final class PausedSVGRenderer: SVGBlockRendering {
        let clock = ManualRenderClock()
        func render(svg: String, availableWidth: CGFloat, scale: CGFloat) async -> SVGBlockOutcome {
            try? await self.clock.sleep(for: .seconds(1))
            return .failed
        }
    }

    @Test func blockedParseDoesNotRetainPlatformViewOrDriver() async throws {
        let gate = ParseGate()
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 64, parser: gate.parse)
        let registry = RenderSessionSinkRegistry()
        var session: MarkdownRenderSession? = MarkdownRenderSession(executor: executor, registry: registry)
        var driver: MarkdownRenderSessionDriver? = try MarkdownRenderSessionDriver(session: #require(session))
        var view: MarkdownLabelView? = try MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400), driver: #require(driver))
        try registry.register(#require(view), for: #require(session?.id))
        let weakView = WeakLifetime(view)
        let weakDriver = WeakLifetime(driver)
        let weakSession = WeakLifetime(session)
        view?.setMarkdown("blocked")
        #expect(await eventually { gate.entered == ["blocked"] })
        session = nil
        driver = nil
        view = nil
        #expect(await eventually { weakView.value == nil && weakDriver.value == nil && weakSession.value == nil })
        #expect(registry.count == 0)
        gate.release("blocked")
        #expect(await eventually { await executor.diagnostics.activeCount == 0 })
    }

    @Test func pendingLegacyResourceDoesNotRetainViewAcrossTeardown() async {
        let renderer = PausedSVGRenderer()
        var view: MarkdownLabelView? = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let weakView = WeakLifetime(view)
        view?.svgBlockRenderer = renderer
        view?.setMarkdown("```svg\n<svg viewBox=\"0 0 20 10\"/>\n```")
        #expect(await eventually { renderer.clock.sleepingCount == 1 })
        view?.dismantleRenderSession()
        view = nil
        #expect(await eventually { weakView.value == nil })
        renderer.clock.advance(by: .seconds(1))
        #expect(await eventually { renderer.clock.sleepingCount == 0 })
    }

    @Test func rendererChangesEmitExactlyOnceInMutationOrder() {
        let driver = RecordingSessionDriver()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400), driver: driver)
        view.mathRenderer = MissingMathRenderer()
        view.setMarkdown("one")
        view.svgBlockRenderer = MissingSVGRenderer()
        view.appendMarkdown(" two")
        view.mathRenderer = nil
        view.svgBlockRenderer = nil
        view.dismantleRenderSession()
        #expect(driver.events == ["configuration", "set:one", "configuration", "append: two", "configuration", "configuration", "dismantle"])
    }

    @Test func failedLegacyRenderersPreserveStaticPlaceholders() async throws {
        let math = MissingMathRenderer()
        let svg = MissingSVGRenderer()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 120, height: 400))
        var style = view.renderStyle
        style.bodyFont = .systemFont(ofSize: 16)
        view.renderStyle = style
        view.mathRenderer = math
        view.svgBlockRenderer = svg
        view.setMarkdown("![alt](file:///markdownkit-missing-parity-fixture.png) $x$\n\n$$\ny=2\n$$\n\n```svg\n<svg viewBox=\"0 0 200 100\"/>\n```")
        #expect(await eventually { math.calls.count == 2 && svg.calls.count == 1 })
        let snapshot = try #require(view.currentSnapshot)
        #expect(snapshot.attributedString.string == "🖼 alt x\n\u{FFFC}\n\u{FFFC}")
        #expect(view._renderedMathStateForTesting().mathSourceCount == 2)
        #expect(view._renderedSVGBlockStateForTesting().markerCount == 1)
        view.dismantleRenderSession()
    }

    @Test func programmaticDocumentUsesSessionAndSourceAbsentCopyFallback() async {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        view.blocks = [.paragraph([.strong([.text("direct")])]), .paragraph([.text("😀")])]
        #expect(await eventually { view.currentSnapshot?.attributedString.string == "direct\n😀" })
        #expect(view.currentSnapshot?.displayModel.source == nil)
        #expect(view.currentSnapshot?.blockStarts == [0, 7])
        view._selectEntireDocumentForTesting()
        #expect(view._copiedStringForCurrentSelectionForTesting() == "direct\n😀")
        view.dismantleRenderSession()
    }

    @Test func publicMutationsEmitOneOrderedDriverEvent() {
        let driver = RecordingSessionDriver()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400), driver: driver)
        view.setMarkdown("one")
        view.appendMarkdown(" two")
        var style = view.renderStyle
        style.paragraphSpacing += 1
        view.renderStyle = style
        view.rasterScaleDidChange(to: 7)
        view.frame.size.width = 200
        #if canImport(UIKit)
        view.layoutSubviews()
        #else
        view.layout()
        #endif
        view.dismantleRenderSession()
        view.dismantleRenderSession()
        #expect(driver.events == ["set:one", "append: two", "configuration", "configuration", "width:200", "dismantle"])
        #expect(view.currentSnapshot == nil)
    }

    @Test func snapshotReplacementUsesExactRegistryAuthorizationAndAtomicCopyMapping() throws {
        let driver = RecordingSessionDriver()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400), driver: driver)
        let registry = RenderSessionSinkRegistry()
        let id = RenderSessionID(rawValue: UUID())
        registry.register(view, for: id)
        let first = RenderCommitToken(sessionID: id, sequence: 1, sourceRevision: 1, configurationGeneration: 1)
        let second = RenderCommitToken(sessionID: id, sequence: 2, sourceRevision: 2, configurationGeneration: 1)
        func snapshot(_ source: String) throws -> RenderSnapshot {
            let configuration = RenderStyle.default.snapshot(generation: 1)
            let input = RenderInput(document: MarkdownDocument(parsing: source), source: source, availableWidth: 320, configuration: configuration, placeholderMode: .static)
            return try RenderMaterializer(configuration: configuration).materialize(RenderPreparer(configuration: configuration).prepare(input), resources: .init(values: [:]))
        }
        let old = try snapshot("**old**")
        let current = try snapshot("**new**\n\nnext")
        registry.authorize(first)
        #expect(registry.withAuthorizedSink(for: first) { $0.replaceSnapshot(old, token: first) })
        view._selectEntireDocumentForTesting()
        registry.authorize(second)
        #expect(!registry.withAuthorizedSink(for: first) { $0.replaceSnapshot(old, token: first) })
        #expect(!registry.withAuthorizedSink(for: first) { $0.receive(error: .parseBusy) })
        #expect(view.lastRenderError == nil)
        #expect(registry.withAuthorizedSink(for: second) { $0.replaceSnapshot(current, token: second) })
        #expect(view.currentSnapshot === current)
        #expect(view.currentCommitToken == second)
        #expect(view._copiedStringForCurrentSelectionForTesting() == "**new**")
        view._selectEntireDocumentForTesting()
        #expect(view._copiedStringForCurrentSelectionForTesting() == "**new**\n\nnext")
        registry.revokeAndUnregister(id)
        view.dismantleRenderSession()
        #expect(view.currentSnapshot == nil)
    }

    @Test func publishedSnapshotOwnsLegacyResourcesUntilTextKitIsCleared() {
        let driver = RecordingSessionDriver()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400), driver: driver)
        let registry = RenderSessionSinkRegistry()
        let id = RenderSessionID(rawValue: UUID())
        registry.register(view, for: id)
        let token = RenderCommitToken(sessionID: id, sequence: 1, sourceRevision: 1, configurationGeneration: 1)
        weak var observed: LegacyResourceOwner?
        weak var observedSnapshot: RenderSnapshot?
        do {
            let owner = LegacyResourceOwner(retaining: NSObject())
            observed = owner
            let attachment = NSTextAttachment()
            attachment.bounds = CGRect(x: 0, y: -3, width: 30, height: 10)
            let model = RenderDisplayModel(runs: [], blocks: [], resources: [], accessibility: .init(roots: []))
            let snapshot = RenderSnapshot(attributedString: NSAttributedString(attachment: attachment), displayModel: model, resourceOwners: [owner])
            observedSnapshot = snapshot
            registry.authorize(token)
            registry.withAuthorizedSink(for: token) { $0.replaceSnapshot(snapshot, token: token) }
        }
        #expect(observed != nil)
        #expect(observedSnapshot != nil)
        view.dismantleRenderSession()
        #expect(observed == nil)
        #expect(observedSnapshot == nil)
    }

    @Test func realDriverPublishesAppendAndWidthThenTearsDown() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        view.setMarkdown("**one**")
        view.appendMarkdown(" two")
        #expect(await eventually { view.currentSnapshot?.attributedString.string == "one two" })
        let prior = try #require(view.currentCommitToken)
        view.frame.size.width = 180
        #if canImport(UIKit)
        view.layoutSubviews()
        #else
        view.layout()
        #endif
        #expect(await eventually { view.currentSnapshot?.displayModel.availableWidth == 180 })
        #expect(try #require(view.currentCommitToken).sequence > prior.sequence)
        view.dismantleRenderSession()
        #expect(view.currentSnapshot == nil)
    }
}
