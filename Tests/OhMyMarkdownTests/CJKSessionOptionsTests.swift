import MarkdownCore
@testable import MarkdownPlatformView
import MarkdownRenderKit
import Testing

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor @Suite(.timeLimit(.minutes(2)))
struct CJKSessionOptionsTests {
    private let source = "中**“文”**后"

    @Test(arguments: [false, true])
    func activeAndPendingConfigurationCannotPublishOldResults(initialCJK: Bool) async {
        let gate = ParseGate()
        defer { gate.release(self.source) }
        let executor = ParseExecutor(maxActive: 1, maxWaitingTokens: 64, parser: gate.parse)
        let registry = RenderSessionSinkRegistry()
        let sink = RecordingRenderSink()
        let session = MarkdownRenderSession(executor: executor, registry: registry)
        registry.register(sink, for: session.id)
        let driver = MarkdownRenderSessionDriver(session: session)
        driver.send(.replaceParseOptions(initialCJK ? .cjkFriendlyEmphasis : []))
        driver.send(.setSource(self.source, MarkdownRenderConfiguration.default.snapshot(generation: 1)))
        await gate.events.settled { gate.entered.contains(self.source) }
        let finalOptions: MarkdownParseOptions = initialCJK ? [] : .cjkFriendlyEmphasis
        driver.send(.replaceParseOptions(finalOptions))
        driver.send(.replaceParseOptions(initialCJK ? .cjkFriendlyEmphasis : []))
        driver.send(.replaceParseOptions(finalOptions))
        await session.settled { await session.currentToken?.sequence == 5 }
        gate.release(self.source)
        await sink.events.settled { sink.tokens.count == 1 }
        #expect(sink.tokens.first?.sequence == 5)
        #expect(sink.strings == [initialCJK ? self.source : "中“文”后"])
        #expect(gate.jobs.last?.parseOptions == finalOptions)
        driver.send(.dismantle)
    }

    @Test func ruleChangeReplacesBusyRetry() async {
        let gate = ParseGate()
        defer { gate.release("a", "b", self.source) }
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 0, parser: gate.parse)
        let parseSink = RecordingParseSink()
        _ = await executor.enqueue(parseJob("a"), sink: parseSink)
        _ = await executor.enqueue(parseJob("b"), sink: parseSink)
        let clock = ManualRenderClock()
        let registry = RenderSessionSinkRegistry()
        let sink = RecordingRenderSink()
        let session = MarkdownRenderSession(executor: executor, registry: registry, clock: clock)
        registry.register(sink, for: session.id)
        let driver = MarkdownRenderSessionDriver(session: session)
        driver.send(.setSource(self.source, MarkdownRenderConfiguration.default.snapshot(generation: 1)))
        await clock.events.settled { clock.sleepingCount == 1 }
        driver.send(.replaceParseOptions(.cjkFriendlyEmphasis))
        await clock.events.settled { clock.sleepCalls == 2 && clock.sleepingCount == 1 }
        gate.release("a", "b", self.source)
        await executor.settled { await executor.diagnostics.activeCount == 0 }
        clock.advance(by: .milliseconds(250))
        await sink.events.settled { sink.tokens.count == 1 }
        #expect(sink.strings == ["中“文”后"])
        #expect(gate.jobs.last?.parseOptions == .cjkFriendlyEmphasis)
        #expect(clock.sleepingCount == 0)
        driver.send(.dismantle)
    }

    @Test func cancelledSessionCannotOverwriteRestoredRules() async {
        let gate = ParseGate()
        defer { gate.release(self.source) }
        let executor = ParseExecutor(maxActive: 2, maxWaitingTokens: 64, parser: gate.parse)
        let registry = RenderSessionSinkRegistry()
        let oldSink = RecordingRenderSink()
        let old = MarkdownRenderSession(executor: executor, registry: registry)
        registry.register(oldSink, for: old.id)
        let oldDriver = MarkdownRenderSessionDriver(session: old)
        oldDriver.send(.setSource(self.source, MarkdownRenderConfiguration.default.snapshot(generation: 1)))
        await gate.events.settled { gate.entered.contains(self.source) }
        oldDriver.send(.dismantle)
        await old.settled { await old.submission == nil }

        let restoredSink = RecordingRenderSink()
        let restored = MarkdownRenderSession(executor: executor, registry: registry)
        registry.register(restoredSink, for: restored.id)
        let driver = MarkdownRenderSessionDriver(session: restored)
        driver.send(.replaceParseOptions(.cjkFriendlyEmphasis))
        driver.send(.setSource(self.source, MarkdownRenderConfiguration.default.snapshot(generation: 1)))
        gate.release(self.source)
        await restoredSink.events.settled { restoredSink.tokens.count == 1 }
        await executor.settled { await executor.diagnostics.activeCount == 0 }
        #expect(oldSink.tokens.isEmpty)
        #expect(restoredSink.strings == ["中“文”后"])
        driver.send(.dismantle)
    }

    @Test func platformSameSourceAndDocumentAuthority() async {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        defer { view.dismantleRenderSession() }
        view.setMarkdown(self.source)
        await view.settled { view.currentSnapshot?.attributedString.string == self.source }
        view.parseOptions = .cjkFriendlyEmphasis
        await view.settled { view.currentSnapshot?.attributedString.string == "中“文”后" }
        view.parseOptions = []
        await view.settled { view.currentSnapshot?.attributedString.string == self.source }
        view.setDocument(MarkdownDocument(parsing: "文**“档”**原文", options: .cjkFriendlyEmphasis))
        await view.settled { view.currentSnapshot?.attributedString.string == "文“档”原文" }
        #expect(view.parseOptions == .cjkFriendlyEmphasis)
        let token = view.currentCommitToken
        view.parseOptions = []
        await view.settled { view.currentCommitToken != token }
        #expect(view.currentSnapshot?.attributedString.string == "文“档”原文")
        let beforeAppend = view.currentCommitToken
        view.appendMarkdown("不应替换文档")
        await view.settled { view.currentCommitToken != beforeAppend }
        #expect(view.currentSnapshot?.attributedString.string == "文“档”原文")
        view.setMarkdown(self.source)
        await view.settled { view.currentSnapshot?.attributedString.string == self.source }
    }
}
