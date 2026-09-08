import MarkdownCore

public struct RenderDisplayModel: Sendable, Equatable {
    /// Explicit diagnostic facade. Materialization reads each bundle directly.
    package var syntaxSpans: [SyntaxHighlightKey: [SyntaxHighlightSpan]] {
        var metrics = ParseWorkMetrics()
        var result: [SyntaxHighlightKey: [SyntaxHighlightSpan]] = [:]
        for bundle in self.bundles {
            for entry in bundle.syntaxSpans {
                let (key, spans) = (entry.key, entry.spans)
                metrics.materializationBytes = ParseWorkMetrics.saturatingAdd(metrics.materializationBytes, key.code.utf8.count + (key.language?.utf8.count ?? 0))
                metrics.recordMetadata(MemoryLayout<SyntaxHighlightKey>.stride + MemoryLayout<[SyntaxHighlightSpan]>.stride)
                result[key] = spans
            }
        }
        self.preparedDocument?.workRecorder?.recordFacade(metrics)
        return result
    }

    package func preparingSyntax(using cache: SyntaxHighlightCache = .shared, recorder: ParseAttemptRecorder? = nil) async -> Self {
        var metrics = ParseWorkMetrics(recording: recorder)
        guard let bundles = try? await Self.prepareSyntax(self.bundles, using: cache, metrics: &metrics) else { return self }
        return Self(copying: self, bundles: bundles)
    }

    /// Structured, value-only input preserves block nesting and semantics needed
    /// for width-dependent TextKit materialization. No platform object crosses here.
    package let preparedDocument: MarkdownDocument?
    package var preparedBlocks: [ParsedBlockNode]? {
        self.preparedDocument?.parsedBlocks
    }

    private let storedSource: String?
    package let sourceBuffer: IncrementalSourceBuffer?
    package var source: String? {
        guard let sourceBuffer else { return self.storedSource }
        var metrics = ParseWorkMetrics()
        let result = try? sourceBuffer.materialize(from: 0, metrics: &metrics, cancellable: false)
        self.preparedDocument?.workRecorder?.recordFacade(metrics)
        return result
    }

    package let availableWidth: Double
    package let placeholderMode: PlaceholderMode
    package let bundles: PersistentValues<DisplayBlockBundle>
    private let standaloneRuns: [DisplayRun]
    private let standaloneResources: [UnresolvedResource]
    private let standaloneAccessibility: AccessibilityTree
    package var contentValues: some Sequence<PreparedPiece> {
        self.bundles.lazy.flatMap(\.content)
    }

    package var resourceValues: ResourceSequence {
        ResourceSequence(standalone: self.standaloneResources, bundles: self.bundles)
    }

    package var preparedContent: [PreparedPiece]? {
        self.preparedDocument == nil ? nil : self.observeFlatMap(\.content)
    }

    /// Explicit O(runs) flat-array facade; streaming consumers use block bundles.
    public var runs: [DisplayRun] {
        self.preparedDocument == nil ? self.standaloneRuns : self.observeFlatMap { $0.block.runs }
    }

    /// Explicit O(blocks) flat-array facade.
    public var blocks: [DisplayBlock] {
        var metrics = ParseWorkMetrics()
        let result = self.bundles.materializedMap(\.block, metrics: &metrics)
        self.preparedDocument?.workRecorder?.recordFacade(metrics)
        return result
    }

    /// Explicit O(resources) flat-array facade.
    public var resources: [UnresolvedResource] {
        self.preparedDocument == nil ? self.standaloneResources : self.observeFlatMap(\.resources)
    }

    public var accessibility: AccessibilityTree {
        self.preparedDocument == nil ? self.standaloneAccessibility : AccessibilityTree(roots: self.observeFlatMap(\.accessibilityRoots))
    }

    private func observeFlatMap<T>(_ transform: (DisplayBlockBundle) -> [T]) -> [T] {
        var metrics = ParseWorkMetrics()
        let result = self.bundles.materializedFlatMap(transform, metrics: &metrics)
        self.preparedDocument?.workRecorder?.recordFacade(metrics)
        return result
    }

    public init(
        runs: [DisplayRun], blocks: [DisplayBlock], resources: [UnresolvedResource],
        accessibility: AccessibilityTree
    ) {
        self.preparedDocument = nil
        self.storedSource = nil
        self.sourceBuffer = nil
        self.availableWidth = 320
        self.placeholderMode = .streaming
        self.standaloneRuns = runs
        self.standaloneResources = resources
        self.standaloneAccessibility = accessibility
        self.bundles = PersistentValues(blocks.map { DisplayBlockBundle(block: $0, resources: [], content: [], accessibilityRoots: []) })
    }

