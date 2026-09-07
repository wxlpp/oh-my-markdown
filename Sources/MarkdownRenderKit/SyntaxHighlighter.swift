import Foundation
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
    private var cache: [SyntaxHighlightKey: [SyntaxHighlightSpan]] = [:]
    private var order: [SyntaxHighlightKey] = []
    private var keywordCache: [String: NSRegularExpression] = [:]
    private let noTypeNameLangs: Set<String> = ["json", "bash", "sh", "shell", "css", "toml", "yaml", "yml", "mermaid"]
    public init() {}

    public func spans(for code: String, language: String?) -> [SyntaxHighlightSpan] {
        let cacheKey = SyntaxHighlightKey(code: code, language: language)
        if let cached = self.cache[cacheKey] {
            self.order.removeAll { $0 == cacheKey }
            self.order.append(cacheKey)
            return cached
        }
        let lang = language?.lowercased() ?? ""
        let nsLen = (code as NSString).length
        let fullRange = NSRange(location: 0, length: nsLen)
        // Flat bitmap — O(1) read/write, no heap allocation per mark.
        // Value = Kind.rawValue of the winning token (0 = unpainted).
        var painted = [UInt8](repeating: 0, count: nsLen)
        var spans: [SyntaxHighlightSpan] = []

        /// Mark a range with a token colour, painting only positions not yet claimed by a
        /// higher-priority token. Partially-overlapping matches (e.g. a comment that
        /// contains a string literal) are split into contiguous unpainted sub-ranges so
        /// both tokens contribute their colour where they are the first claimant.
        @inline(__always)
        func paint(_ range: NSRange, _ kind: Kind) {
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
                if i < hi, painted[i] == 0 {
                    if subStart == nil {
                        subStart = i
                    }
                } else if let s = subStart {
                    let sub = NSRange(location: s, length: i - s)
                    for j in s ..< i {
                        painted[j] = kind.rawValue
                    }
                    spans.append(SyntaxHighlightSpan(range: sub, kind: kind))
                    subStart = nil
                }
            }
        }

        @inline(__always)
        func apply(_ rx: NSRegularExpression, _ kind: Kind) {
            rx.enumerateMatches(in: code, range: fullRange) { m, _, _ in
                guard let m else {
                    return
                }
                paint(m.range, kind)
            }
        }

        // ── Priority order ──────────────────────────────────────────────────
        // Strings come before comments so that comment delimiters *inside* a
        // string literal (e.g. "http://…", "/* not a comment */") do not win.
        // 1. Swift / Python triple-quoted strings
        apply(self.tripleDoubleStringRx, .string)

        // 2. Ordinary string literals
        apply(self.doubleStringRx, .string)
        apply(self.singleStringRx, .string)
        if
            lang == "javascript" || lang == "js" ||
            lang == "typescript" || lang == "ts" || lang == "jsx" || lang == "tsx" {
            apply(self.templateStringRx, .string)
        }

        // 3. Block comments  /* ... */
        apply(self.blockCommentRx, .comment)

        // 4. Single-line comments  // ... or # ...
        apply(self.lineCommentRxFor(lang), .comment)

        // 5. Numeric literals
        apply(self.numberRx, .number)

        // 6. Language keywords
        if let kwRx = keywordRx(for: lang) {
            apply(kwRx, .keyword)
        }

        // 7. PascalCase type names — skip for languages that don't have OOP types
        if !self.noTypeNameLangs.contains(lang) {
            apply(self.typeNameRx, .type)
        }
        // ────────────────────────────────────────────────────────────────────

        self.cache[cacheKey] = spans
        self.order.append(cacheKey)
        if self.order.count > 300 { self.cache[self.order.removeFirst()] = nil }
        return spans
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
