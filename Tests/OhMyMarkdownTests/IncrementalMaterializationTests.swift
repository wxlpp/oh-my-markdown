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
struct IncrementalMaterializationTests {
    private let configuration = RenderStyle.default.snapshot(generation: 0)

    private func model(_ blocks: [BlockNode], previous: RenderDisplayModel? = nil, range: Range<Int>? = nil) throws -> RenderDisplayModel {
        let document = MarkdownDocument(parsedBlocks: blocks.map { ParsedBlockNode(block: $0) })
        let input = RenderInput(document: document, source: nil, availableWidth: 320, configuration: self.configuration, placeholderMode: .streaming, previousModel: previous)
        let preparer = RenderPreparer(configuration: self.configuration)
        if let previous, let range {
            var metrics = ParseWorkMetrics()
            return try preparer.prepareDelta(input, replacing: range, with: range, metrics: &metrics).applying(to: previous)
        }
        return try preparer.prepare(input)
    }

    @Test func middleBlockReplacementReusesPrefixAndSuffixWithExactAttributes() throws {
        let initial: [BlockNode] = [.codeBlock(language: "swift", body: "let x = 1"), .paragraph([.text("中文😀")]), .blockquote([.paragraph([.text("后缀")])])]
        var edited = initial
        edited[1] = .paragraph([.strong([.text("改写😀")])])
        let oldModel = try self.model(initial)
        let materializer = RenderMaterializer(configuration: self.configuration)
        let old = materializer.materialize(oldModel, resources: .init(values: [:]))
        let next = try materializer.materialize(self.model(edited, previous: oldModel, range: 1 ..< 2), resources: .init(values: [:]), previous: old)
        let full = try materializer.materialize(self.model(edited), resources: .init(values: [:]))
        #expect(next.attributedString.isEqual(to: full.attributedString))
        #expect(next.blockStarts == full.blockStarts)
        #expect(next.materializationWork.materializedBlocks <= 2)
        #expect(next.materializationWork.reusedBlocks >= 1)
        #expect(next.edit?.baselineSnapshotID == old.id)
        #expect(next.chunks.first === old.chunks.first)
    }

    @Test(arguments: [BlockNode.codeBlock(language: "swift", body: "let value = 12"), BlockNode.blockquote([.paragraph([.text("引用修改😀")])])])
    func decoratedMiddleReplacementKeepsTheRestEquivalent(changed: BlockNode) throws {
        let initial: [BlockNode] = [.paragraph([.text("prefix")]), .paragraph([.text("old")]), .paragraph([.text("next")]), .paragraph([.text("suffix")])]
        var edited = initial
        edited[1] = changed
        let oldModel = try self.model(initial)
        let materializer = RenderMaterializer(configuration: self.configuration)
        let old = materializer.materialize(oldModel, resources: .init(values: [:]))
        let next = try materializer.materialize(self.model(edited, previous: oldModel, range: 1 ..< 2), resources: .init(values: [:]), previous: old)
        let full = try materializer.materialize(self.model(edited), resources: .init(values: [:]))
        #expect(next.attributedString.isEqual(to: full.attributedString))
        #expect(next.chunks.first === old.chunks.first)
        #expect(next.chunks.last === old.chunks.last)
        #expect(next.materializationWork.materializedBlocks == 2)
    }

    @Test func staleBaselineAndConfigurationFallBack() throws {
        let blocks: [BlockNode] = [.paragraph([.text("first")]), .paragraph([.text("tail")])]
        let oldModel = try self.model(blocks)
        let materializer = RenderMaterializer(configuration: self.configuration)
        let wrong = try materializer.materialize(self.model(blocks), resources: .init(values: [:]))
        let nextModel = try self.model(blocks, previous: oldModel, range: 1 ..< 2)
        let next = materializer.materialize(nextModel, resources: .init(values: [:]), previous: wrong)
        #expect(next.edit == nil)
        #expect(next.materializationWork.fallbackReason == .baselineMismatch)
        let old = materializer.materialize(oldModel, resources: .init(values: [:]))
        var style = RenderStyle.default
        style.paragraphSpacing += 1
        let changedConfiguration = RenderMaterializer(configuration: style.snapshot(generation: 0))
        let changed = changedConfiguration.materialize(nextModel, resources: .init(values: [:]), previous: old)
        #expect(changed.edit == nil)
        #expect(changed.materializationWork.fallbackReason == .configurationChanged)
    }

    @Test func streamingAppendEditsStorageAndKeepsUnchangedPrefix() async throws {
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        view.appendMarkdown((0 ..< 60).map { "段落 \($0)" }.joined(separator: "\n\n") + "\n\n尾巴")
        await view.settled { view.currentSnapshot != nil }
        let previous = try #require(view.currentSnapshot)
        let storage = try #require(view.contentStorage.textStorage)
        let edits = StorageEditObserver()
        storage.delegate = edits
        let start = view.contentStorage.documentRange.location
        let upper = try #require(view.contentStorage.location(start, offsetBy: 4))
        let selection = try #require(NSTextRange(location: start, end: upper))
        view.layoutManager.textSelections = [NSTextSelection(range: selection, affinity: .downstream, granularity: .character)]
        view.appendMarkdown("继续")
        await view.settled { view.currentSnapshot?.id != previous.id }
        let next = try #require(view.currentSnapshot)
        #expect(next.edit != nil)
        #expect(view.contentStorage.textStorage === storage)
        #expect(!edits.characterRanges.isEmpty)
        #expect(edits.characterRanges.allSatisfy { $0.location > 100 })
        #expect(next.fullStringAssemblyCount == 0)
        #expect(view.currentRenderedSelectionRange() == NSRange(location: 0, length: 4))
        #expect(next.materializationWork.materializedBlocks < 5)
        #expect(next.materializationWork.reusedBlocks > 50)
        #expect(view.lastStorageEditRange?.location ?? 0 > 100)
        let full = try RenderMaterializer(configuration: #require(next.configuration)).materialize(next.displayModel, resources: .init(values: [:]))
        let fresh = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        try fresh.replaceSnapshot(full, token: #require(view.currentCommitToken))
        // NSTextStorage normalizes paragraph attributes on separator characters.
        // Compare the actual incremental TextKit stack with a fresh full install.
        let equal = try view.renderedAttributedStringForCopy?.isEqual(to: #require(fresh.renderedAttributedStringForCopy)) == true
        #expect(equal)
        #expect(next.attributedString.isEqual(to: full.attributedString))
        fresh.dismantleRenderSession()
        view.dismantleRenderSession()
    }
}

@MainActor
private final class StorageEditObserver: NSObject, @MainActor NSTextStorageDelegate {
    var characterRanges: [NSRange] = []
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: PlatformStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) { self.characterRanges.append(editedRange) }
    }
}

#if canImport(UIKit)
private typealias PlatformStorageEditActions = NSTextStorage.EditActions
#else
private typealias PlatformStorageEditActions = NSTextStorageEditActions
#endif
