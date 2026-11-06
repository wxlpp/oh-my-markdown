import Foundation
import MarkdownCore
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
struct RenderReuseTests {
    private func rendered(_ source: String) async -> MarkdownLabelView {
        let view = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        view.setMarkdown(source)
        await view.settled { view.currentSnapshot?.displayModel.availableWidth == 320 }
        return view
    }

    @Test func restoredBodyExistsBeforeAnyAsyncTurnAndContinuesStreaming() async throws {
        let source = "已完成的 **正文**\n\n- 第一项\n- 第二项"
        let cache = MarkdownRenderCache()
        let old = await self.rendered(source)
        let snapshot = try #require(old.currentSnapshot)
        let width = snapshot.displayModel.availableWidth
        let text = snapshot.attributedString.string
        old.preserveRenderedContent(in: cache, source: source)
        old.dismantleRenderSession()
        let fresh = imageTestView(frame: CGRect(x: 0, y: 0, width: width, height: 600))
        fresh.setMarkdown(source)
        fresh.restoreRenderedContent(from: cache, source: source, width: width)
        // 关键验收：这里没有 await，不能靠下一轮actor解析后的终态冒充首帧。
        #expect(fresh.currentSnapshot?.attributedString.string == text)
        #expect(fresh.intrinsicContentSize.height > 1)
        #expect(fresh.currentCommitToken?.sequence == 0)
        fresh.appendMarkdown("\n\n后续输出")
        await fresh.settled { fresh.currentSnapshot?.attributedString.string.contains("后续输出") == true }
        #expect((fresh.currentCommitToken?.sequence ?? 0) > 0)
        #expect(fresh.currentSnapshot?.attributedString.string.hasPrefix(text) == true)
        fresh.dismantleRenderSession()
    }

    @Test func latestUnrenderedSourceCannotCacheAnOlderSnapshot() async throws {
        let cache = MarkdownRenderCache()
        let old = await self.rendered("旧正文")
        let width = try #require(old.currentSnapshot?.displayModel.availableWidth)
        old.setMarkdown("新正文")
        old.preserveRenderedContent(in: cache, source: "新正文")
        old.dismantleRenderSession()
        let fresh = imageTestView(frame: CGRect(x: 0, y: 0, width: width, height: 600))
        fresh.setMarkdown("新正文")
        fresh.restoreRenderedContent(from: cache, source: "新正文", width: width)
        #expect(fresh.currentSnapshot == nil)
        fresh.dismantleRenderSession()
    }

    @Test(arguments: ["source", "width", "options", "color", "typeSize"])
    func incompatiblePresentationDoesNotReuse(_ change: String) async throws {
        let cache = MarkdownRenderCache()
        let old = await self.rendered("文字 **内容**")
        let width = try #require(old.currentSnapshot?.displayModel.availableWidth)
        old.preserveRenderedContent(in: cache, source: "文字 **内容**")
        old.dismantleRenderSession()
        let source = change == "source" ? "另一篇文字" : "文字 **内容**"
        let fresh = imageTestView(frame: CGRect(x: 0, y: 0, width: width, height: 600))
        if change == "options" { fresh.parseOptions = .cjkFriendlyEmphasis }
        if change == "color" { fresh.renderStyle.textColor = .red }
        if change == "typeSize" { fresh.contentSizeCategory = .extraExtraExtraLarge }
        fresh.setMarkdown(source)
        fresh.restoreRenderedContent(from: cache, source: source, width: change == "width" ? width + 20 : width)
        #expect(fresh.currentSnapshot == nil)
        fresh.dismantleRenderSession()
    }

    @Test func resourceModelsAreNotRetained() async throws {
        let source = "正文 ![图片](https://example.com/a.png)"
        let cache = MarkdownRenderCache()
        let old = await self.rendered(source)
        let width = try #require(old.currentSnapshot?.displayModel.availableWidth)
        old.preserveRenderedContent(in: cache, source: source)
        old.dismantleRenderSession()
        let fresh = imageTestView(frame: CGRect(x: 0, y: 0, width: width, height: 600))
        fresh.setMarkdown(source)
        fresh.restoreRenderedContent(from: cache, source: source, width: width)
        #expect(fresh.currentSnapshot == nil)
        fresh.dismantleRenderSession()
    }

