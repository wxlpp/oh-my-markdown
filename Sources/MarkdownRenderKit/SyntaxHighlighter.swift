import Foundation
import MarkdownCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Semantic token categories independent of platform fonts and colors.
public enum SyntaxHighlightKind: UInt8, Sendable {
    case keyword = 1, string, comment, number, type
}

/// Immutable UTF-16 range and token category for one exact source string.
public struct SyntaxHighlightSpan: Sendable, Equatable {
    public let range: NSRange
    public let kind: SyntaxHighlightKind
    public init(range: NSRange, kind: SyntaxHighlightKind) {
        self.range = range
        self.kind = kind
    }
}

/// Exact code and case-normalized language used to look up immutable spans.
public struct SyntaxHighlightKey: Sendable, Hashable {
    public let code: String
    public let language: String?
    public init(code: String, language: String?) {
        self.code = code
        self.language = language?.lowercased()
    }
}

/// Regex compilation, segmentation and bounded dictionaries never leave this actor.
public actor SyntaxHighlightCache {
    public static let shared = SyntaxHighlightCache()
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
    private var keywordCache: [String: KeywordTrie] = [:]
    private let noTypeNameLangs: Set<String> = ["json", "bash", "sh", "shell", "css", "toml", "yaml", "yml", "mermaid"]
    public init() {}

    public func spans(for code: String, language: String?) -> [SyntaxHighlightSpan] {
        // The source-compatible nonthrowing API shares the exact algorithm.
        try! self.prepare(code, language: language, cancellable: false).spans
    }

    package struct MeasuredSpans {
        package let spans: [SyntaxHighlightSpan]
        package let workBytes: Int
        package let metadataBytes: Int
        package let cacheHit: Bool
    }

    package func measuredSpans(for code: String, language: String?, recorder: ParseAttemptRecorder? = nil, checkCancellation: @escaping ParseCancellationCheck = { try Task.checkCancellation() }) throws -> MeasuredSpans {
        try self.prepare(code, language: language, cancellable: true, recorder: recorder, checkCancellation: checkCancellation)
    }

    private func prepare(_ code: String, language: String?, cancellable: Bool, recorder: ParseAttemptRecorder? = nil, checkCancellation: @escaping ParseCancellationCheck = { try Task.checkCancellation() }) throws -> MeasuredSpans {
        let work = SyntaxWork(cancellable: cancellable, recorder: recorder, checkCancellation: checkCancellation)
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
                    try work.metadata(self.order.count * MemoryLayout<(UInt64, UInt64)>.stride)
                    try work.check()
                    self.order.removeAll { $0.id == entry.id }
                    self.order.append((hash, entry.id))
                    return MeasuredSpans(spans: entry.spans, workBytes: work.bytes, metadataBytes: work.metadataBytes, cacheHit: true)
                }
            }
        }
        let spans = try self.lex(code, language: lang, work: work)

        let bucketSize = self.cache[hash]?.count ?? 0
        try work.metadata((bucketSize + 1) * MemoryLayout<Entry>.stride)
        try work.metadata(MemoryLayout<(UInt64, UInt64)>.stride)
        if self.order.count == 300 {
            try work.metadata(self.order.count * MemoryLayout<(UInt64, UInt64)>.stride)
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
        return MeasuredSpans(spans: spans, workBytes: work.bytes, metadataBytes: work.metadataBytes, cacheHit: false)
    }

    private final class SyntaxWork {
        var bytes = 0
        var metadataBytes = 0
        var sinceCheck = 0
        let cancellable: Bool
        let recorder: ParseAttemptRecorder?
        let checkCancellation: ParseCancellationCheck
        init(cancellable: Bool, recorder: ParseAttemptRecorder?, checkCancellation: @escaping ParseCancellationCheck) {
            self.cancellable = cancellable
            self.recorder = recorder
            self.checkCancellation = checkCancellation
        }

        func check() throws {
            if self.cancellable { try self.checkCancellation() }
        }

        func add(_ count: Int) throws {
            self.bytes = ParseWorkMetrics.saturatingAdd(self.bytes, count)
            self.recorder?.record(.preparation, bytes: count)
            try self.checkpoint(count)
        }

        func metadata(_ count: Int) throws {
            self.metadataBytes = ParseWorkMetrics.saturatingAdd(self.metadataBytes, count)
            self.recorder?.record(.metadata, bytes: count)
            try self.checkpoint(count)
        }

        private func checkpoint(_ count: Int) throws {
            if count >= 1024 || self.sinceCheck >= 1024 - count {
                self.sinceCheck = 0
                try self.check()
            } else { self.sinceCheck += count }
        }
    }

    private struct KeywordTrie {
        struct Node { var edges: [UInt32: Int] = [:]; var terminal = false }
        let nodes: [Node]
        init(_ words: [String]) {
            var nodes = [Node()]
            for word in words {
                var index = 0
                for scalar in word.unicodeScalars {
                    if let next = nodes[index].edges[scalar.value] { index = next }
                    else {
                        let next = nodes.count
                        nodes[index].edges[scalar.value] = next
                        nodes.append(Node())
                        index = next
                    }
                }
                nodes[index].terminal = true
            }
            self.nodes = nodes
        }
    }

    private struct QuotedState {
        let quote: UInt32
        let multiline: Bool
        var start: Int?
        var escaped = false
        mutating func feed(_ scalar: UInt32, at offset: Int, end: Int) -> Range<Int>? {
            guard let start else {
                if scalar == self.quote { self.start = offset; self.escaped = false }
                return nil
            }
            if !self.multiline, scalar == 10 || scalar == 13 {
                self.start = nil; self.escaped = false; return nil
            }
            if self.escaped {
                if !self.multiline, scalar == 0x85 || scalar == 0x2028 || scalar == 0x2029 {
                    self.start = nil
                }
                self.escaped = false; return nil
            }
            if scalar == 92 { self.escaped = true; return nil }
            if scalar == self.quote { self.start = nil; return start ..< end }
            return nil
        }
    }

    private struct NumberState {
        enum Phase { case zero, integer, hexLead, hex, binaryLead, binary, fractionLead, fraction, exponentLead, exponentSign, exponent }
        var start: Int?
        var phase = Phase.integer
        var acceptedEnd = 0
        var boundaryEnd: Int?
        mutating func feed(_ value: UInt32, digit: Bool, word: Bool, previousWord: Bool, at offset: Int, end: Int) -> Range<Int>? {
            var result: Range<Int>?
            if let start {
                if self.acceptedEnd == offset, !word { self.boundaryEnd = offset }
                var consumed = false
                var accepted = false
                switch self.phase {
                case .zero:
                    if value == 120 { self.phase = .hexLead; consumed = true }
                    else if value == 98 { self.phase = .binaryLead; consumed = true }
                    else { (consumed, accepted) = self.decimal(value, digit: digit, fractionAllowed: true) }
                case .integer: (consumed, accepted) = self.decimal(value, digit: digit, fractionAllowed: true)
                case .fraction: (consumed, accepted) = self.decimal(value, digit: digit, fractionAllowed: false)
                case .hexLead, .hex:
                    if digit || (65 ... 70).contains(value) || (97 ... 102).contains(value) {
                        self.phase = .hex; consumed = true; accepted = true
                    }
                case .binaryLead, .binary:
                    if value == 48 || value == 49 { self.phase = .binary; consumed = true; accepted = true }
                case .fractionLead:
                    if digit { self.phase = .fraction; consumed = true; accepted = true }
                case .exponentLead:
                    if value == 43 || value == 45 { self.phase = .exponentSign; consumed = true }
                    else if digit { self.phase = .exponent; consumed = true; accepted = true }
                case .exponentSign, .exponent:
                    if digit { self.phase = .exponent; consumed = true; accepted = true }
                }
                if consumed {
                    if accepted { self.acceptedEnd = end }
                    return nil
                }
                if let boundaryEnd = self.boundaryEnd { result = start ..< boundaryEnd }
                self.start = nil
            }
            if digit, !previousWord {
                self.start = offset; self.phase = value == 48 ? .zero : .integer
                self.acceptedEnd = end; self.boundaryEnd = nil
            }
            return result
        }

        private mutating func decimal(_ value: UInt32, digit: Bool, fractionAllowed: Bool) -> (Bool, Bool) {
            if digit { if self.phase == .zero { self.phase = .integer }; return (true, true) }
            if fractionAllowed, value == 46 { self.phase = .fractionLead; return (true, false) }
            if value == 101 || value == 69 { self.phase = .exponentLead; return (true, false) }
            return (false, false)
        }
    }

    /// Independent lexical recognizers consume each scalar once. Keeping the
    /// recognizers independent preserves the legacy global token precedence,
    /// including strings nested inside comment matches. Range-only merging then
    /// resolves precedence without rereading the source or allocating a bitmap.
    private func lex(_ code: String, language: String, work: SyntaxWork) throws -> [SyntaxHighlightSpan] {
        try work.add(language.utf8.count) // keyword-language dictionary hash
        let normalized = self.keywords[language] == nil ? "_default" : language
        let trie: KeywordTrie
        try work.add(normalized.utf8.count) // trie-cache dictionary hash
        if let cached = self.keywordCache[normalized] { trie = cached }
        else {
            try work.add(2 * normalized.utf8.count) // keyword lookup and cache insertion hashes
            trie = KeywordTrie(self.keywords[normalized]!)
            self.keywordCache[normalized] = trie
            try work.metadata(trie.nodes.count * MemoryLayout<KeywordTrie.Node>.stride)
        }
        func matches(_ candidates: [String]) throws -> Bool {
            for candidate in candidates where candidate.utf8.count == language.utf8.count {
                try work.add(language.utf8.count)
                if candidate == language { return true }
            }
            return false
        }
        let templates = try matches(["javascript", "js", "typescript", "ts", "jsx", "tsx"])
        let hashComments = try matches(["bash", "perl", "python", "r", "ruby", "sh", "shell", "toml", "yaml", "yml"])
        try work.add(language.utf8.count) // excluded-type language set hash
        let types = !self.noTypeNameLangs.contains(language)
        var matches = Array(repeating: [Range<Int>](), count: 9)
        func append(_ range: Range<Int>?, rank: Int) throws {
            guard let range, !range.isEmpty else { return }
            if matches[rank].count == matches[rank].capacity {
                try work.metadata(matches[rank].count * MemoryLayout<Range<Int>>.stride)
            }
            matches[rank].append(range)
            try work.metadata(MemoryLayout<Range<Int>>.stride)
        }
        var double = QuotedState(quote: 34, multiline: false)
        var single = QuotedState(quote: 39, multiline: false)
        var template = QuotedState(quote: 96, multiline: true)
        var tripleStart: Int?
        var quoteRun = 0
        var blockStart: Int?
        var blockConsumedEnd = 0
        var lineStart: Int?
        var previous: UInt32 = 0
        var previousOffset = 0
        var previousWord = false
        var wordStart: Int?
        var wordTrie: Int? = 0
        var typeCandidate = false
        // Regex backtracking can restart after a decimal point or exponent sign.
        // Keep those bounded alternative starts until the earlier candidate wins.
        var numbers: [NumberState] = []
        var numberConsumedEnd = 0
        func feedNumbers(_ value: UInt32, digit: Bool, word: Bool, previousWord: Bool, at offset: Int, end: Int) throws {
            var retained: [NumberState] = []
            for var number in numbers {
                guard (number.start ?? 0) >= numberConsumedEnd else { continue }
                if let range = number.feed(value, digit: digit, word: word, previousWord: true, at: offset, end: end) {
                    try append(range, rank: 6)
                    numberConsumedEnd = range.upperBound
                }
                if number.start != nil { retained.append(number) }
                try work.metadata(MemoryLayout<NumberState>.stride)
            }
            if digit, !previousWord, offset >= numberConsumedEnd {
                var number = NumberState()
                _ = number.feed(value, digit: true, word: word, previousWord: false, at: offset, end: end)
                retained.append(number)
                try work.metadata(MemoryLayout<NumberState>.stride)
            }
            numbers = retained
        }
        var offset = 0
        func finishWord(at end: Int) throws {
            guard let start = wordStart else { return }
            if let index = wordTrie, trie.nodes[index].terminal { try append(start ..< end, rank: 7) }
            if typeCandidate, types { try append(start ..< end, rank: 8) }
            wordStart = nil
        }
        for scalar in code.unicodeScalars {
            let value = scalar.value
            let byteCount = value < 0x80 ? 1 : value < 0x800 ? 2 : value < 0x10000 ? 3 : 4
            try work.add(byteCount)
            let end = offset + (value > 0xFFFF ? 2 : 1)
            let digit = scalar.properties.generalCategory == .decimalNumber
            let word: Bool = switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .connectorPunctuation: true
            default: scalar.properties.isAlphabetic || value == 0x200C || value == 0x200D
            }
            if value == 34 {
                quoteRun += 1
                if quoteRun == 3 {
                    if let start = tripleStart { try append(start ..< end, rank: 0); tripleStart = nil }
                    else { tripleStart = offset - 2 }
                    quoteRun = 0
                }
            } else { quoteRun = 0 }
            try append(double.feed(value, at: offset, end: end), rank: 1)
            try append(single.feed(value, at: offset, end: end), rank: 2)
            if templates { try append(template.feed(value, at: offset, end: end), rank: 3) }
            if let start = blockStart {
                if previous == 42, value == 47, offset >= start + 3 {
                    try append(start ..< end, rank: 4); blockStart = nil; blockConsumedEnd = end
                }
            } else if previous == 47, value == 42, previousOffset >= blockConsumedEnd { blockStart = previousOffset }
            if let start = lineStart {
                if value == 10 || value == 13 { try append(start ..< offset, rank: 5); lineStart = nil }
            } else if hashComments ? value == 35 : previous == 47 && value == 47 {
                lineStart = hashComments ? offset : previousOffset
            }
            try feedNumbers(value, digit: digit, word: word, previousWord: previousWord, at: offset, end: end)
            if word {
                if wordStart == nil {
                    wordStart = offset; wordTrie = 0; typeCandidate = (65 ... 90).contains(value)
                }
                if let index = wordTrie { wordTrie = trie.nodes[index].edges[value]; try work.metadata(MemoryLayout<Int>.stride) }
                typeCandidate = typeCandidate && ((65 ... 90).contains(value) || (97 ... 122).contains(value) || (48 ... 57).contains(value) || value == 95)
            } else { try finishWord(at: offset) }
            previous = value; previousOffset = offset; previousWord = word; offset = end
        }
        try finishWord(at: offset)
        try feedNumbers(0, digit: false, word: false, previousWord: previousWord, at: offset, end: offset)
        if let start = lineStart { try append(start ..< offset, rank: 5) }
        let kinds: [Kind] = [.string, .string, .string, .string, .comment, .comment, .number, .keyword, .type]
        var covered: [Range<Int>] = []
        var spans: [SyntaxHighlightSpan] = []
        for rank in matches.indices {
            let ranges = matches[rank]
            guard !ranges.isEmpty else { continue }
            var maskIndex = 0
            func emit(_ lower: Int, _ upper: Int) throws {
                guard lower < upper else { return }
                if spans.count == spans.capacity { try work.metadata(spans.count * MemoryLayout<SyntaxHighlightSpan>.stride) }
                spans.append(SyntaxHighlightSpan(range: NSRange(location: lower, length: upper - lower), kind: kinds[rank]))
                try work.metadata(MemoryLayout<SyntaxHighlightSpan>.stride)
            }
            for range in ranges {
                var cursor = range.lowerBound
                while maskIndex < covered.count, covered[maskIndex].upperBound <= cursor {
                    try work.metadata(MemoryLayout<Range<Int>>.stride); maskIndex += 1
                }
                var index = maskIndex
                while index < covered.count, covered[index].lowerBound < range.upperBound {
                    try work.metadata(MemoryLayout<Range<Int>>.stride)
                    let mask = covered[index]
                    try emit(cursor, min(mask.lowerBound, range.upperBound))
                    cursor = max(cursor, mask.upperBound)
                    if cursor >= range.upperBound { break }
                    index += 1
                }
                try emit(cursor, range.upperBound)
            }
            var merged: [Range<Int>] = []
            merged.reserveCapacity(covered.count + ranges.count)
            var left = 0, right = 0
            while left < covered.count || right < ranges.count {
                let next: Range<Int>
                if right == ranges.count || (left < covered.count && covered[left].lowerBound <= ranges[right].lowerBound) {
                    next = covered[left]; left += 1
                } else { next = ranges[right]; right += 1 }
                if let last = merged.last, last.upperBound >= next.lowerBound { merged[merged.count - 1] = last.lowerBound ..< max(last.upperBound, next.upperBound) }
                else { merged.append(next) }
                try work.metadata(MemoryLayout<Range<Int>>.stride)
            }
            covered = merged
        }
        return spans
    }

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
}

