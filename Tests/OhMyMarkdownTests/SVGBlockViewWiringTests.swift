import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private final class ImgSVGRenderer: SVGBlockRendering, @unchecked Sendable {
    let imageSize: CGSize
    init(_ size: CGSize = CGSize(width: 50, height: 30)) {
        self.imageSize = size
    }

    func render(svg _: String, availableWidth _: CGFloat, scale _: CGFloat) async -> SVGBlockOutcome {
        #if canImport(UIKit)
        let img = UIGraphicsImageRenderer(size: self.imageSize).image { _ in }
        return .rendered(RenderedSVG(image: encodedTestImage(size: img.size)))
        #elseif canImport(AppKit)
        let img = NSImage(size: self.imageSize)
        img.lockFocus(); img.unlockFocus()
        return .rendered(RenderedSVG(image: encodedTestImage(size: img.size)))
        #else
        return .failed
        #endif
    }
}

@Suite("SVG view wiring", .timeLimit(.minutes(1)))
@MainActor
struct SVGBlockViewWiringTests {
    private let source = "```svg\n<svg viewBox=\"0 0 10 6\"/>\n```\n\ntail"

    private func resolved(_ view: MarkdownLabelView) -> Bool {
        view._renderedSVGBlockStateForTesting().markerCount == 0 && view._firstSVGAttachmentImageSizeForTesting() != nil
    }

    @Test func placeholderThenAttachment() async {
        let gate = ViewSnapshotGate()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 4000))
        view.setMarkdown(self.source)
        await gate.wait(for: view) { view._renderedSVGBlockStateForTesting().markerCount == 1 }
        #expect(view._firstSVGAttachmentImageSizeForTesting() == nil)
        view.svgBlockRenderer = SVGRendererConfiguration(renderer: ImgSVGRenderer())
        await gate.wait(for: view) { self.resolved(view) }
        #expect(view._renderedSVGBlockStateForTesting().attachmentCount == 1)
        view.dismantleRenderSession()
    }

    @Test func subPixelWidthJitterStillResolves() async {
        let gate = ViewSnapshotGate()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 4000))
        view.svgBlockRenderer = SVGRendererConfiguration(renderer: ImgSVGRenderer())
        view.setMarkdown("intro\n\nbody")
        await gate.wait(for: view) { view.currentSnapshot?.displayModel.source == "intro\n\nbody" }
        view.frame.size.width = 320.3
        view.setMarkdown(self.source)
        await gate.wait(for: view) { self.resolved(view) }
        #expect(view._renderedSVGBlockStateForTesting().attachmentCount == 1)
        #expect(view.currentSnapshot?.displayModel.availableWidth == 320)
        view.dismantleRenderSession()
    }

    @Test func nonNilRendererSwapChangesImageSize() async {
        let gate = ViewSnapshotGate()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 4000))
        view.svgBlockRenderer = SVGRendererConfiguration(renderer: ImgSVGRenderer(CGSize(width: 50, height: 30)))
        view.setMarkdown(self.source)
        await gate.wait(for: view) { self.resolved(view) }
        #expect(view._firstSVGAttachmentImageSizeForTesting() == CGSize(width: 50, height: 30))
        view.svgBlockRenderer = SVGRendererConfiguration(renderer: ImgSVGRenderer(CGSize(width: 120, height: 80)))
        await gate.wait(for: view) { view._firstSVGAttachmentImageSizeForTesting() == CGSize(width: 120, height: 80) }
        #expect(view._renderedSVGBlockStateForTesting().markerCount == 0)
        view.dismantleRenderSession()
    }

    @Test func lateRendererInjectionResolvesExistingSource() async {
        let gate = ViewSnapshotGate()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 4000))
        view.setMarkdown(self.source)
        await gate.wait(for: view) { view._renderedSVGBlockStateForTesting().markerCount == 1 }
        view.svgBlockRenderer = SVGRendererConfiguration(renderer: ImgSVGRenderer())
        await gate.wait(for: view) { self.resolved(view) }
        #expect(view.currentSnapshot?.displayModel.source == self.source)
        view.dismantleRenderSession()
    }

    @Test func nilRendererDegradesResolved() async {
        let gate = ViewSnapshotGate()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 4000))
        view.svgBlockRenderer = SVGRendererConfiguration(renderer: ImgSVGRenderer())
        view.setMarkdown(self.source)
        await gate.wait(for: view) { self.resolved(view) }
        view.svgBlockRenderer = nil
        await gate.wait(for: view) { view._renderedSVGBlockStateForTesting().markerCount == 1 }
        #expect(view._firstSVGAttachmentImageSizeForTesting() == nil)
        view.dismantleRenderSession()
    }
}