    @Test func cacheLimitsAndClearReleaseEntries() async {
        let cache = MarkdownRenderCache(maximumEntryCount: 1, maximumSourceBytes: 64)
        for text in ["第一篇", "第二篇", String(repeating: "超长", count: 100)] {
            let view = await self.rendered(text)
            view.preserveRenderedContent(in: cache, source: text)
            view.dismantleRenderSession()
        }
        for (text, expected) in [("第一篇", false), ("第二篇", true)] {
            let fresh = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
            fresh.setMarkdown(text)
            fresh.restoreRenderedContent(from: cache, source: text, width: 320)
            #expect((fresh.currentSnapshot != nil) == expected)
            fresh.dismantleRenderSession()
        }
        cache.removeAll()
        let fresh = imageTestView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        fresh.setMarkdown("第二篇")
        fresh.restoreRenderedContent(from: cache, source: "第二篇", width: 320)
        #expect(fresh.currentSnapshot == nil)
        fresh.dismantleRenderSession()
    }

    @Test func zeroFrameProposalsHandOffToAsyncTableRendering() async {
        let source = "| Name | Detail |\n|---|---|\n| One | A long detail with wrapping words |"
        let cache = MarkdownRenderCache()
        let old = await self.rendered(source)
        old.preserveRenderedContent(in: cache, source: source)
        old.dismantleRenderSession()
        let fresh = imageTestView(frame: .zero)
        fresh.setMarkdown(source)
        fresh.restoreRenderedContent(from: cache, source: source, width: 320)
        #expect(fresh.currentSnapshot?.displayModel.availableWidth == 320)
        #expect(fresh.intrinsicContentSize.height > 1)
        fresh.restoreRenderedContent(from: cache, source: source, width: 240)
        #expect(fresh.currentSnapshot == nil)
        await fresh.settled { fresh.currentSnapshot?.displayModel.availableWidth == 240 }
        #expect(fresh.currentSnapshot?.displayModel.availableWidth == 240)
        fresh.frame = CGRect(x: 0, y: 0, width: 280, height: 600)
        #if canImport(UIKit)
        fresh.setNeedsLayout()
        fresh.layoutIfNeeded()
        #else
        fresh.needsLayout = true
        fresh.layoutSubtreeIfNeeded()
        #endif
        await fresh.settled { fresh.currentSnapshot?.displayModel.availableWidth == 280 }
        #expect(fresh.currentSnapshot?.displayModel.availableWidth == 280)
        fresh.dismantleRenderSession()
    }

    @Test func cachedModelsDetachOldWorkAccounting() throws {
        let recorder = ParseWorkRecorder()
        var buffer = IncrementalSourceBuffer(recorder: recorder)
        var metrics = ParseWorkMetrics()
        let source = "# Heading\n\nBody"
        try buffer.append(source, metrics: &metrics)
        let document = try buffer.parse(previous: nil).document
        let config = MarkdownRenderConfiguration.default.snapshot(generation: 0)
        let model = try RenderPreparer(configuration: config).prepare(RenderInput(
            document: document, source: nil, availableWidth: 320,
            configuration: config, placeholderMode: .streaming,
            previousModel: nil, sourceBuffer: buffer
        ))
        let cache = MarkdownRenderCache()
        cache.store(model, source: source, options: [], configuration: config)
        let copy = try #require(cache.model(source: source, options: [], width: 320, configuration: config))
        let before = recorder.snapshot()
        #expect(copy.source == source)
        _ = copy.preparedBlocks
        _ = copy.runs
        #expect(copy.sourceBuffer == nil)
        #expect(copy.preparedDocument?.workRecorder == nil)
        #expect(copy.materializationDelta == nil)
        #expect(copy.identity != model.identity)
        #expect(recorder.snapshot() == before)
    }
}