    package init(bundles: PersistentValues<DisplayBlockBundle>, input: RenderInput) {
        self.bundles = bundles
        self.standaloneRuns = []
        self.standaloneResources = []
        self.standaloneAccessibility = AccessibilityTree(roots: [])
        self.preparedDocument = input.document
        self.storedSource = input.source
        self.sourceBuffer = input.sourceBuffer
        self.availableWidth = input.availableWidth
        self.placeholderMode = input.placeholderMode
    }

    private init(copying model: Self, bundles: PersistentValues<DisplayBlockBundle>) {
        self.bundles = bundles
        self.standaloneRuns = model.standaloneRuns
        self.standaloneResources = model.standaloneResources
        self.standaloneAccessibility = model.standaloneAccessibility
        self.preparedDocument = model.preparedDocument
        self.storedSource = model.storedSource
        self.sourceBuffer = model.sourceBuffer
        self.availableWidth = model.availableWidth
        self.placeholderMode = model.placeholderMode
    }

    package static func prepareSyntax(
        _ bundles: PersistentValues<DisplayBlockBundle>, using cache: SyntaxHighlightCache = .shared,
        metrics: inout ParseWorkMetrics
    ) async throws -> PersistentValues<DisplayBlockBundle> {
        var result: [DisplayBlockBundle] = []
        for bundle in bundles {
            try Task.checkCancellation()
            metrics.syntaxPreparationBlocks = ParseWorkMetrics.saturatingAdd(metrics.syntaxPreparationBlocks, 1)
            var spans: [PreparedSyntax] = []
            func visit(_ run: PreparedRun) async throws {
                try Task.checkCancellation()
                let language: String?
                switch run.kind {
                case .code(let value): language = value
                case .svg: language = "svg"
                default: return
                }
                metrics.renderPreparationBytes = ParseWorkMetrics.saturatingAdd(metrics.renderPreparationBytes, language?.utf8.count ?? 0)
                let key = SyntaxHighlightKey(code: run.text, language: language)
                metrics.renderPreparationBytes = ParseWorkMetrics.saturatingAdd(metrics.renderPreparationBytes, key.language?.utf8.count ?? 0)
                let prepared = try await cache.measuredSpans(for: key.code, language: key.language, recorder: metrics.recorder)
                var child = ParseWorkMetrics()
                child.renderPreparationBytes = prepared.workBytes
                child.metadataBytes = prepared.metadataBytes
                metrics.addRecorded(child)
                // Immutable recipes share their keys. No second full-code hash
                // is needed merely to store the block-local prepared result.
                metrics.recordArrayGrowth(spans, preparation: true)
                spans.append(PreparedSyntax(key: key, spans: prepared.spans))
                metrics.recordPreparationMetadata(MemoryLayout<PreparedSyntax>.stride)
            }
            for piece in bundle.content {
                switch piece {
                case .run(let run): try await visit(run)
                case .table(let table):
                    for cell in table.head {
                        for run in cell {
                            try await visit(run)
                        }
                    }
                    for row in table.rows {
                        for cell in row {
                            for run in cell {
                                try await visit(run)
                            }
                        }
                    }
                case .blockStart: break
                }
            }
            result.append(DisplayBlockBundle(
                block: bundle.block,
                resources: bundle.resources,
                content: bundle.content,
                accessibilityRoots: bundle.accessibilityRoots,
                syntaxSpans: spans
            ))
            metrics.recordPreparationMetadata(MemoryLayout<DisplayBlockBundle>.stride)
        }
        metrics.recordPreparationMetadata(88)
        return PersistentValues(result)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.runs == rhs.runs && lhs.blocks == rhs.blocks && lhs.resources == rhs.resources
            && lhs.accessibility == rhs.accessibility && lhs.preparedDocument == rhs.preparedDocument
            && lhs.source == rhs.source && lhs.availableWidth == rhs.availableWidth
            && lhs.placeholderMode == rhs.placeholderMode && lhs.preparedContent == rhs.preparedContent
            && lhs.syntaxSpans == rhs.syntaxSpans
    }
}

package struct PreparedSyntax: Equatable {
    package let key: SyntaxHighlightKey
    package let spans: [SyntaxHighlightSpan]
}