/// Applies already prepared spans. Platform fonts and adaptive colors stay on MainActor.
@MainActor
public enum SyntaxHighlighter {
    public static func highlight(_ code: String, spans: [SyntaxHighlightSpan], font: PlatformFont, defaultColor: PlatformColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: code, attributes: [.font: font, .foregroundColor: defaultColor])
        for span in spans where span.range.location >= 0 && NSMaxRange(span.range) <= result.length {
            result.addAttribute(.foregroundColor, value: self.color(for: span.kind), range: span.range)
        }
        return result
    }

    #if canImport(UIKit)
    /// Xcode-inspired palette
    private static let colorKeyword = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.81, green: 0.56, blue: 0.96, alpha: 1) // #CF8EF4
            : UIColor(red: 0.61, green: 0.14, blue: 0.58, alpha: 1) // #9B2393
    }

    private static let colorString = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.99, green: 0.42, blue: 0.36, alpha: 1) // #FC6A5D
            : UIColor(red: 0.77, green: 0.10, blue: 0.09, alpha: 1) // #C41A16
    }

    private static let colorComment = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.42, green: 0.54, blue: 0.38, alpha: 1)
            : UIColor(red: 0.25, green: 0.43, blue: 0.20, alpha: 1)
    }

    private static let colorNumber = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.82, green: 0.75, blue: 0.41, alpha: 1) // #D0BF69
            : UIColor(red: 0.11, green: 0.11, blue: 0.73, alpha: 1)
    }

    private static let colorType = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.36, green: 0.85, blue: 1.00, alpha: 1) // #5DD8FF
            : UIColor(red: 0.22, green: 0.00, blue: 0.63, alpha: 1)
    }

    #elseif canImport(AppKit)
    private static let colorKeyword = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.81, green: 0.56, blue: 0.96, alpha: 1)
            : NSColor(calibratedRed: 0.61, green: 0.14, blue: 0.58, alpha: 1)
    }

    private static let colorString = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.99, green: 0.42, blue: 0.36, alpha: 1)
            : NSColor(calibratedRed: 0.77, green: 0.10, blue: 0.09, alpha: 1)
    }

    private static let colorComment = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.42, green: 0.54, blue: 0.38, alpha: 1)
            : NSColor(calibratedRed: 0.25, green: 0.43, blue: 0.20, alpha: 1)
    }

    private static let colorNumber = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.82, green: 0.75, blue: 0.41, alpha: 1)
            : NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.73, alpha: 1)
    }

    private static let colorType = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.36, green: 0.85, blue: 1.00, alpha: 1)
            : NSColor(calibratedRed: 0.22, green: 0.00, blue: 0.63, alpha: 1)
    }
    #endif

    private static func color(for kind: SyntaxHighlightKind) -> PlatformColor {
        switch kind {
        case .keyword: self.colorKeyword
        case .string: self.colorString
        case .comment: self.colorComment
        case .number: self.colorNumber
        case .type: self.colorType
        }
    }
}
