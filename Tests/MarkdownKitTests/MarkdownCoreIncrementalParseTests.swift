import MarkdownCore
import Testing

@Suite("MarkdownCore incremental parsing")
struct MarkdownCoreIncrementalParseTests {
    @Test("Parsed blocks include stable source fingerprints")
    func parsedBlocksIncludeStableFingerprints() throws {
        let source = """
        # Title

        Paragraph text.
        """

        let first = MarkdownDocument(parsing: source)
        let second = MarkdownDocument(parsing: source)

        #expect(first.parsedBlocks.count == 2)
        let firstFingerprint = try #require(first.parsedBlocks.first?.fingerprint)
        let secondFingerprint = try #require(second.parsedBlocks.first?.fingerprint)
        #expect(firstFingerprint == secondFingerprint)
    }

    @Test("Appending preserves stable prefix fingerprints")
    func appendPreservesStablePrefixFingerprints() throws {
        let original = """
        # Title

        First paragraph.
        """
        let appended = original + "\n\nSecond paragraph."

        let previous = MarkdownDocument(parsing: original)
        let incremental = previous.parsingAppend(to: appended, previousSource: original)

        let previousFingerprint = try #require(previous.parsedBlocks.first?.fingerprint)
        let incrementalFingerprint = try #require(incremental.parsedBlocks.first?.fingerprint)
        #expect(previousFingerprint == incrementalFingerprint)
        #expect(previous.parsedBlocks.first?.sourceRange == incremental.parsedBlocks.first?.sourceRange)
    }

    @Test("Appending a new block preserves parse result")
    func appendNewBlockMatchesFullParse() {
        let original = """
        # Title

        First paragraph.
        """
        let appended = original + "\n\nSecond paragraph."

        let previous = MarkdownDocument(parsing: original)
        let incremental = previous.parsingAppend(to: appended, previousSource: original)
        let full = MarkdownDocument(parsing: appended)

        #expect(incremental.blocks == full.blocks)
        #expect(incremental.parsedBlocks.count == full.parsedBlocks.count)
    }

    @Test("Appending setext marker can reclassify the previous paragraph")
    func appendSetextMarkerMatchesFullParse() {
        let original = "Title"
        let appended = "Title\n---"

        let previous = MarkdownDocument(parsing: original)
        let incremental = previous.parsingAppend(to: appended, previousSource: original)
        let full = MarkdownDocument(parsing: appended)

        #expect(incremental.blocks == full.blocks)
        #expect(incremental.blocks == [.heading(level: 2, content: [.text("Title")])])
    }

    @Test("Appending table delimiter can reclassify the previous paragraph")
    func appendTableDelimiterMatchesFullParse() {
        let original = "| Name | Value |"
        let appended = """
        | Name | Value |
        | --- | --- |
        | A | B |
        """

        let previous = MarkdownDocument(parsing: original)
        let incremental = previous.parsingAppend(to: appended, previousSource: original)
        let full = MarkdownDocument(parsing: appended)

        #expect(incremental.blocks == full.blocks)
        guard case .table = incremental.blocks.first else {
            Issue.record("Expected table after delimiter append")
            return
        }
    }

    @Test("Streaming table rows remain attached to the table")
    func streamingTableRowsRemainAttached() {
        let source = """
        | Name | Value |
        | --- | --- |
        | A | B |
        | C | D |
        """
        var previousSource = ""
        var document = MarkdownDocument(parsing: previousSource)
        var index = source.startIndex
        while index < source.endIndex {
            let next = source.index(index, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex
            let newSource = previousSource + source[index ..< next]
            document = document.parsingAppend(to: String(newSource), previousSource: previousSource)
            previousSource = String(newSource)
            index = next
        }

        let full = MarkdownDocument(parsing: source)

        #expect(document.blocks == full.blocks)
        guard case .table(_, _, let rows) = document.blocks.first else {
            Issue.record("Expected streamed content to remain a table")
            return
        }
        #expect(rows.count == 2)
    }

    @Test("Non-prefix edits fall back to full parse")
    func nonPrefixEditFallsBackToFullParse() {
        let original = "# Title\n\nBody"
        let edited = "# New Title\n\nBody"

        let previous = MarkdownDocument(parsing: original)
        let incremental = previous.parsingAppend(to: edited, previousSource: original)
        let full = MarkdownDocument(parsing: edited)

        #expect(incremental.blocks == full.blocks)
    }
}
