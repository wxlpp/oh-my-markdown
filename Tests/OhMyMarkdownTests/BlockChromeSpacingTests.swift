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
struct BlockChromeSpacingTests {
    @Test func adjacentDecoratedBlocksDoNotOverlap() throws {
        let source = """
        ## Scene notes

        | Detail | Use |
        | --- | --- |
        | Salt | Coast |

        ```text
        SCENE 01
        Location: harbour
        Time: dusk
        ```

        > Let the setting reveal the character.
        """
        let snapshot = MaterializationFixture(availableWidth: 350).snapshot(MarkdownDocument(parsing: source).blocks)
        let storage = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.textContainer = container
        storage.addTextLayoutManager(layout)
        storage.textStorage?.setAttributedString(snapshot.attributedString)
        layout.ensureLayout(for: layout.documentRange)
        let decorations = MarkdownLabelDecorations(style: .default, bounds: CGRect(x: 0, y: 0, width: 350, height: 1000), layoutManager: layout, contentStorage: storage, liveString: snapshot.attributedString, blockStarts: snapshot.blockStarts)
        let heading = try #require(decorations.blockFrameUnion(at: 0))
        let table = try #require(decorations.blockFrameUnion(at: 1))
        let code = try #require(decorations.blockFrameUnion(at: 2))
        let quote = try #require(decorations.blockFrameUnion(at: 3))
        #expect(table.minY - 8 > heading.maxY)
        #expect(code.minY - 8 > table.maxY + 8)
        #expect(quote.minY - 4 > code.maxY + 8)
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 350, height: 1000))
        view.replaceSnapshot(snapshot, token: RenderCommitToken(sessionID: RenderSessionID(rawValue: UUID()), sequence: 1, sourceRevision: 1, configurationGeneration: 1))
        #expect(view.intrinsicContentSize.height >= quote.maxY + 4)
    }
}
