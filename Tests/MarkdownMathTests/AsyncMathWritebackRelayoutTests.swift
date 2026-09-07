import Foundation
import MarkdownCore
@testable import MarkdownMath
@testable import MarkdownPlatformView
import MarkdownRenderKit
import Testing
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

private actor PausedMathProducer: MathRendering {
    private let renderer = MathJaxRenderer()
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func open() {
        self.opened = true
        let waiting = self.pending
        self.pending.removeAll()
        waiting.forEach { $0.resume() }
    }

    func render(latex: String, display: Bool, pointSize: CGFloat, scale: CGFloat, colorHex: String) async -> MathRenderOutcome {
        if !self.opened { await withCheckedContinuation { self.pending.append($0) } }
        return await self.renderer.render(latex: latex, display: display, pointSize: pointSize, scale: scale, colorHex: colorHex)
    }
}

@MainActor
@Suite("Async math write-back relayout", .timeLimit(.minutes(1)))
struct AsyncMathWritebackRelayoutTests {
    @Test func asyncMathWritebackDrivesRealLayoutInvalidationPrimitives() async {
        let spans = (0 ..< 8).map { "$x_{\($0)}$" }.joined(separator: " 填充文字 ")
        let markdown = "前置一段普通文字。\n\n\(spans)\n\n后置一段普通文字。"
        let gate = ViewSnapshotGate()
        let producer = PausedMathProducer()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 10000))
        view.mathRenderer = MathRendererConfiguration(renderer: producer)
        view.setMarkdown(markdown)
        await gate.wait(for: view) { view.currentSnapshot?.displayModel.source == markdown }
        #expect(view._renderedMathStateForTesting().mathSourceCount == 8)
        let placeholderHeight = view.intrinsicContentSize.height
        let scheduleCount = view._deferredHeightScheduleCount
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #else
        view.layoutSubtreeIfNeeded()
        #endif
        await producer.open()
        await gate.wait(for: view) {
            let state = view._renderedMathStateForTesting()
            return state.mathSourceCount == 0 && state.attachmentCount == 8
        }
        #expect(view.intrinsicContentSize.height < placeholderHeight)
        #expect(view.blocks.count == 3)
        #expect(view._deferredHeightScheduleCount > scheduleCount)
        #if canImport(AppKit)
        #expect(view.needsLayout)
        #endif
        view.dismantleRenderSession()
    }
}
