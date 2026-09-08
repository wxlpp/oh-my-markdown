@testable import MarkdownCore
@testable import MarkdownPlatformView
import MarkdownRenderKit
import Testing

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@Suite("Incremental parsing differential")
struct IncrementalParseDifferentialTests {
    /// `parsedBlocks ==` ignores `sourceAnchor`/`sourceAnchorEnd` by design, so
    /// the other differential tests cannot see a splice that keeps a node whose
    /// origin block's bytes have since moved. Source copy reads those two fields
    /// as boundary proofs, so a stale one silently truncates or overruns.
    @Test("Streamed and full parses agree on every source anchor and end")
    func streamedAnchorsMatchAFullParse() throws {
        let corpus = [
            "text $x$  \n\nnext\n",
            "head $x$\n===\n\nbody $y$",
            "- a $x$\n- b $y$\n\nafter $z$",
            "alpha\n\n$$\n  x  \n$$\n\nomega",
            "para\n\n[ref]: /t\n\n$$\ny\n$$\n",
        ]
        for source in corpus {
            let bytes = Array(source.utf8)
            var buffer = IncrementalSourceBuffer()
            var metrics = ParseWorkMetrics()
            var previous: IncrementalParseResult?
            for index in bytes.indices {
                try buffer.append(bytes: [bytes[index]], metrics: &metrics)
                previous = try buffer.parse(previous: previous)
                let prefix = String(decoding: bytes[...index], as: UTF8.self)
                let streamed = try #require(previous).document.parsedBlocks
                let full = MarkdownDocument(parsing: prefix).parsedBlocks
                #expect(
                    streamed.map(\.sourceAnchor) == full.map(\.sourceAnchor),
                    "anchors diverged after \(index + 1) bytes of \(source.debugDescription)"
                )
                #expect(
                    streamed.map(\.sourceAnchorEnd) == full.map(\.sourceAnchorEnd),
                    "ends diverged after \(index + 1) bytes of \(source.debugDescription)"
                )
            }
        }
    }

    @Test("Public heading levels use renderer-normalized lineage across the entire Int domain", arguments: [
        (-1, 1), (Int.min, 1), (0, 1), (1, 1), (2, 2), (6, 6), (7, 6), (Int.max, 6),
    ])
    @MainActor func publicHeadingLevelLineage(level: Int, normalized: Int) throws {
        let document = MarkdownDocument(parsedBlocks: [ParsedBlockNode(block: .heading(level: level, content: [.text("Heading")]))])
        let expected = MarkdownDocument(parsedBlocks: [ParsedBlockNode(block: .heading(level: normalized, content: [.text("Heading")]))])
        let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 1)
        let preparer = RenderPreparer(configuration: configuration)
        let model = try preparer.prepare(RenderInput(document: document, source: nil, availableWidth: 320, configuration: configuration, placeholderMode: .streaming))
        let expectedModel = try preparer.prepare(RenderInput(document: expected, source: nil, availableWidth: 320, configuration: configuration, placeholderMode: .streaming))
        #expect(model.blocks.map(\.lineage) == expectedModel.blocks.map(\.lineage))
        let materializer = RenderMaterializer(configuration: configuration)
        let snapshot = materializer.materialize(model, resources: .init(values: [:]))
        let expectedSnapshot = materializer.materialize(expectedModel, resources: .init(values: [:]))
        #expect(snapshot.attributedString.string == "Heading")
        #expect(snapshot.attributedString.isEqual(to: expectedSnapshot.attributedString))
        #expect(document.blocks == [.heading(level: level, content: [.text("Heading")])])
    }

    @Test("Public signed source ranges survive lineage and rendering without narrowing traps")
    @MainActor func signedSourceRangeLineage() throws {
        let nodes = [-1, Int.min, 0].map { lower in
            ParsedBlockNode(block: .paragraph([.image(source: "image.png", alt: "image")]), sourceRange: MarkdownSourceRange(lowerBound: lower, upperBound: 0))
        }
        let document = MarkdownDocument(parsedBlocks: nodes)
        #expect(Set(document.blockStorage.map(\.lineage)).count == 3)
        #expect(document.parsedBlocks.map(\.sourceRange) == nodes.map(\.sourceRange))
        let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 1)
        let model = try RenderPreparer(configuration: configuration).prepare(RenderInput(document: document, source: nil, availableWidth: 320, configuration: configuration, placeholderMode: .streaming))
        let snapshot = RenderMaterializer(configuration: configuration).materialize(model, resources: .init(values: [:]))
        #expect(snapshot.attributedString.string == "🖼 image\n🖼 image\n🖼 image")
        #expect(Set(model.runs.compactMap(\.resourceID)).count == 3)
    }

    @Test("Programmatic image paragraphs have distinct document-local lineage through public entry points", arguments: [false, true])
    @MainActor func programmaticImageLineages(_ publicBlocksSetter: Bool) async throws {
        let blocks: [BlockNode] = [
            .paragraph([.image(source: "file:///first-missing.png", alt: "first")]),
            .paragraph([.image(source: "file:///second-missing.png", alt: "second")]),
        ]
        let document = MarkdownDocument(parsedBlocks: blocks.map { ParsedBlockNode(block: $0) })
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        defer { view.dismantleRenderSession() }
        let model: RenderDisplayModel
        let text: String
        if publicBlocksSetter {
            view.blocks = blocks
            #expect(await eventually { view.currentSnapshot != nil })
            let snapshot = try #require(view.currentSnapshot)
            model = snapshot.displayModel
            text = snapshot.attributedString.string
            #expect(snapshot.blockStarts == [0, 9])
            #expect(view.blocks == blocks)
        } else {
            let registry = RenderSessionSinkRegistry()
            let sink = RecordingRenderSink()
            let session = MarkdownRenderSession(registry: registry)
            registry.register(sink, for: session.id)
            let driver = MarkdownRenderSessionDriver(session: session)
            driver.send(.setDocument(document, MarkdownRenderConfiguration.default.snapshot(generation: 0)))
            #expect(await eventually { sink.models.count == 1 })
            model = try #require(sink.models.first)
            text = try #require(sink.strings.first)
            driver.send(.dismantle)
        }
        #expect(Set(model.blocks.map(\.lineage)).count == 2)
        let firstID = try #require(model.blocks[0].runs.first?.resourceID)
        let secondID = try #require(model.blocks[1].runs.first?.resourceID)
        #expect(firstID != secondID)
        #expect(model.resources == [
            .image(id: firstID, source: "file:///first-missing.png", alt: "first"),
            .image(id: secondID, source: "file:///second-missing.png", alt: "second"),
        ])
        let firstImage = PlatformImage()
        let secondImage = PlatformImage()
        var resolved: [ResourceID: ResolvedPlatformResource] = [:]
        resolved[firstID] = .image(firstImage, owner: TestResourceOwner(retaining: firstImage))
        resolved[secondID] = .image(secondImage, owner: TestResourceOwner(retaining: secondImage))
        let materialized = RenderMaterializer(configuration: MarkdownRenderConfiguration.default.snapshot(generation: 1)).materialize(model, resources: .init(values: resolved))
        #expect(materialized.attributedString.string == "\u{FFFC}\n\u{FFFC}")
        let firstAttachment = materialized.attributedString.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        let secondAttachment = materialized.attributedString.attribute(.attachment, at: 2, effectiveRange: nil) as? NSTextAttachment
        #expect(firstAttachment?.image === firstImage)
        #expect(secondAttachment?.image === secondImage)
        #expect(text == "🖼 first\n🖼 second")
        let rebuilt = MarkdownDocument(parsedBlocks: blocks.map { ParsedBlockNode(block: $0) })
        #expect(document.blockStorage.map(\.lineage) == rebuilt.blockStorage.map(\.lineage))
        let roundTrip = MarkdownDocument(parsedBlocks: document.parsedBlocks)
        #expect(document.blockStorage.map(\.lineage) == roundTrip.blockStorage.map(\.lineage))
        let sourceBacked = MarkdownDocument(parsing: "one $x$ two\n")
        #expect(sourceBacked.blockStorage.map(\.lineage) == MarkdownDocument(parsedBlocks: sourceBacked.parsedBlocks).blockStorage.map(\.lineage))
    }

    @Test("Escaped reference-label closers invalidate prior links at every append boundary")
    func escapedReferenceDefinitionBoundaries() throws {
        for label in [#"foo\]"#, #"foo\\\]"#, #"foo\\"#] {
            let prefix = "[link][\(label)]\n\n"
            let definition = "[\(label)]: /target\n"
            let bytes = Array(definition.utf8)
            for boundary in 0 ... bytes.count {
                var buffer = IncrementalSourceBuffer()
                var metrics = ParseWorkMetrics()
                try buffer.append(prefix, metrics: &metrics)
                let previous = try buffer.parse(previous: nil)
                let first = String(decoding: bytes[..<boundary], as: UTF8.self)
                try buffer.append(first, metrics: &metrics)
                let partial = try buffer.parse(previous: previous)
                #expect(partial.document.parsedBlocks == MarkdownDocument(parsing: prefix + first).parsedBlocks)
                try buffer.append(bytes: Array(bytes[boundary...]), metrics: &metrics)
                let result = try buffer.parse(previous: partial)
                #expect(result.document.parsedBlocks == MarkdownDocument(parsing: prefix + definition).parsedBlocks)
                #expect(result.document.blocks == [.paragraph([.link(destination: "/target", title: nil, children: [.text("link")])])])
                #expect(result.fullParseReason == .referenceDefinition)
                #expect(result.invalidationStartByte == 0)
            }
        }
    }

    @Test("Retained table/resource suffixes survive prefix insertion and deletion without stale positions", arguments: [false, true])
    @MainActor func shiftedSuffixMaterialization(_ deleting: Bool) throws {
        let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 1)
        let prefix = MarkdownDocument(parsing: "# Inserted\n\nSecond prefix\n\n").parsedBlocks
        let suffix = MarkdownDocument(parsing: "| VeryVeryLongHeading | OtherLongHeading |\n|---|---|\n| a | b |\n\n![image](asset.png)\n").parsedBlocks
        let oldNodes = (deleting ? prefix : []) + suffix
        let newNodes = (deleting ? [] : prefix) + suffix
        func input(_ nodes: [ParsedBlockNode], previous: RenderDisplayModel? = nil) -> RenderInput {
            RenderInput(
                document: MarkdownDocument(parsedBlocks: nodes),
                source: nil,
                availableWidth: 40,
                configuration: configuration,
                placeholderMode: .streaming,
                previousModel: previous
            )
        }
        let preparer = RenderPreparer(configuration: configuration)
        let old = try preparer.prepare(input(oldNodes))
        let nextInput = input(newNodes, previous: old)
        var metrics = ParseWorkMetrics()
        let delta = try preparer.prepareDelta(
            nextInput,
            replacing: 0 ..< (deleting ? prefix.count : 0),
            with: 0 ..< (deleting ? 0 : prefix.count),
            metrics: &metrics
        )
        let merged = delta.applying(to: old)
        let fresh = try preparer.prepare(nextInput)
        #expect(merged == fresh)
        #expect(merged.resources == old.resources)
        #expect(delta.removedResourceIDs.isEmpty)
        let materializer = RenderMaterializer(configuration: configuration)
        let actual = materializer.materialize(merged, resources: .init(values: [:]))
        let expected = materializer.materialize(fresh, resources: .init(values: [:]))
        #expect(actual.attributedString.isEqual(to: expected.attributedString))
        #expect(actual.blockStarts == expected.blockStarts)
        #expect(Set(actual.tableOverlays.keys) == Set(expected.tableOverlays.keys))
        #expect(Set(actual.tableOverlays.keys) == [deleting ? 0 : 2])
        for (index, overlay) in actual.tableOverlays {
            let oracle = try #require(expected.tableOverlays[index])
            #expect(overlay.attributedString.isEqual(to: oracle.attributedString))
            #expect(overlay.naturalWidth == oracle.naturalWidth)
            #expect(overlay.height == oracle.height)
        }
    }

    @Test("Unverifiable recorded UTF-8 boundaries fall back to zero instead of decoding a partial scalar")
    func invalidRecordedBoundary() throws {
        for boundary in [-1, 3, 999] {
            var buffer = IncrementalSourceBuffer()
            var metrics = ParseWorkMetrics()
            let source = "# 😀\n\n"
            try buffer.append(source, metrics: &metrics)
            let previous = try buffer.parse(previous: nil)
            let s = previous.state
            let state = IncrementalParseState(
                safeUTF8Boundary: boundary,
                fence: s.fence,
                inlineCodeDelimiterLength: s.inlineCodeDelimiterLength,
                math: s.math,
                lineContext: s.lineContext,
                sourceUTF8Count: s.sourceUTF8Count,
                sourceOrigin: s.sourceOrigin,
                sourceWitness: s.sourceWitness,
                hasReferences: s.hasReferences,
                requiresGlobalContext: s.requiresGlobalContext,
                endsInNewline: s.endsInNewline,
                containsMathSyntax: s.containsMathSyntax,
                containsCodeSyntax: s.containsCodeSyntax,
                containsReservedScalar: s.containsReservedScalar
            )
            let corrupted = IncrementalParseResult(
                document: previous.document,
                state: state,
                fullParseReason: previous.fullParseReason,
                invalidationStartByte: previous.invalidationStartByte,
                changedBlockRange: previous.changedBlockRange,
                replacedPreviousRange: previous.replacedPreviousRange,
                lineageChanges: previous.lineageChanges,
                metrics: previous.metrics
            )
            try buffer.append("# Next\n\n", metrics: &metrics)
            let result = try buffer.parse(previous: corrupted)
            #expect(result.invalidationStartByte == 0)
            #expect(result.fullParseReason == .missingState)
            #expect(result.document == MarkdownDocument(parsing: source + "# Next\n\n"))
        }
    }

    @Test @MainActor func accessibilitySplicePreservesNonemptyPrefixAndSuffix() throws {
        let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 1)
        let document = MarkdownDocument(parsing: "# A\n\n# B\n\n# C\n")
        let input = RenderInput(document: document, source: nil, availableWidth: 320, configuration: configuration, placeholderMode: .streaming)
        func root(_ index: Int, label: String) -> AccessibilityNode {
            let id = AccessibilityNodeID(sourceGeneration: 1, role: .heading(level: 1), startAnchor: index * 5, lineage: UInt64(index))
            let leafID = AccessibilityNodeID(sourceGeneration: 1, role: .text, startAnchor: index * 5 + 2, lineage: UInt64(index))
            return AccessibilityNode(
                id: id,
                role: .heading(level: 1),
                label: nil,
                children: [AccessibilityNode(id: leafID, role: .text, label: label)]
            )
        }
        let prepared = try RenderPreparer(configuration: configuration).prepare(input)
        let bundles = prepared.bundles.enumerated().map { index, bundle in
            DisplayBlockBundle(
                block: bundle.block,
                resources: bundle.resources,
                content: bundle.content,
                accessibilityRoots: [root(index, label: "old \(index)")]
            )
        }
        let previous = RenderDisplayModel(bundles: PersistentValues(bundles), input: input)
        let replacement = DisplayBlockBundle(
            block: bundles[1].block,
            resources: [],
            content: bundles[1].content,
            accessibilityRoots: [root(1, label: "updated")]
        )
        let delta = RenderDisplayDelta(
            replacedPreviousBlocks: 1 ..< 2,
            changedDocumentBlocks: 1 ..< 2,
            replacementStorage: PersistentValues([replacement]),
            removedResourceIDs: [],
            input: input
        )
        let merged = delta.applying(to: previous)
        #expect(delta.replacementAccessibilityRoots == [root(1, label: "updated")])
        #expect(merged.accessibility.roots == [root(0, label: "old 0"), root(1, label: "updated"), root(2, label: "old 2")])
        #expect(merged.accessibility.roots.map(\.id) == previous.accessibility.roots.map(\.id))
    }

    @Test("State retains open fence, inline delimiter, math and original line origin")
    func scannerStateMatrix() throws {
        let cases: [(String, Int?, MathDelimiterState, UInt8?, Int)] = [
            ("# Head\n\n`open", 1, .closed, nil, 8),
            ("# Head\n\n```swift\nbody", nil, .closed, 96, 17),
            ("# Head\n\n$x", nil, .dollar, nil, 8),
            ("# Head\n\n\\[x", nil, .bracket, nil, 8),
        ]
        for (source, inline, math, fence, lineStart) in cases {
            var buffer = IncrementalSourceBuffer()
            var metrics = ParseWorkMetrics()
            try buffer.append(source, metrics: &metrics)
            let result = try buffer.parse(previous: nil)
            #expect(result.state.inlineCodeDelimiterLength == inline)
            #expect(result.state.math == math)
            #expect(result.state.fence?.marker == fence)
            #expect(result.state.lineContext.lineStart == lineStart)
        }
    }

    @Test("Reserved scalars round-trip even inside a combining grapheme")
    func reservedCombiningScalar() {
        let literal = "before \u{10FE00}\u{301} after"
        #expect(MathSentinel.unescapeReservedScalar(MathSentinel.escapeReservedScalar(literal)) == literal)
        #expect(MarkdownDocument(parsing: literal + " $x$").blocks == [.paragraph([.text(literal + " "), .math(latex: "x")])])
    }

    @Test("A global reference fallback excludes unchanged prefix and suffix from its delta")
    func globalFallbackTrimsUnchangedBlocks() throws {
        var buffer = IncrementalSourceBuffer()
        var metrics = ParseWorkMetrics()
        let prefix = "# Keep\n\n[ref][id]\n\n# Stay\n\n"
        try buffer.append(prefix, metrics: &metrics)
        let previous = try buffer.parse(previous: nil)
        try buffer.append("[id]: /target\n", metrics: &metrics)
        let result = try buffer.parse(previous: previous)
        #expect(result.fullParseReason == .referenceDefinition)
        #expect(result.changedBlockRange == 1 ..< 2)
        #expect(result.replacedPreviousRange == 1 ..< 2)
        #expect(result.document == MarkdownDocument(parsing: prefix + "[id]: /target\n"))
    }

    @Test @MainActor func lineageUsesStartAndRoleWhileGrowing() throws {
        let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 0)
        let preparer = RenderPreparer(configuration: configuration)
        func model(_ source: String) throws -> RenderDisplayModel {
            try preparer.prepare(RenderInput(
                document: MarkdownDocument(parsing: source),
                source: source,
                availableWidth: 320,
                configuration: configuration,
                placeholderMode: .streaming
            ))
        }
        for (before, after) in [("Text", "Text grows"), ("- one\n", "- one\n- two\n"),
                                ("| a |\n| - |\n", "| a |\n| - |\n| b |\n")] {
            #expect(try model(before).blocks[0].lineage == model(after).blocks[0].lineage)
        }
        #expect(try model("Title\n").blocks[0].lineage != model("Title\n---\n").blocks[0].lineage)
        let math = try model("$$x$$\n\n$$y$$\n")
        #expect(math.blocks[0].lineage != math.blocks[1].lineage)
    }

    @Test("Foreign and forked state fall back without inheriting stale syntax")
    func stateProvenance() throws {
        var original = IncrementalSourceBuffer()
        var metrics = ParseWorkMetrics()
        try original.append("[id]: /old\n\n", metrics: &metrics)
        let previous = try original.parse(previous: nil)
        var replacement = IncrementalSourceBuffer()
        try replacement.append("# New\n\n", metrics: &metrics)
        let reset = try replacement.parse(previous: previous)
        #expect(reset.fullParseReason == .nonPrefixEdit)
        #expect(reset.invalidationStartByte == 0)
        #expect(!reset.state.hasReferences)
        #expect(reset.document == MarkdownDocument(parsing: "# New\n\n"))

        var branch = replacement
        try branch.append("# Left\n\n", metrics: &metrics)
        let left = try branch.parse(previous: reset)
        try replacement.append("# Right\n\n", metrics: &metrics)
        let right = try replacement.parse(previous: left)
        #expect(right.fullParseReason == .inconsistentPrefix)
        #expect(right.invalidationStartByte == 0)
        #expect(right.document == MarkdownDocument(parsing: "# New\n\n# Right\n\n"))
    }

    @Test("A carriage return only triggers splitCRLF when the next byte is LF")
    func bareCarriageReturnAppend() throws {
        var buffer = IncrementalSourceBuffer()
        var metrics = ParseWorkMetrics()
        try buffer.append("# Head\n\nparagraph\r", metrics: &metrics)
        let previous = try buffer.parse(previous: nil)
        try buffer.append("next\n", metrics: &metrics)
        let result = try buffer.parse(previous: previous)
        #expect(result.fullParseReason != .splitCRLF)
        #expect(result.document == MarkdownDocument(parsing: "# Head\n\nparagraph\rnext\n"))
    }

    @Test("Source ranges use UTF-8 columns across CR, LF and CRLF")
    func carriageReturnRanges() {
        for ending in ["\r", "\n", "\r\n"] {
            let prefix = "# 中文" + ending + ending
            let document = MarkdownDocument(parsing: prefix + "body" + ending)
            #expect(document.parsedBlocks[0].sourceRange == MarkdownSourceRange(lowerBound: 0, upperBound: 8))
            #expect(document.parsedBlocks[1].sourceRange == MarkdownSourceRange(lowerBound: prefix.utf8.count, upperBound: prefix.utf8.count + 4))
            #expect(document.parsedBlocks[1].fingerprint != nil)
        }
    }

    @Test @MainActor func displayDeltaReplacesOnlyChangedBlocksAndResources() throws {
        let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 7)
        let oldSource = "![keep](keep.png)\n\n![remove](old.png)\n\n# Suffix\n"
        let newSource = "![keep](keep.png)\n\nNew **text** here.\n\n# Suffix\n"
        let oldInput = RenderInput(
            document: MarkdownDocument(parsing: oldSource),
            source: oldSource,
            availableWidth: 320,
            configuration: configuration,
            placeholderMode: .streaming
        )
        let preparer = RenderPreparer(configuration: configuration)
        let previous = try preparer.prepare(oldInput)
        let input = RenderInput(
            document: MarkdownDocument(parsing: newSource),
            source: newSource,
            availableWidth: 320,
            configuration: configuration,
            placeholderMode: .streaming,
            previousModel: previous
        )
        var metrics = ParseWorkMetrics()
        let delta = try preparer.prepareDelta(input, replacing: 1 ..< 2, with: 1 ..< 2, metrics: &metrics)
        #expect(delta.replacementBlocks.count == 1)
        #expect(delta.replacementRuns.map(\.text) == ["New ", "text", " here."])
        #expect(delta.removedResourceIDs == Set(previous.blocks[1].runs.compactMap(\.resourceID)))
        #expect(delta.replacementResources.isEmpty)
        let merged = delta.applying(to: previous)
        let full = try preparer.prepare(input)
        #expect(merged == full)
        #expect(merged.blocks[0] == previous.blocks[0])
        #expect(merged.resources == [previous.resources[0]])
    }

    @Test("Non-local invalidation preserves its reason and validated boundary")
    func invalidationMatrix() throws {
        let cases: [(String, String, FullParseReason, Int)] = [
            ("# Head\n\n[ref][id]\n\nTail\n\n", "[id]: /destination\n", .referenceDefinition, 0),
            ("# Head\n\nTitle\n", "---\n", .setextOrThematicBreak, 8),
            ("# Head\n\n<div>\none\n", "two\n</div>\n", .htmlBlock, 8),
            ("# Head\n\n> quoted\n", "lazy\n", .lazyContainer, 8),
            ("# Head\n\n- item\n", "  continuation\n", .lazyContainer, 8),
            ("# Head\n\nparagraph\r", "\nnext\n", .splitCRLF, 0),
            ("# Head\n\nparagraph", " continues\n", .missingFinalNewline, 8),
        ]
        for (prefix, append, reason, boundary) in cases {
            var buffer = IncrementalSourceBuffer()
            var metrics = ParseWorkMetrics()
            try buffer.append(prefix, metrics: &metrics)
            let previous = try buffer.parse(previous: nil, metrics: metrics)
            try buffer.append(append, metrics: &metrics)
            let result = try buffer.parse(previous: previous, metrics: metrics)
            #expect(result.fullParseReason == reason, "prefix=\(prefix.debugDescription)")
            #expect(result.invalidationStartByte == boundary)
            #expect(result.document == MarkdownDocument(parsing: prefix + append))
            print("TASK5_FALLBACK reason=\(reason) start=\(result.invalidationStartByte) N=\(buffer.utf8Count) cmark=\(result.metrics.cmarkInputBytes)")
        }
    }

    @Test("Stateful raw-byte streaming matches every complete UTF-8 prefix", arguments: fixtures)
    @MainActor func rawByteStream(_ fixture: String) throws {
        var buffer = IncrementalSourceBuffer()
        var previous: IncrementalParseResult?
        var bytes: [UInt8] = []
        var metrics = ParseWorkMetrics()
        let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 0)
        let preparer = RenderPreparer(configuration: configuration)
        var model: RenderDisplayModel?
        for byte in fixture.utf8 {
            bytes.append(byte)
            try buffer.append(bytes: [byte], metrics: &metrics)
            guard let source = String(validating: bytes, as: UTF8.self) else { continue }
            let result = try buffer.parse(previous: previous, metrics: metrics)
            #expect(result.document.parsedBlocks == MarkdownDocument(parsing: source).parsedBlocks, "source=\(source.debugDescription)")
            #expect(result.state.sourceUTF8Count == source.utf8.count)
            #expect(result.lineageMapping.map(\.newIndex) == Array(0 ..< result.document.blocks.count))
            let input = RenderInput(
                document: result.document,
                source: source,
                availableWidth: 320,
                configuration: configuration,
                placeholderMode: .streaming,
                previousModel: model
            )
            if let old = model {
                let delta = try preparer.prepareDelta(
                    input,
                    replacing: result.replacedPreviousRange,
                    with: result.changedBlockRange,
                    metrics: &metrics
                )
                model = delta.applying(to: old, metrics: &metrics)
            } else { model = try preparer.prepare(input) }
            let fresh = RenderInput(
                document: MarkdownDocument(parsing: source),
                source: source,
                availableWidth: 320,
                configuration: configuration,
                placeholderMode: .streaming
            )
            #expect(try model == (preparer.prepare(fresh)), "display source=\(source.debugDescription)")
            previous = result
            metrics = ParseWorkMetrics()
        }
    }

    @Test("A chunk appended after closed blocks does not prepare the unchanged prefix")
    func stableBlockBoundary() throws {
        var buffer = IncrementalSourceBuffer()
        var metrics = ParseWorkMetrics()
        try buffer.append("# Stable\n\nFirst paragraph.\n\n", metrics: &metrics)
        let first = try buffer.parse(previous: nil, metrics: metrics)
        metrics = ParseWorkMetrics()
        try buffer.append("# Next\n\n", metrics: &metrics)
        let next = try buffer.parse(previous: first, metrics: metrics)
        #expect(next.fullParseReason == nil)
        #expect(next.changedBlockRange == 2 ..< 3)
        #expect(next.metrics.cmarkInputBytes == 8)
        #expect(next.document == MarkdownDocument(parsing: "# Stable\n\nFirst paragraph.\n\n# Next\n\n"))
    }

    static let fixtures = [
        "# Stable\n\n[link][id]\n\nTail\n\n[id]: https://example.com\n",
        "# Stable\n\n$x$ and $$y$$\n\n\\(z\\) \\[w\\]\n",
        "# Stable\n\n```swift\nlet x = \"$a$\"\n```\n\n`$b$`\n\n    $c$\n",
        "# 😀\n\ne\u{301} 中文 👩‍👩‍👧‍👦\n\nLast",
        "# Stable\n\nTitle\n---\n\n* * *\n",
        "# Stable\n\n<div>\none\n\ntwo\n</div>\n",
        "# Stable\n\n<!-- open\n\nclose -->\n",
        "# Stable\n\n> quote\nlazy\n\n> next\n",
        "# Stable\n\n- one\n  continuation\n\n- two\n",
        "# Stable\n\n| A | B |\n| --- | --- |\n| c | d |\n",
        "# Stable\r\n\r\nBody\r\n\r\nEnd\r",
        "# Stable\r\rBody\r\rEnd\r",
        "# Stable\n\n[broken](\n\n$$open\n\nend",
        "# Stable\n\n\\[open\n\n# heading\n\nclose\\]\n",
    ]

    /// Every scalar boundary is tested without repairing partial UTF-8 into U+FFFD.
    /// The byte-buffer suite separately feeds each individual byte of multibyte scalars.
    @Test("Every UTF-8 scalar boundary agrees with full blocks, ranges and fingerprints", arguments: fixtures)
    func everyBoundary(_ fixture: String) {
        let bytes = Array(fixture.utf8)
        for split in 0 ... bytes.count {
            guard let prefix = String(validating: bytes[..<split], as: UTF8.self),
                  let suffix = String(validating: bytes[split...], as: UTF8.self)
            else { continue }
            let prior = MarkdownDocument(parsing: prefix)
            let result = prior.parsingAppend(to: prefix + suffix, previousSource: prefix)
            #expect(result == MarkdownDocument(parsing: fixture), "split=\(split), source=\(fixture.debugDescription)")
        }
    }

    @Test("Appended definitions update links before the reparsed tail")
    func referencesInvalidatePrefix() {
        let prefix = "[reference][id]\n\nTail\n\n"
        let source = prefix + "[id]: https://example.com\n"
        let result = MarkdownDocument(parsing: prefix).parsingAppend(to: source, previousSource: prefix)
        #expect(result == MarkdownDocument(parsing: source))
        #expect(result.blocks.first == .paragraph([.link(destination: "https://example.com", title: nil, children: [.text("reference")])]))
    }

    @Test("Sequential scalar appends agree after every accepted byte boundary", arguments: fixtures)
    func sequentialBoundaries(_ fixture: String) {
        var source = ""
        var document = MarkdownDocument(parsing: source)
        for scalar in fixture.unicodeScalars {
            let next = source + String(scalar)
            document = document.parsingAppend(to: next, previousSource: source)
            source = next
            #expect(document == MarkdownDocument(parsing: source), "accepted UTF-8 bytes=\(source.utf8.count)")
        }
    }

    @Test("Fixed-seed mixed-size chunks preserve non-local semantics")
    func seededChunks() throws {
        let fixture = String(repeating: "# Heading\n\nText **bold** 中文.\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n", count: 80)
            + "[reference][id]\n\nTail\n\n[id]: https://example.com\n"
        let bytes = Array(fixture.utf8)
        var seed: UInt64 = 0x4D_6172_6B64_6F77
        var offset = 0
        var source = ""
        var buffer = IncrementalSourceBuffer()
        var previous: IncrementalParseResult?
        while offset < bytes.count {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            var end = min(bytes.count, offset + 1 + Int(seed % 127))
            while end < bytes.count, bytes[end] & 0xC0 == 0x80 {
                end += 1
            }
            let chunk = String(decoding: bytes[offset ..< end], as: UTF8.self)
            let next = source + chunk
            var metrics = ParseWorkMetrics()
            try buffer.append(chunk, metrics: &metrics)
            let result = try buffer.parse(previous: previous, metrics: metrics)
            source = next
            offset = end
            #expect(result.document == MarkdownDocument(parsing: source), "seeded boundary=\(end)")
            previous = result
        }
    }
}