package struct DisplayBlockBundle: Equatable {
    package let block: DisplayBlock
    package let resources: [UnresolvedResource]
    package let content: [PreparedPiece]
    package let accessibilityRoots: [AccessibilityNode]
    package let syntaxSpans: [PreparedSyntax]
    package init(
        block: DisplayBlock,
        resources: [UnresolvedResource],
        content: [PreparedPiece],
        accessibilityRoots: [AccessibilityNode],
        syntaxSpans: [PreparedSyntax] = []
    ) {
        self.block = block; self.resources = resources; self.content = content
        self.accessibilityRoots = accessibilityRoots; self.syntaxSpans = syntaxSpans
    }
}

package struct ResourceSequence: Sequence {
    package let standalone: [UnresolvedResource]
    package let bundles: PersistentValues<DisplayBlockBundle>
    package struct Iterator: IteratorProtocol {
        package var current: ArraySlice<UnresolvedResource>
        package var bundles: PersistentValues<DisplayBlockBundle>.Iterator
        package mutating func next() -> UnresolvedResource? {
            while self.current.isEmpty {
                guard let bundle = self.bundles.next() else { return nil }
                self.current = bundle.resources[...]
            }
            return self.current.popFirst()
        }
    }

    package func makeIterator() -> Iterator {
        Iterator(current: self.standalone[...], bundles: self.bundles.makeIterator())
    }
}

package enum PreparedColor: Equatable {
    case body, secondary, code, inlineCode, inlineBackground, link, image, quote, clear
}

package struct PreparedParagraph: Equatable {
    package var lineSpacing: Double = 4
    package var spacing: Double = 0
    package var before: Double = 0
    package var head: Double = 0
    package var first: Double = 0
    package var tail: Double = 0
    package var height: Double = 0
    package var centered = false
    package var tab: Double?
}

package struct PreparedAttributes: Equatable {
    package var role: MarkdownTextRole? = .body
    /// Trait order preserves nested legacy bold/italic operations.
    package var traits: [Bool] = []
    package var color: PreparedColor? = .body
    package var background: PreparedColor?
    package var paragraph: PreparedParagraph?
    package var strike = false
    package var underline = false
    package var destination: String?
    package var tinyFont = false
}

package enum PreparedRunKind: Equatable {
    case text
    case code(language: String?)
    case image(id: ResourceID, source: String, width: Double, resolves: Bool)
    case math(id: ResourceID, latex: String, display: Bool, width: Double, staticPlaceholder: Bool, resolves: Bool)
    case svg(id: ResourceID, source: String, placeholderWidth: Double, placeholderHeight: Double, staticPlaceholder: Bool, resolves: Bool)
}

package struct PreparedRun: Equatable {
    package var text: String
    package var attributes: PreparedAttributes
    package var kind: PreparedRunKind = .text
    /// What this run contributes to a *rendered* copy when it materializes as an
    /// attachment and its `text` is therefore not in the string. `nil` means
    /// `text` is already what a reader sees.
    package var copyText: String?
    /// The Markdown syntax this run came from, for blocks the parser could not
    /// give a source range — a block-level formula lifted out of a paragraph has
    /// none, so without this its source copy would silently lose the delimiters.
    package var sourceText: String?
}

package struct PreparedTable: Equatable {
    /// Block-local eligibility (false for nested tables). The
    /// current global overlay index is derived during materialization.
    package let overlayEligible: Bool
    package let columns: [ColumnAlignment]
    package let head: [[PreparedRun]]
    package let rows: [[[PreparedRun]]]
    package let width: Double
    package var quoteIndent: Double = 0
}

package enum PreparedPiece: Equatable {
    case blockStart
    case run(PreparedRun)
    case table(PreparedTable)
}

public struct ResourceID: Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum UnresolvedResource: Sendable, Equatable {
    case image(id: ResourceID, source: String, alt: String?)
    case math(id: ResourceID, latex: String, display: Bool)
    case svg(id: ResourceID, source: String)
}

public struct DisplayRun: Sendable, Equatable {
    public let text: String
    public let role: MarkdownTextRole
    public let sourceRange: MarkdownSourceRange?
    public let resourceID: ResourceID?

    public init(
        text: String, role: MarkdownTextRole, sourceRange: MarkdownSourceRange? = nil,
        resourceID: ResourceID? = nil
    ) {
        self.text = text
        self.role = role
        self.sourceRange = sourceRange
        self.resourceID = resourceID
    }
}

public struct DisplayBlock: Sendable, Equatable {
    public let lineage: UInt64
    public let runs: [DisplayRun]
    public let sourceRange: MarkdownSourceRange?

    public init(lineage: UInt64, runs: [DisplayRun], sourceRange: MarkdownSourceRange? = nil) {
        self.lineage = lineage
        self.runs = runs
        self.sourceRange = sourceRange
    }
}
