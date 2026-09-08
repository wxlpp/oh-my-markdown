import Foundation
import MarkdownCore
@testable import MarkdownPlatformView
import MarkdownRenderKit
import Synchronization
import Testing

private enum LegacySVGViewBoxParser {
    /// 上限：超过此字节数后还没遇到 `<svg ` 起始即放弃，避免 pathological 长字符串扫描成本。
    private static let scanWindowBytes = 4096

    /// 解析 viewBox 的 `(width, height)` 原生尺寸（point 单位语义）。
    /// 调用方需自己决定 fit/scale 策略——常用模式是 fit-without-upscale：
    /// `target = (min(native.width, availableWidth), 按 native aspect 派生 height)`。
    /// w 或 h ≤ 0 返回 nil（无法绘制 + 防 division by zero）。
    static func parseSize(from svg: String) -> CGSize? {
        let scan = svg.prefix(self.scanWindowBytes)
        // 找 "<svg " 或 "<svg>" 起始
        guard let svgRange = scan.range(of: #"<svg(\s|>)"#, options: .regularExpression) else {
            return nil
        }
        // 找该 svg tag 内的 viewBox="..." attribute，限定到 svgRange 之后到 tag 结束符 ">"
        let afterSVG = scan[svgRange.upperBound...]
        guard let tagEnd = afterSVG.firstIndex(of: ">") else { return nil }
        let tagBody = afterSVG[..<tagEnd]
        guard let vbRange = tagBody.range(of: #"viewBox\s*=\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        // 抽出引号内 4 个数
        let vbAttr = tagBody[vbRange]
        guard let quoteStart = vbAttr.firstIndex(of: "\""),
              let quoteEnd = vbAttr.lastIndex(of: "\""),
              quoteStart < quoteEnd else {
            return nil
        }
        let inner = vbAttr[vbAttr.index(after: quoteStart) ..< quoteEnd]
        let tokens = inner.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" })
        guard tokens.count == 4 else { return nil }
        let nums = tokens.compactMap { Double($0) }
        guard nums.count == 4 else { return nil }
        let w = nums[2], h = nums[3]
        guard w > 0, h > 0 else { return nil } // 防 division by zero + 不可绘制
        return CGSize(width: w, height: h)
    }

    /// 解析 viewBox 的高宽比 `h / w`。等价于 `parseSize(from:).map { $0.height / $0.width }`。
    /// 仅对历史调用者保留——新代码应优先用 `parseSize` 拿完整尺寸做精确 fit。
    static func parseAspect(from svg: String) -> CGFloat? {
        self.parseSize(from: svg).map { CGFloat($0.height / $0.width) }
    }
}

/// Frozen pre-lexer implementation: intentionally independent, test-only regex oracle.
private actor LegacyRegexSyntaxCache {
    static let shared = LegacyRegexSyntaxCache()
    private typealias Kind = SyntaxHighlightKind
    private struct Entry {
        let id: UInt64
        let code: String
        let language: String
        let spans: [SyntaxHighlightSpan]
    }

    // Hash source bytes exactly once; dictionary/LRU keys are fixed-size values.
    // Collision comparisons are explicit and included in the work counter.
    private var cache: [UInt64: [Entry]] = [:]
    private var order: [(hash: UInt64, id: UInt64)] = []
    private var nextID: UInt64 = 0
    private var keywordCache: [String: NSRegularExpression] = [:]
    private let noTypeNameLangs: Set<String> = ["json", "bash", "sh", "shell", "css", "toml", "yaml", "yml", "mermaid"]
    init() {}

    func spans(for code: String, language: String?) -> [SyntaxHighlightSpan] {
        // The source-compatible nonthrowing API shares the exact algorithm.
        try! self.prepare(code, language: language, cancellable: false).spans
    }

    struct MeasuredSpans {
        let spans: [SyntaxHighlightSpan]
        let workBytes: Int
        let cacheHit: Bool
    }

    func measuredSpans(for code: String, language: String?) throws -> MeasuredSpans {
        try self.prepare(code, language: language, cancellable: true)
    }

    private func prepare(_ code: String, language: String?, cancellable: Bool) throws -> MeasuredSpans {
        let work = SyntaxWork(cancellable: cancellable)
        try work.check()
        try work.add(language?.utf8.count ?? 0) // lowercasing input
        let lang = language?.lowercased() ?? ""
        try work.add(lang.utf8.count) // lowercasing output
        var hash: UInt64 = 14_695_981_039_346_656_037
        for bytes in [code.utf8, lang.utf8] {
            for byte in bytes {
                try work.add(1); hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
            hash = (hash ^ 255) &* 1_099_511_628_211
        }
        if let bucket = self.cache[hash] {
            for entry in bucket {
                try work.add(code.utf8.count + lang.utf8.count) // exact collision equality inputs
                if entry.code == code, entry.language == lang {
                    try work.add(self.order.count * MemoryLayout<(UInt64, UInt64)>.stride)
                    try work.check()
                    self.order.removeAll { $0.id == entry.id }
                    self.order.append((hash, entry.id))
                    return MeasuredSpans(spans: entry.spans, workBytes: work.bytes, cacheHit: true)
                }
            }
        }
        try work.add(code.utf8.count) // NSString bridge input
        let nsLen = (code as NSString).length
        try work.add(nsLen * MemoryLayout<UInt16>.stride) // UTF-16 bridge payload
        let fullRange = NSRange(location: 0, length: nsLen)
        // Flat bitmap — O(1) read/write, no heap allocation per mark.
        // Value = Kind.rawValue of the winning token (0 = unpainted).
        var painted = [UInt8](repeating: 0, count: nsLen)
        try work.add(nsLen)
        var spans: [SyntaxHighlightSpan] = []

        /// Mark a range with a token colour, painting only positions not yet claimed by a
        /// higher-priority token. Partially-overlapping matches (e.g. a comment that
        /// contains a string literal) are split into contiguous unpainted sub-ranges so
        /// both tokens contribute their colour where they are the first claimant.
        @inline(__always)
        func paint(_ range: NSRange, _ kind: Kind) throws {
            guard range.length > 0 else {
                return
            }
            let lo = range.location
            let hi = min(lo + range.length, nsLen)
            guard lo < hi else {
                return
            }
            var subStart: Int?
            for i in lo ... hi {
                try work.add(1)
                if i < hi, painted[i] == 0 {
                    if subStart == nil {
                        subStart = i
                    }
                } else if let s = subStart {
                    let sub = NSRange(location: s, length: i - s)
                    for j in s ..< i {
                        try work.add(1)
                        painted[j] = kind.rawValue
                    }
                    spans.append(SyntaxHighlightSpan(range: sub, kind: kind))
                    try work.add(MemoryLayout<SyntaxHighlightSpan>.stride)
                    subStart = nil
                }
            }
        }

        @inline(__always)
        func apply(_ rx: NSRegularExpression, _ kind: Kind) throws {
            try work.add(nsLen * MemoryLayout<UInt16>.stride) // one opaque regex input pass
            var failure: (any Error)?
            rx.enumerateMatches(in: code, range: fullRange) { m, _, stop in
                guard let m else {
                    return
                }
                do { try paint(m.range, kind) }
                catch { failure = error; stop.pointee = true }
            }
            if let failure { throw failure }
            try work.check()
        }

        // ── Priority order ──────────────────────────────────────────────────
        // Strings come before comments so that comment delimiters *inside* a
        // string literal (e.g. "http://…", "/* not a comment */") do not win.
        // 1. Swift / Python triple-quoted strings
        try apply(self.tripleDoubleStringRx, .string)

        // 2. Ordinary string literals
        try apply(self.doubleStringRx, .string)
        try apply(self.singleStringRx, .string)
        if
            lang == "javascript" || lang == "js" ||
            lang == "typescript" || lang == "ts" || lang == "jsx" || lang == "tsx" {
            try apply(self.templateStringRx, .string)
        }

        // 3. Block comments  /* ... */
        try apply(self.blockCommentRx, .comment)

        // 4. Single-line comments  // ... or # ...
        try apply(self.lineCommentRxFor(lang), .comment)

        // 5. Numeric literals
        try apply(self.numberRx, .number)

        // 6. Language keywords
        if let kwRx = keywordRx(for: lang) {
            try apply(kwRx, .keyword)
        }

        // 7. PascalCase type names — skip for languages that don't have OOP types
        if !self.noTypeNameLangs.contains(lang) {
            try apply(self.typeNameRx, .type)
        }
        // ────────────────────────────────────────────────────────────────────

        let bucketSize = self.cache[hash]?.count ?? 0
        try work.add((bucketSize + 1) * MemoryLayout<Entry>.stride)
        try work.add(MemoryLayout<(UInt64, UInt64)>.stride)
        if self.order.count == 300 {
            try work.add(self.order.count * MemoryLayout<(UInt64, UInt64)>.stride)
        }
        try work.check() // cancellation never commits a partial cache result
        let id = self.nextID
        self.nextID &+= 1
        self.cache[hash, default: []].append(Entry(id: id, code: code, language: lang, spans: spans))
        self.order.append((hash, id))
        if self.order.count > 300 {
            let oldest = self.order.removeFirst()
            self.cache[oldest.hash]?.removeAll { $0.id == oldest.id }
            if self.cache[oldest.hash]?.isEmpty == true { self.cache[oldest.hash] = nil }
        }
        return MeasuredSpans(spans: spans, workBytes: work.bytes, cacheHit: false)
    }

    private final class SyntaxWork {
        var bytes = 0
        var sinceCheck = 0
        let cancellable: Bool
        init(cancellable: Bool) {
            self.cancellable = cancellable
        }

        func check() throws {
            if self.cancellable { try Task.checkCancellation() }
        }

        func add(_ count: Int) throws {
            self.bytes = ParseWorkMetrics.saturatingAdd(self.bytes, count)
            if count >= 1024 || self.sinceCheck >= 1024 - count {
                self.sinceCheck = 0
                try self.check()
            } else { self.sinceCheck += count }
        }
    }

    // MARK: - Precompiled regexes

    private lazy var blockCommentRx = self.rx(#"/\*[\s\S]*?\*/"#, [.dotMatchesLineSeparators])
    private lazy var slashCommentRx = self.rx(#"//[^\r\n]*"#)
    private lazy var hashCommentRx = self.rx(#"#[^\r\n]*"#)
    private lazy var tripleDoubleStringRx = self.rx(#""""[\s\S]*?""""#, [.dotMatchesLineSeparators])
    // Single-line strings: don't allow unescaped newlines so an unclosed quote
    // doesn't eat the rest of the file.
    private lazy var doubleStringRx = self.rx(#""(?:[^"\\\r\n]|\\.)*""#)
    private lazy var singleStringRx = self.rx(#"'(?:[^'\\\r\n]|\\.)*'"#)
    // Template literals can span lines.
    private lazy var templateStringRx = self.rx(#"`(?:[^`\\]|\\.)*`"#, [.dotMatchesLineSeparators])
    private lazy var numberRx = self.rx(#"\b(0x[\dA-Fa-f]+|0b[01]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#)
    private lazy var typeNameRx = self.rx(#"\b[A-Z][A-Za-z0-9_]*\b"#)

    // MARK: - Keyword regexes (built once per language, then cached)

    // MARK: - Keyword tables

    // swiftlint:disable line_length
    private let keywords: [String: [String]] = [
        "swift": [
            "actor", "any", "as", "associatedtype", "async", "await",
            "break", "case", "catch", "class", "continue", "convenience",
            "default", "defer", "deinit", "do", "dynamic",
            "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final",
            "for", "func", "get", "guard", "if", "import", "in", "indirect", "infix",
            "init", "inout", "internal", "is", "lazy", "let", "mutating",
            "nil", "nonisolated", "open", "operator", "optional", "override",
            "postfix", "precedencegroup", "prefix", "private", "protocol", "public",
            "repeat", "required", "rethrows", "return", "self", "set", "some", "static",
            "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
            "typealias", "unowned", "var", "weak", "where", "while",
        ],
        "python": [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
            "del", "elif", "else", "except", "False", "finally", "for", "from", "global",
            "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass",
            "raise", "return", "True", "try", "while", "with", "yield",
        ],
        "javascript": [
            "async", "await", "break", "case", "catch", "class", "const", "continue",
            "debugger", "default", "delete", "do", "else", "export", "extends", "finally",
            "for", "from", "function", "if", "import", "in", "instanceof", "let", "new",
            "null", "of", "return", "static", "super", "switch", "this", "throw", "true",
            "false", "try", "typeof", "undefined", "var", "void", "while", "with", "yield",
        ],
        "js": [
            "async", "await", "break", "case", "catch", "class", "const", "continue",
            "debugger", "default", "delete", "do", "else", "export", "extends", "finally",
            "for", "from", "function", "if", "import", "in", "instanceof", "let", "new",
            "null", "of", "return", "static", "super", "switch", "this", "throw", "true",
            "false", "try", "typeof", "undefined", "var", "void", "while", "with", "yield",
        ],
        "typescript": [
            "abstract", "as", "async", "await", "break", "case", "catch", "class", "const",
            "continue", "declare", "default", "delete", "do", "else", "enum", "export",
            "extends", "finally", "for", "from", "function", "if", "implements", "import",
            "in", "instanceof", "interface", "keyof", "let", "namespace", "new", "null",
            "of", "override", "private", "protected", "public", "readonly", "return",
            "static", "super", "switch", "this", "throw", "true", "false", "try", "type",
            "typeof", "undefined", "var", "void", "while", "with", "yield",
        ],
        "ts": [
            "abstract", "as", "async", "await", "break", "case", "catch", "class", "const",
            "continue", "declare", "default", "delete", "do", "else", "enum", "export",
            "extends", "finally", "for", "from", "function", "if", "implements", "import",
            "in", "instanceof", "interface", "keyof", "let", "namespace", "new", "null",
            "of", "override", "private", "protected", "public", "readonly", "return",
            "static", "super", "switch", "this", "throw", "true", "false", "try", "type",
            "typeof", "undefined", "var", "void", "while", "with", "yield",
        ],
        "kotlin": [
            "abstract", "actual", "annotation", "as", "break", "by", "catch", "class",
            "companion", "const", "constructor", "continue", "crossinline", "data", "do",
            "else", "enum", "expect", "external", "false", "final", "finally", "for",
            "fun", "if", "import", "in", "infix", "init", "inline", "inner", "interface",
            "internal", "is", "it", "lateinit", "noinline", "null", "object", "open",
            "operator", "out", "override", "package", "private", "protected", "public",
            "reified", "return", "sealed", "super", "suspend", "tailrec", "this", "throw",
            "true", "try", "typealias", "val", "var", "vararg", "when", "where", "while",
        ],
        "java": [
            "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char",
            "class", "const", "continue", "default", "do", "double", "else", "enum",
            "extends", "final", "finally", "float", "for", "goto", "if", "implements",
            "import", "instanceof", "int", "interface", "long", "native", "new", "null",
            "package", "private", "protected", "public", "return", "short", "static",
            "strictfp", "super", "switch", "synchronized", "this", "throw", "throws",
            "transient", "true", "false", "try", "var", "void", "volatile", "while",
        ],
        "rust": [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
            "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
            "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
            "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
        ],
        "go": [
            "break", "case", "chan", "const", "continue", "default", "defer", "else",
            "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
            "package", "range", "return", "select", "struct", "switch", "type", "var",
            "false", "nil", "true",
        ],
        "bash": [
            "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in",
            "select", "then", "until", "while", "echo", "return", "exit", "export", "local",
            "readonly", "declare", "source", "alias", "unset", "shift", "true", "false",
        ],
        "sh": [
            "case", "do", "done", "elif", "else", "esac", "fi", "for", "if", "in",
            "then", "until", "while", "echo", "return", "exit", "true", "false",
        ],
        "shell": [
            "case", "do", "done", "elif", "else", "esac", "fi", "for", "if", "in",
            "then", "until", "while", "echo", "return", "exit", "true", "false",
        ],
        "json": ["true", "false", "null"],
        "css": ["important", "media", "keyframes", "supports", "charset", "import", "namespace", "layer"],
        "_default": [
            "if", "else", "for", "while", "do", "switch", "case", "break", "continue",
            "return", "function", "class", "import", "export", "const", "let", "var",
            "true", "false", "null", "undefined", "new", "this", "void", "typeof",
        ],
    ]

    // swiftlint:enable line_length

    private func rx(
        _ pattern: String,
        _ opts: NSRegularExpression.Options = []
    )
        -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: opts)
    }

    private func lineCommentRxFor(_ lang: String) -> NSRegularExpression {
        switch lang {
        case "bash", "perl", "python", "r", "ruby",
             "sh", "shell", "toml", "yaml", "yml":
            self.hashCommentRx
        default:
            self.slashCommentRx
        }
    }

    private func keywordRx(for lang: String) -> NSRegularExpression? {
        let normalized = self.keywords[lang] == nil ? "_default" : lang
        if let cached = self.keywordCache[normalized] { return cached }
        let words = self.keywords[normalized]!
        let result = try? NSRegularExpression(pattern: #"\b("# + words.joined(separator: "|") + #")\b"#)
        self.keywordCache[normalized] = result
        return result
    }
}

@Suite("Incremental work budgets", .timeLimit(.minutes(5)))
struct IncrementalWorkBudgetTests {
    @Test("Cancellation inside owned preparation loops retains only completed work")
    @MainActor func partialPreparationAttemptAccounting() async throws {
        let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 0)
        let document = MarkdownDocument(parsedBlocks: [ParsedBlockNode(block: .paragraph(Array(repeating: .image(source: "image.png", alt: "alt"), count: 100_000)))])
        let recorder = ParseAttemptRecorder()
        let input = RenderInput(document: document, source: nil, availableWidth: 320, configuration: configuration, placeholderMode: .streaming, previousModel: nil, attemptRecorder: recorder)
        let checkpoint = SelfCancellingCheckpoint(at: 100)
        let task = Task.detached {
            var metrics = ParseWorkMetrics(recording: recorder)
            return try RenderPreparer(configuration: configuration).prepareBlocks(input, range: 0 ..< 1, metrics: &metrics, checkCancellation: checkpoint.check)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(recorder.snapshot().renderPreparationBytes >= 1024)
        #expect(recorder.snapshot().renderPreparationBytes < 100_000)
    }

    @Test("Failed preparation reports discarded work without a model publication")
    @MainActor func failedPreparationAttemptAccounting() async {
        let registry = RenderSessionSinkRegistry()
        let sink = RecordingRenderSink()
        let session = MarkdownRenderSession(registry: registry, configuration: MarkdownRenderConfiguration.default.snapshot(generation: 0), prepare: { input in
            _ = try RenderPreparer(configuration: input.configuration).prepare(input)
            throw RenderPreparer.PreparationError.configurationMismatch
        })
        registry.register(sink, for: session.id)
        let driver = MarkdownRenderSessionDriver(session: session)
        driver.send(.append("![alt](image.png)\n\n"))
        #expect(await eventually { sink.errors.count == 1 })
        #expect(sink.models.isEmpty)
        let diagnostics = await session.attemptDiagnostics
        #expect(diagnostics.acceptedCount == 0)
        #expect(diagnostics.discardedCount == 1)
        #expect(diagnostics.discarded.cmarkInputBytes > 0)
        #expect(diagnostics.discarded.renderPreparationBytes > 0)
        driver.send(.dismantle)
    }

    @Test("The admitted compatibility full-source job records every parse phase")
    func fullSourceJobAttemptAccounting() async throws {
        let job = parseJob("# heading $x$\n\n")
        let sink = RecordingParseSink()
        let admission = await ParseExecutor.shared.enqueue(job, sink: sink)
        #expect(admission != .busy)
        #expect(await eventually { await sink.results.count == 1 })
        let work = job.attemptRecorder.snapshot()
        #expect(work.scannerBytes > 0)
        #expect(work.mappingBytes > 0)
        #expect(work.cmarkInputBytes > 0)
        if case .parsed(_, let document) = try #require(await sink.results.first) {
            #expect(document == MarkdownDocument(parsing: job.source))
        } else { Issue.record("Expected full-source parse publication") }
    }

    @Test("Orphaned non-cancellable work remains in executor diagnostics")
    func orphanAttemptAccounting() async throws {
        let gate = AttemptCmarkGate()
        let executor = ParseExecutor(maxActive: 1, maxWaitingTokens: 64, afterCmark: gate.hold)
        var sink: RecordingParseSink? = RecordingParseSink()
        let weakSink = try WeakParseResultSink(#require(sink))
        let job = parseJob("orphan work")
        #expect(try await executor.enqueue(job, sink: #require(sink)) == .started)
        #expect(await eventually { gate.jobs.count == 1 })
        await executor.tombstone(job.submission.sessionToken)
        sink = nil
        #expect(weakSink.value == nil)
        #expect(await executor.diagnostics.activeCount == 1)
        gate.release(index: 0)
        #expect(await eventually { await executor.workDiagnostics.orphanedCount == 1 })
        let diagnostics = await executor.workDiagnostics
        #expect(diagnostics.orphaned == job.attemptRecorder.snapshot())
        #expect(diagnostics.orphaned.cmarkInputBytes == 11)
        #expect(diagnostics.orphaned.scannerBytes == 11)
        #expect(diagnostics.orphaned.mappingBytes == 0) // cancellation is observed immediately after cmark
        #expect(diagnostics.completedCount == 0)
    }

    @Test("Cancelled live preparation reports real discarded work without publishing")
    @MainActor func cancelledPreparationAttemptAccounting() async throws {
        let first = Mutex(true)
        let started = Mutex(false)
        let records = Mutex<[ParseAttemptRecorder]>([])
        let registry = RenderSessionSinkRegistry()
        let sink = RecordingRenderSink()
        let session = MarkdownRenderSession(registry: registry, configuration: MarkdownRenderConfiguration.default.snapshot(generation: 0), prepare: { input in
            if let recorder = input.attemptRecorder { records.withLock { $0.append(recorder) } }
            _ = input.document.blocks // Intentional facade work must follow this attempt even when cancelled.
            let model = try RenderPreparer(configuration: input.configuration).prepare(input)
            if first.withLock({ value in let old = value; value = false; return old }) {
                started.withLock { $0 = true }
                while !Task.isCancelled {
                    await Task.yield()
                }
                try Task.checkCancellation()
            }
            return model
        })
        registry.register(sink, for: session.id)
        let driver = MarkdownRenderSessionDriver(session: session)
        driver.send(.append("![alt](image.png)\n\n"))
        #expect(await eventually { started.withLock { $0 } })
        #expect(sink.models.isEmpty)
        let active = try #require(await session.submission)
        let forged = ParseSubmission(id: active.id, sessionToken: active.sessionToken, commitToken: active.commitToken, attempt: active.attempt + 1)
        await session.receive(.stale(submission: forged))
        #expect(await session.attemptDiagnostics.discardedCount == 0)
        driver.send(.setSource("# latest\n\n", MarkdownRenderConfiguration.default.snapshot(generation: 0)))
        #expect(await eventually { sink.models.count == 1 })
        #expect(await eventually { await session.attemptDiagnostics.discardedCount == 1 })
        let totals = await session.attemptDiagnostics
        #expect(totals.acceptedCount == 1)
        #expect(totals.discarded.renderPreparationBytes > 0)
        #expect(totals.discarded.facadeMaterializationCount == 1)
        #expect(totals.accepted.facadeMaterializationCount == 1)
        #expect(await session.facadeMaterializationCount == 2)
        var expected = ParseWorkMetrics()
        for recorder in records.withLock({ $0 }) {
            expected.add(recorder.snapshot())
        }
        #expect(totals.totalAttempted == expected)
        driver.send(.dismantle)
    }

    @Test("Rapid supersession accounts discarded attempts and publishes only latest")
    @MainActor func supersededAttemptAccounting() async {
        let gate = AttemptCmarkGate()
        let executor = ParseExecutor(maxActive: 1, maxWaitingTokens: 64, afterCmark: gate.hold)
        let registry = RenderSessionSinkRegistry()
        let sink = RecordingRenderSink()
        let session = MarkdownRenderSession(executor: executor, registry: registry, configuration: MarkdownRenderConfiguration.default.snapshot(generation: 0))
        registry.register(sink, for: session.id)
        let driver = MarkdownRenderSessionDriver(session: session)
        let chunk = "# " + String(repeating: "x", count: 1020) + "\n\n"
        driver.send(.append(chunk))
        #expect(await eventually { gate.jobs.count == 1 })
        driver.send(.append(chunk))
        #expect(await eventually { await session.currentToken?.sequence == 2 })
        driver.send(.append(chunk))
        #expect(await eventually { await session.attemptDiagnostics.discardedCount == 1 })
        #expect(await session.attemptDiagnostics.acceptedCount == 0)
        #expect(sink.models.isEmpty)
        gate.release(index: 0)
        #expect(await eventually { gate.jobs.count == 2 })
        #expect(await eventually { await session.attemptDiagnostics.discardedCount == 2 })
        #expect(await session.attemptDiagnostics.acceptedCount == 0)
        #expect(await session.attemptDiagnostics.discarded.total > 0)
        gate.release(index: 1)
        #expect(await eventually { sink.models.count == 1 })
        let totals = await session.attemptDiagnostics
        #expect(totals.acceptedCount == 1)
        #expect(totals.discardedCount == 2)
        #expect(totals.discarded.cmarkInputBytes == 1024)
        #expect(totals.accepted.cmarkInputBytes == 3072)
        #expect(totals.totalAttempted.cmarkInputBytes == 4096)
        #expect(totals.totalAttempted.materializationBytes == 3072)
        #expect(totals.totalAttempted.scannerBytes == 4096)
        #expect(totals.totalAttempted.mappingBytes == 8184)
        #expect(totals.totalAttempted.total == 19448)
        var workers = ParseWorkMetrics()
        for job in gate.jobs {
            workers.add(job.attemptRecorder.snapshot())
        }
        #expect(totals.totalAttempted.total == workers.total)
        #expect(totals.totalAttempted.total <= 16 * 3072)
        print("TASK5_SUPERSESSION N=3072 accepted=\(totals.acceptedCount) discarded=\(totals.discardedCount) scanner=\(totals.totalAttempted.scannerBytes) mapping=\(totals.totalAttempted.mappingBytes) materialization=\(totals.totalAttempted.materializationBytes) cmark=\(totals.totalAttempted.cmarkInputBytes) prepare=\(totals.totalAttempted.renderPreparationBytes) total=\(totals.totalAttempted.total)")
        driver.send(.dismantle)
    }

    @Test("Cancelled syntax preparation retains partial work without caching")
    func partialSyntaxAttemptAccounting() async throws {
        let cache = SyntaxHighlightCache()
        let recorder = ParseAttemptRecorder()
        let code = String(repeating: "// long comment\n", count: 100_000)
        let checkpoint = SelfCancellingCheckpoint(at: 2)
        let task = Task.detached { try await cache.measuredSpans(for: code, language: "swift", recorder: recorder, checkCancellation: checkpoint.check) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(recorder.snapshot().renderPreparationBytes >= 1024)
        #expect(recorder.snapshot().renderPreparationBytes < code.utf8.count)
        #expect(try await !cache.measuredSpans(for: code, language: "swift").cacheHit)
    }

    @Test("Attempt counters survive cancellation with nonzero partial scanner work")
    func partialScannerAttemptAccounting() async throws {
        let recorder = ParseAttemptRecorder()
        let source = String(repeating: "plain ", count: 100_000)
        let checkpoint = SelfCancellingCheckpoint(at: 5)
        let task = Task.detached {
            var metrics = ParseWorkMetrics(recording: recorder)
            return try MathScanner.scan(source, metrics: &metrics, checkCancellation: checkpoint.check)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let partial = recorder.snapshot()
        #expect(partial.scannerBytes >= 1024)
        #expect(partial.scannerBytes < source.utf8.count)
        #expect(partial.cmarkInputBytes == 0)
        let second = ParseAttemptRecorder()
        var local = ParseWorkMetrics(recording: second)
        local.addRecorded(partial)
        #expect(second.snapshot().total == 0)
        local.scannerBytes += 7
        #expect(second.snapshot().scannerBytes == 7)
        #expect(recorder.snapshot() == partial)
    }

    @Test("Explicit lineage projection is included in its operation-scoped facade recorder")
    func lineageFacadeAccounting() throws {
        let recorder = ParseWorkRecorder()
        var buffer = IncrementalSourceBuffer(recorder: recorder)
        var metrics = ParseWorkMetrics()
        try buffer.append("# Heading\n\n", metrics: &metrics)
        let parsed = try buffer.parse(previous: nil)
        #expect(recorder.snapshot().facadeMaterializationCount == 0)
        _ = parsed.lineageMapping
        #expect(recorder.snapshot().facadeMaterializationCount == 1)
        #expect(recorder.snapshot().metadataBytes > 0)
    }

    @Test("Growing tails are correctness diagnostics, never mislabeled as budget-safe", arguments: ["paragraph", "list", "table"])
    func growingTailDiagnostic(_ kind: String) throws {
        var buffer = IncrementalSourceBuffer()
        var previous: IncrementalParseResult?
        var cumulative = ParseWorkMetrics()
        var source = kind == "table" ? "| h |\n|---|\n" : ""
        if !source.isEmpty {
            var metrics = ParseWorkMetrics()
            try buffer.append(source, metrics: &metrics)
            previous = try buffer.parse(previous: nil, metrics: metrics)
            try cumulative.add(#require(previous).metrics)
        }
        var firstLineage: UInt64?
        for _ in 0 ..< 100 {
            let payload = String(repeating: "x", count: 1020)
            let chunk = kind == "paragraph" ? payload : kind == "list" ? "- " + payload + "\n" : "| " + payload + " |\n"
            source += chunk
            var metrics = ParseWorkMetrics()
            try buffer.append(chunk, metrics: &metrics)
            let result = try buffer.parse(previous: previous, metrics: metrics)
            cumulative.add(result.metrics)
            let lineage = result.document.blockStorage[0].lineage
            if let firstLineage { #expect(lineage == firstLineage) }
            else { firstLineage = lineage }
            previous = result
        }
        #expect(previous?.document == MarkdownDocument(parsing: source))
        #expect(cumulative.cmarkInputBytes > buffer.utf8Count * 40)
        print("TASK5_GROWING kind=\(kind) N=\(buffer.utf8Count) cmark=\(cumulative.cmarkInputBytes) total=\(cumulative.total) outside_safe_corpus=true")
    }

    @Test("Image alt flattening preserves upstream plain-text spelling and counts its payload")
    func imageAltPayload() throws {
        var buffer = IncrementalSourceBuffer()
        var metrics = ParseWorkMetrics()
        let alt = "bold ~gone~ `code` nested"
        try buffer.append("![**bold** ~~gone~~ `code` ![nested](x)](asset.png)\n", metrics: &metrics)
        let result = try buffer.parse(previous: nil)
        #expect(result.document.blocks == [.paragraph([.image(source: "asset.png", alt: alt)])])
        #expect(result.metrics.materializationBytes >= alt.utf8.count)
    }

    @Test("Reference invalidation recognition consumes one measured byte pass without a regex bridge")
    func referenceDecisionPass() throws {
        let source = "[id]: /target\n"
        var buffer = IncrementalSourceBuffer()
        var metrics = ParseWorkMetrics()
        try buffer.append(source, metrics: &metrics)
        let result = try buffer.parse(previous: nil)
        #expect(result.fullParseReason == .referenceDefinition)
        #expect(result.metrics.scannerBytes == source.utf8.count)
    }

    @Test("Wall-clock medians are diagnostics only, with attributed-string assembly reported separately")
    @MainActor func medianDiagnostics() async throws {
        let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 0)
        var pipelineTimes: [Double] = []
        var assemblyTimes: [Double] = []
        for run in 0 ..< 6 { // One warm-up followed by five measured runs.
            var buffer = IncrementalSourceBuffer()
            var previous: IncrementalParseResult?
            var model: RenderDisplayModel?
            let started = Date.timeIntervalSinceReferenceDate
            for _ in 0 ..< 100 {
                var metrics = ParseWorkMetrics()
                try buffer.append("# " + String(repeating: "x", count: 1020) + "\n\n", metrics: &metrics)
                let parsed = try buffer.parse(previous: previous, metrics: metrics)
                metrics = parsed.metrics
                let input = RenderInput(
                    document: parsed.document,
                    source: nil,
                    availableWidth: 320,
                    configuration: configuration,
                    placeholderMode: .streaming,
                    previousModel: model,
                    sourceBuffer: buffer
                )
                let preparer = RenderPreparer(configuration: configuration)
                if let old = model {
                    let delta = try preparer.prepareDelta(input, replacing: parsed.replacedPreviousRange, with: parsed.changedBlockRange, metrics: &metrics)
                    model = try await delta.preparingSyntax(metrics: &metrics).applying(to: old, metrics: &metrics)
                } else { model = try preparer.prepare(input) }
                previous = parsed
            }
            let pipeline = Date.timeIntervalSinceReferenceDate - started
            let assemblyStart = Date.timeIntervalSinceReferenceDate
            let snapshot = try RenderMaterializer(configuration: configuration).materialize(#require(model), resources: .init(values: [:]))
            #expect(snapshot.attributedString.length > 100_000)
            if run > 0 {
                pipelineTimes.append(pipeline)
                assemblyTimes.append(Date.timeIntervalSinceReferenceDate - assemblyStart)
            }
        }
        print("TASK5_MEDIAN N=102400 warmup=1 runs=5 parse_prepare_seconds=\(pipelineTimes.sorted()[2]) final_NSAttributedString_seconds=\(assemblyTimes.sorted()[2]) assembly_excluded_from_byte_gate=true")
    }

    @Test("SVG bounded byte scanner preserves ordinary legacy viewBox parsing")
    func svgMeasuredBoundary() throws {
        let fixtures = [
            "<svg width=\"9\" height=\"8\" viewBox=\"0 0 100 200\"></svg>",
            "<svg viewBox=\"0,0,100.5,200.25\" viewBox=\"0 0 2 3\"></svg>",
            "<svg viewBox = \"0 0 -1 2\"></svg>", "<svg viewBox=\"0 0 1e999 2\"></svg>",
            "<svg viewBox=\"0 0 nan 2\"></svg>", "<svg viewBox=\"0 0 1\"></svg>",
            "<svg viewBox='0 0 1 2'></svg>", "<svg width=\"5\" height=\"6\"></svg>",
            "<!-- comment -->\n<svg\tviewBox=\"-1 -2 3e2 4.5\"></svg>",
        ]
        for source in fixtures {
            var metrics = ParseWorkMetrics()
            #expect(try SVGViewBoxParser.parseSize(from: source, metrics: &metrics) == LegacySVGViewBoxParser.parseSize(from: source))
            #expect(metrics.renderPreparationBytes > 0)
        }
        for prefix in ["a" + String(repeating: "\u{301}", count: 100_000), String(repeating: "x", count: 4095) + "😀"] {
            var metrics = ParseWorkMetrics()
            #expect(try SVGViewBoxParser.parseSize(from: prefix + fixtures[0], metrics: &metrics) == nil)
            #expect(metrics.renderPreparationBytes <= 8192)
        }
    }

    @Test("Preparation counts source-derived URL, label, and language normalization payloads")
    @MainActor func preparationPayloadAccounting() throws {
        let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 0)
        let url = "https://example.com/" + String(repeating: "x", count: 200)
        let alt = String(repeating: "a", count: 200)
        for (source, minimum) in [("[label](\(url))", url.utf8.count * 2), ("![\(alt)](image.png)", alt.utf8.count + 5), ("``` SWIFT\nx\n```\n", 21)] {
            let input = RenderInput(
                document: MarkdownDocument(parsing: source),
                source: source,
                availableWidth: 320,
                configuration: configuration,
                placeholderMode: .streaming
            )
            var metrics = ParseWorkMetrics()
            _ = try RenderPreparer(configuration: configuration).prepareBlocks(input, range: 0 ..< input.document.blockStorage.count, metrics: &metrics)
            #expect(metrics.renderPreparationBytes >= minimum)
        }
    }

    @Test("Adversarial dense tokens retain exact UTF-16 output and linear work independently of corpus constants")
    func denseSyntaxDiagnostic() async throws {
        var ratios: [Double] = []
        for size in [10 * 1024, 100 * 1024, 1024 * 1024] {
            let cache = SyntaxHighlightCache()
            let code = String(repeating: "1 ", count: size / 2)
            let measured = try await cache.measuredSpans(for: code, language: "swift")
            #expect(measured.spans.count == size / 2)
            for (index, span) in measured.spans.enumerated() {
                #expect(span.kind == .number)
                #expect(span.range == NSRange(location: index * 2, length: 1))
            }
            #expect(measured.workBytes == 2 * size + 45)
            ratios.append(Double(measured.metadataBytes) / Double(size))
            print("TASK5_ADVERSARIAL_CODE N=\(size) payload=\(measured.workBytes) metadata=\(measured.metadataBytes) spans=\(measured.spans.count)")
        }
        #expect(try #require(ratios.max()) <= #require(ratios.min()) * 1.2)
    }

    @Test("Single-pass syntax lexer matches the frozen regex oracle on seeded adversarial inputs")
    func syntaxLegacyDifferential() async {
        let old = LegacyRegexSyntaxCache()
        let current = SyntaxHighlightCache()
        let atoms = ["let", "Thing", "éA", "A\u{301}", "中文", "😀", "²", "١", "42", "0xFF", "0b12", "1.2e+3", "1e+", "1.2a", " ", "\n", "\r", "\u{2028}", "\u{85}", "\t", "\"", "'", "`", "\\", "/", "*", "#", "_", ".", "+", "-"]
        var seed: UInt64 = 0xBADC0DE
        for index in 0 ..< 2000 {
            var source = ""
            for _ in 0 ..< 40 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                source += atoms[Int(seed >> 32) % atoms.count]
            }
            let language = ["swift", "python", "javascript", "json", "unknown", "bash", "typescript", "rust"][index % 8]
            let expected = await old.spans(for: source, language: language)
            let actual = await current.spans(for: source, language: language)
            #expect(actual == expected, "\(language): \(source.debugDescription)")
        }
    }

    @Test("Freeze legacy syntax token precedence and UTF-16 ranges before lexer replacement")
    func syntaxLegacyFreeze() async {
        let cache = SyntaxHighlightCache()
        for (index, fixture) in Self.syntaxFixtures.enumerated() {
            let (language, source) = fixture
            let spans = await cache.spans(for: source, language: language)
            let summary = spans.map { "\($0.kind.rawValue):\($0.range.location):\($0.range.length)" }.joined(separator: ",")
            #expect(summary == Self.syntaxGoldens[index], "\(language) \(source.debugDescription)")
        }
    }

    /// Frozen from pre-lexer implementation; artifact 65 records exact inputs/output.
    static let syntaxGoldens = [
        "4:19:4,4:26:5,4:34:7,1:0:3,5:11:5",
        "2:9:7,2:27:5,3:17:10,1:0:3",
        "2:0:13,3:13:15",
        "2:10:3,2:18:3,3:0:10,3:13:5,3:21:3,4:35:1,1:25:3,5:29:3",
        "2:0:31,4:40:1,1:32:3",
        "2:1:14,4:39:1,1:31:3",
        "2:0:6,2:14:13,2:7:6",
        "3:27:7,4:24:2,1:12:3,5:16:5",
        "2:26:8,2:10:16,2:34:1,3:37:7,1:0:5",
        "2:0:6,2:7:10,4:26:1,1:18:3",
        "2:16:6,3:14:2,3:22:3,4:38:4,1:0:3,1:31:6,5:4:5",
        "2:1:3,2:12:3,2:21:3,2:26:5,3:31:1,4:17:2,1:6:4",
        "4:39:3,4:43:1,1:0:5,1:12:2,1:20:4,5:6:5,5:15:4",
        "4:27:2,4:39:2,5:17:3",
        "2:0:6,2:6:12,3:18:2",
        "2:5:4,3:10:9,4:32:2,1:0:4",
    ]

    static let syntaxFixtures: [(String, String)] = [
        ("swift", "let value: Thing = 0xFF + 0b101 + 1.25e-2\n"),
        ("swift", "let 中文 = \"😀 e\u{301}\" // quoted \"yes\"\n"),
        ("swift", "\"http://host\"; let tail = 12\n"),
        ("swift", "/* before \"s\" and 'q' */ let End = 3"),
        ("swift", "\"\"\"multi\n\"inner\" /* x */\nend\"\"\"\nlet x = 0"),
        ("swift", "#\"raw \\\" quote\"#\n\"unterminated\nlet x = 1"),
        ("swift", "\"a\\\"b\" 'a\\\'b' \"backslash\\\\\""),
        ("swift", "/* unclosed let Thing = 12 // line\nnext"),
        ("javascript", "const x = `hello ${Thing}\n\"quoted\"`; // tail\n"),
        ("javascript", "`a\\`b` `bad\\\nend` let x = 3"),
        ("python", "def Thing(x): # 'text' 12\r\n    return 3.14\r"),
        ("json", "{\"k\": true, \"n\": 12, \"s\": \"//x\"}"),
        ("unknown", "class Thing if ELSE null 123abc 0x 1e+ 1.2.3"),
        ("swift", "éThing Aé Thing\u{301} A_1 中文2 😀42 x42 _42 ²42"),
        ("swift", "\"\"\"\"\"\"\" // /* */ \"x\""),
        ("bash", "echo \"$x\" # comment\nlet Thing = 12"),
    ]

    @Test("Closed code blocks satisfy the same safe-fixture definition", arguments: [10, 100, 1024])
    @MainActor func closedCodeSafeBudget(_ chunks: Int) async throws {
        let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 0)
        var buffer = IncrementalSourceBuffer()
        var previous: IncrementalParseResult?
        var model: RenderDisplayModel?
        var cumulative = ParseWorkMetrics()
        for index in 0 ..< chunks {
            let prefix = "```swift\n// \(index) "
            let chunk = prefix + String(repeating: "x", count: 1024 - prefix.utf8.count - 6) + "\n```\n\n"
            var metrics = ParseWorkMetrics()
            try buffer.append(chunk, metrics: &metrics)
            let parsed = try buffer.parse(previous: previous, metrics: metrics)
            metrics = parsed.metrics
            let input = RenderInput(
                document: parsed.document,
                source: nil,
                availableWidth: 320,
                configuration: configuration,
                placeholderMode: .streaming,
                previousModel: model,
                sourceBuffer: buffer
            )
            let preparer = RenderPreparer(configuration: configuration)
            if let old = model {
                let delta = try preparer.prepareDelta(input, replacing: parsed.replacedPreviousRange, with: parsed.changedBlockRange, metrics: &metrics)
                let prepared = try await delta.preparingSyntax(metrics: &metrics)
                model = prepared.applying(to: old, metrics: &metrics)
            } else {
                let bundles = try preparer.prepareBlocks(input, range: parsed.changedBlockRange, metrics: &metrics)
                model = try await RenderDisplayModel(bundles: RenderDisplayModel.prepareSyntax(bundles, metrics: &metrics), input: input)
            }
            #expect(parsed.state.safeUTF8Boundary == (index + 1) * 1024)
            #expect(index == 0 || parsed.fullParseReason == nil)
            cumulative.add(metrics)
            previous = parsed
        }
        let count = chunks * 1024
        print("TASK5_CLOSED_CODE N=\(count) scanner=\(cumulative.scannerBytes) mapping=\(cumulative.mappingBytes) materialization=\(cumulative.materializationBytes) cmark=\(cumulative.cmarkInputBytes) prepare=\(cumulative.renderPreparationBytes) metadata=\(cumulative.metadataBytes) total=\(cumulative.total)")
        #expect(cumulative.scannerBytes >= count && cumulative.scannerBytes <= 3 * count)
        #expect(cumulative.mappingBytes >= count && cumulative.mappingBytes <= 3 * count)
        #expect(cumulative.materializationBytes <= 4 * count)
        #expect(cumulative.cmarkInputBytes >= count && cumulative.cmarkInputBytes <= 4 * count)
        #expect(cumulative.renderPreparationBytes >= count && cumulative.renderPreparationBytes <= 4 * count)
        #expect(cumulative.total <= 16 * count)
    }

    @Test("Work-counter arithmetic saturates instead of trapping or wrapping")
    func counterOverflow() {
        #expect(ParseWorkMetrics.saturatingAdd(Int.max, 1) == Int.max)
        #expect(ParseWorkMetrics.saturatingMultiply(Int.max, 2) == Int.max)
        var metrics = ParseWorkMetrics()
        metrics.materializationBytes = Int.max
        metrics.scannerBytes = 1
        #expect(metrics.total == Int.max)
    }

    @Test("Concurrent document/model facade accounting is instance-scoped and drains atomically")
    @MainActor func scopedFacadeAccounting() async throws {
        let first = ParseWorkRecorder()
        let second = ParseWorkRecorder()
        let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 0)
        var a = IncrementalSourceBuffer(recorder: first)
        var b = IncrementalSourceBuffer(recorder: second)
        var metrics = ParseWorkMetrics()
        try a.append("# First\n\n", metrics: &metrics)
        try b.append("# Second\n\n", metrics: &metrics)
        let document = try a.parse(previous: nil).document
        let firstModel = try RenderPreparer(configuration: configuration).prepare(RenderInput(
            document: document,
            source: nil,
            availableWidth: 320,
            configuration: configuration,
            placeholderMode: .streaming
        ))
        let secondModel = try RenderPreparer(configuration: configuration).prepare(RenderInput(
            document: b.parse(previous: nil).document,
            source: nil,
            availableWidth: 320,
            configuration: configuration,
            placeholderMode: .streaming
        ))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for _ in 0 ..< 100 {
                _ = document.blocks; _ = firstModel.runs
            } }
            group.addTask { for _ in 0 ..< 100 {
                _ = secondModel.blocks
            } }
        }
        #expect(first.snapshot().facadeMaterializationCount == 200)
        #expect(second.snapshot().facadeMaterializationCount == 100)
        #expect(first.drain().metadataBytes > 0)
        #expect(first.drain().facadeMaterializationCount == 0)
        #expect(first.snapshot().facadeMaterializationCount == 200)
        #expect(second.drain().facadeMaterializationCount == 100)
    }

    @Test("An immutable ParseJob source facade is independent of task cancellation")
    func cancelledJobSourceIsStable() async throws {
        var buffer = IncrementalSourceBuffer()
        var metrics = ParseWorkMetrics()
        try buffer.append("# Stable\n\n", metrics: &metrics)
        try buffer.append("tail", metrics: &metrics)
        let submission = ParseSubmission(
            id: .init(),
            sessionToken: .init(),
            commitToken: RenderCommitToken(sessionID: .init(rawValue: .init()), sequence: 1, sourceRevision: 1, configurationGeneration: 1),
            attempt: 0
        )
        let job = ParseJob(submission: submission, buffer: buffer, previous: nil, metrics: metrics)
        let before = job.source
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return job.source
        }
        task.cancel()
        #expect(await task.value == before)
        #expect(before == "# Stable\n\ntail")
    }

    @Test("Production session emits combined metrics for 1 KiB appends through 1 MiB", arguments: ["plain", "math", "code"])
    @MainActor func productionSessionBudget(_ corpus: String) async throws {
        let registry = RenderSessionSinkRegistry()
        let sink = RecordingRenderSink()
        let diagnostics = WorkDiagnosticsRecorder()
        let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 0)
        let session = MarkdownRenderSession(
            registry: registry,
            configuration: configuration,
            diagnostics: { _, metrics in await diagnostics.record(metrics) }
        )
        registry.register(sink, for: session.id)
        let driver = MarkdownRenderSessionDriver(session: session)
        let math = corpus == "math"
        var fullSource = ""
        for index in 0 ..< 1024 {
            let prefix = "```swift\n// \(index) "
            let chunk = corpus == "code"
                ? prefix + String(repeating: "x", count: 1024 - prefix.utf8.count - 6) + "\n```\n\n"
                : "# " + String(repeating: "x", count: math ? 1016 : 1020) + (math ? " $x$" : "") + "\n\n"
            fullSource += chunk // Test-only oracle source, not the production session buffer.
            driver.send(.append(chunk))
            #expect(await eventually { sink.models.count == index + 1 })
        }
        let metrics = await diagnostics.total
        let attempts = await session.attemptDiagnostics
        #expect(attempts.acceptedCount == 1024)
        #expect(attempts.discardedCount == 0)
        #expect(attempts.accepted == metrics)
        #expect(attempts.totalAttempted == metrics)
        let count = 1_048_576
        #expect(await session.deltaPreparationCount == 1023)
        #expect(await session.facadeMaterializationCount == 0)
        #expect(metrics.facadeMaterializationCount == 0)
        #expect(metrics.syntaxPreparationBlocks == 1024)
        #expect(metrics.scannerBytes >= count && metrics.scannerBytes <= 3 * count)
        #expect(metrics.mappingBytes >= count && metrics.mappingBytes <= 3 * count)
        #expect(metrics.materializationBytes <= 4 * count)
        #expect(metrics.cmarkInputBytes <= 4 * count)
        #expect(metrics.metadataBytes > 0)
        #expect(metrics.renderPreparationBytes <= 4 * count)
        #expect(metrics.total <= 16 * count)
        let unpreparedFresh = try RenderPreparer(configuration: configuration).prepare(RenderInput(
            document: MarkdownDocument(parsing: fullSource), source: fullSource, availableWidth: 320,
            configuration: configuration, placeholderMode: .streaming
        ))
        let fresh = await unpreparedFresh.preparingSyntax()
        let final = try #require(sink.models.last)
        #expect(final.bundles.elementsEqual(fresh.bundles))
        #expect(final.preparedDocument?.blockStorage == fresh.preparedDocument?.blockStorage)
        #expect(await session.facadeMaterializationCount == 0)
        print("TASK5_PRODUCTION corpus=\(corpus) N=\(count) scanner=\(metrics.scannerBytes) mapping=\(metrics.mappingBytes) materialization=\(metrics.materializationBytes) cmark=\(metrics.cmarkInputBytes) prepare=\(metrics.renderPreparationBytes) metadata=\(metrics.metadataBytes) total=\(metrics.total)")
        driver.send(.dismantle)
    }

    @Test("Syntax cache measures misses, hits, and rejects cancelled preparation")
    func syntaxCacheAccounting() async throws {
        let cache = SyntaxHighlightCache()
        let code = "let 中文 = \"value\" // note\n"
        let miss = try await cache.measuredSpans(for: code, language: "SWIFT")
        let hit = try await cache.measuredSpans(for: code, language: "swift")
        #expect(miss.spans == hit.spans)
        #expect(!miss.cacheHit)
        #expect(hit.cacheHit)
        #expect(hit.workBytes >= code.utf8.count)
        #expect(miss.workBytes == 2 * code.utf8.count + 9 * 5)
        #expect(hit.workBytes == 2 * code.utf8.count + 4 * 5)
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await cache.measuredSpans(for: "cancelled", language: nil)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await !cache.measuredSpans(for: "cancelled", language: nil).cacheHit)
    }

    @Test("Scanner and substitution report work on the production overloads")
    func mathWorkAccounting() throws {
        let source = "before $x^2$ after\n"
        var metrics = ParseWorkMetrics()
        let spans = try MathScanner.scan(source, metrics: &metrics)
        #expect(spans.count == 1)
        let substitution = try MathSentinel.substitute(source: source, spans: spans, metrics: &metrics)
        #expect(substitution.table.first?.latex == "x^2")
        #expect(metrics.scannerBytes >= source.utf8.count)
        #expect(metrics.materializationBytes >= source.utf8.count)
        #expect(metrics.metadataBytes > 0) // Segment records contain offsets, not copied source bytes.
    }

    @Test("Cancelled scanner and substitution stop before producing a result")
    func cancelledMathWork() async {
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            var metrics = ParseWorkMetrics()
            return try MathScanner.scan("$x$", metrics: &metrics)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Safe 1 KiB chunks account for every phase and meet deterministic budgets", arguments: [10, 100, 1024], [false, true])
    @MainActor func safeBudgets(_ chunks: Int, _ math: Bool) throws {
        let chunk = "# " + String(repeating: "x", count: math ? 1016 : 1020) + (math ? " $x$" : "") + "\n\n"
        let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 0)
        let preparer = RenderPreparer(configuration: configuration)
        var buffer = IncrementalSourceBuffer()
        var previous: IncrementalParseResult?
        var model: RenderDisplayModel?
        var cumulative = ParseWorkMetrics()
        for _ in 0 ..< chunks {
            var metrics = ParseWorkMetrics()
            try buffer.append(chunk, metrics: &metrics)
            let result = try buffer.parse(previous: previous, metrics: metrics)
            metrics = result.metrics
            let input = RenderInput(
                document: result.document,
                source: nil,
                availableWidth: 320,
                configuration: configuration,
                placeholderMode: .streaming,
                previousModel: model,
                sourceBuffer: buffer
            )
            if let previousModel = model {
                let delta = try preparer.prepareDelta(
                    input,
                    replacing: result.replacedPreviousRange,
                    with: result.changedBlockRange,
                    metrics: &metrics
                )
                model = delta.applying(to: previousModel, metrics: &metrics)
            } else {
                model = try RenderDisplayModel(bundles: preparer.prepareBlocks(
                    input,
                    range: result.changedBlockRange,
                    metrics: &metrics
                ), input: input)
            }
            cumulative.add(metrics)
            previous = result
        }
        let count = chunks * 1024
        #expect(cumulative.scannerBytes >= count)
        #expect(cumulative.mappingBytes >= count)
        #expect(cumulative.scannerBytes <= 3 * count)
        #expect(cumulative.mappingBytes <= 3 * count)
        #expect(cumulative.materializationBytes <= 4 * count)
        #expect(cumulative.cmarkInputBytes <= 4 * count)
        #expect(cumulative.renderPreparationBytes <= 4 * count)
        #expect(cumulative.total <= 16 * count)
        #expect(model?.bundles.count == chunks)
        print("TASK5_BUDGET N=\(count) scanner=\(cumulative.scannerBytes) mapping=\(cumulative.mappingBytes) materialization=\(cumulative.materializationBytes) cmark=\(cumulative.cmarkInputBytes) prepare=\(cumulative.renderPreparationBytes) metadata=\(cumulative.metadataBytes) total=\(cumulative.total)")
    }

    @Test @MainActor func productionSessionUsesDeltaForAppend() async throws {
        let registry = RenderSessionSinkRegistry()
        let sink = RecordingRenderSink()
        let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 0)
        let session = MarkdownRenderSession(registry: registry, configuration: configuration)
        registry.register(sink, for: session.id)
        let driver = MarkdownRenderSessionDriver(session: session)
        driver.send(.append("# Stable\n\n"))
        #expect(await eventually { sink.models.count == 1 })
        driver.send(.append("# Next\n\n"))
        #expect(await eventually { sink.models.count == 2 })
        #expect(await session.deltaPreparationCount == 1)
        let metrics = await session.lastWorkMetrics
        #expect(metrics?.cmarkInputBytes == 8)
        #expect((metrics?.metadataBytes ?? 0) > 0)
        #expect((metrics?.renderPreparationBytes ?? Int.max) < 4096)
        #expect(metrics?.syntaxPreparationBlocks == 1)
        let fullInput = RenderInput(
            document: MarkdownDocument(parsing: "# Stable\n\n# Next\n\n"),
            source: "# Stable\n\n# Next\n\n",
            availableWidth: 320,
            configuration: configuration,
            placeholderMode: .streaming
        )
        let full = try RenderPreparer(configuration: configuration).prepare(fullInput)
        #expect(sink.models.last == full)
        driver.send(.dismantle)
    }

    @Test("Persistent block splices preserve both ends without flattening them")
    func persistentSplice() {
        var values = PersistentValues<Int>()
        var metrics = ParseWorkMetrics()
        for index in 0 ..< 1024 {
            values = values.appending(PersistentValues([index]), metrics: &metrics)
        }
        let snapshot = values
        metrics = ParseWorkMetrics()
        values = values.slice(0 ..< 1000, metrics: &metrics)
            .appending(PersistentValues([8000, 8001]), metrics: &metrics)
            .appending(snapshot.slice(1002 ..< 1024, metrics: &metrics), metrics: &metrics)
        #expect(Array(values) == Array(0 ..< 1000) + [8000, 8001] + Array(1002 ..< 1024))
        #expect(Array(snapshot) == Array(0 ..< 1024))
        #expect(values[1001] == 8001)
        #expect(metrics.materializationBytes < 4000)
        #expect(values.depth < 20)
    }

    @Test("A partial UTF-8 scalar is buffered without replacement characters")
    func partialScalar() throws {
        var buffer = IncrementalSourceBuffer()
        var metrics = ParseWorkMetrics()
        for byte in [UInt8(0xF0), 0x9F, 0x98] {
            try buffer.append(bytes: [byte], metrics: &metrics)
            #expect(buffer.utf8Count == 0)
        }
        try buffer.append(bytes: [0x80, 0x0A], metrics: &metrics)
        #expect(buffer.utf8Count == 5)
        #expect(try buffer.materialize(from: 0, metrics: &metrics) == "😀\n")
    }

    @Test("Invalid UTF-8 rejects the append atomically")
    func invalidScalar() throws {
        var buffer = IncrementalSourceBuffer()
        var metrics = ParseWorkMetrics()
        try buffer.append("valid\n", metrics: &metrics)
        #expect(throws: IncrementalSourceBuffer.BufferError.invalidUTF8) {
            try buffer.append(bytes: [0xFF], metrics: &metrics)
        }
        #expect(try buffer.materialize(from: 0, metrics: &metrics) == "valid\n")
    }

    @Test("Tail materialization never copies the preserved prefix")
    func tailOnlyCopy() throws {
        var buffer = IncrementalSourceBuffer()
        var metrics = ParseWorkMetrics()
        try buffer.append(String(repeating: "x", count: 100_000) + "\n\n", metrics: &metrics)
        let prefixCount = buffer.utf8Count
        try buffer.append("tail\n", metrics: &metrics)
        metrics = ParseWorkMetrics()
        #expect(try buffer.materialize(from: prefixCount, metrics: &metrics) == "tail\n")
        #expect(metrics.materializationBytes - metrics.metadataBytes <= 5)
        #expect(metrics.metadataBytes <= 24)
    }

    @Test("Snapshots retain immutable prefixes while later buffers append")
    func snapshotIsolation() throws {
        var buffer = IncrementalSourceBuffer()
        var metrics = ParseWorkMetrics()
        try buffer.append("first\n", metrics: &metrics)
        let snapshot = buffer
        try buffer.append("second\n", metrics: &metrics)
        #expect(try snapshot.materialize(from: 0, metrics: &metrics) == "first\n")
        #expect(try buffer.materialize(from: 0, metrics: &metrics) == "first\nsecond\n")
    }
}

private actor WorkDiagnosticsRecorder {
    private(set) var total = ParseWorkMetrics()
    func record(_ metrics: ParseWorkMetrics) {
        self.total.add(metrics)
    }
}

/// Cancel on the worker's own checkpoint, independently of scheduling/metrics.
private final class SelfCancellingCheckpoint: Sendable {
    private let calls = Mutex(0)
    private let target: Int
    init(at target: Int) {
        self.target = target
    }

    func check() throws {
        let cancel = self.calls.withLock { $0 += 1; return $0 == self.target }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        try Task.checkCancellation()
    }
}

/// Pause the admitted synchronous cmark adapter after its real input has been
/// parsed, before cancellation/source-mapping/publication resumes. No fake parser.
private final class AttemptCmarkGate: Sendable {
    private let condition = NSCondition()
    private let state = Mutex((jobs: [ParseJob](), released: Set<UUID>()))
    var jobs: [ParseJob] {
        self.state.withLock { $0.jobs }
    }

    func hold(_ job: ParseJob) {
        self.condition.lock()
        self.state.withLock { $0.jobs.append(job) }
        while !self.state.withLock({ $0.released.contains(job.submission.id) }) {
            self.condition.wait()
        }
        self.condition.unlock()
    }

    func release(index: Int) {
        self.condition.lock()
        _ = self.state.withLock { $0.released.insert($0.jobs[index].submission.id) }
        self.condition.broadcast()
        self.condition.unlock()
    }
}
