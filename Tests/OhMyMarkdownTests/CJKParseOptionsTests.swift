@testable import MarkdownCore
import Testing

@Suite("CJK parse options")
struct CJKParseOptionsTests {
    @Test func explicitModeAndAppendKeepSource() {
        let source = "中**“文”**后"
        let strict = MarkdownDocument(parsing: source)
        let relaxed = MarkdownDocument(parsing: source, options: .cjkFriendlyEmphasis)
        #expect(strict.blocks != relaxed.blocks)
        #expect(relaxed.blocks == [.paragraph([.text("中"), .strong([.text("“文”")]), .text("后")])])
        #expect(relaxed.parsedBlocks.first?.sourceRange?.upperBound == source.utf8.count)
        #expect(relaxed.parsingAppend(to: source + "续", previousSource: source).parseOptions == .cjkFriendlyEmphasis)
        #expect(MarkdownDocument(parsing: "same") != MarkdownDocument(parsing: "same", options: .cjkFriendlyEmphasis))
    }

    @Test func configurationChangeRejectsPreviousIncrementalState() throws {
        var buffer = IncrementalSourceBuffer()
        var metrics = ParseWorkMetrics()
        let source = "中**“文”**后\n\n尾部\n"
        try buffer.append(source, metrics: &metrics)
        let strict = try buffer.parse(previous: nil)
        let relaxed = try buffer.parse(options: .cjkFriendlyEmphasis, previous: strict)
        #expect(relaxed.fullParseReason == .configurationChanged)
        #expect(relaxed.invalidationStartByte == 0)
        #expect(relaxed.document == MarkdownDocument(parsing: source, options: .cjkFriendlyEmphasis))
        let again = try buffer.parse(previous: relaxed)
        #expect(again.fullParseReason == .configurationChanged)
        #expect(again.document == strict.document)
    }

    @Test(arguments: ["中**“文”**后", "中**“文”**后 $x$", "中**[链接](https://example.com)**后\n\n尾部\n"])
    func scalarSplitsMatchFullParse(source: String) throws {
        var buffer = IncrementalSourceBuffer()
        var metrics = ParseWorkMetrics()
        var previous: IncrementalParseResult?
        var prefix = ""
        for scalar in source.unicodeScalars {
            let piece = String(scalar)
            prefix += piece
            try buffer.append(piece, metrics: &metrics)
            previous = try buffer.parse(options: .cjkFriendlyEmphasis, previous: previous)
            let expected = MarkdownDocument(parsing: prefix, options: .cjkFriendlyEmphasis)
            #expect(previous?.document == expected)
            #expect(previous?.document.parsedBlocks.map(\.sourceRange) == expected.parsedBlocks.map(\.sourceRange))
        }
    }
}
