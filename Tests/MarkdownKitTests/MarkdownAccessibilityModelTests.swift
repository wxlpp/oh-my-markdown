import Foundation
import MarkdownCore
@testable import MarkdownRenderKit
import Testing

/// Task 10's semantic tree. The exposed-leaf sequence *is* what a screen reader
/// reads, in order, so these goldens are the specification.
@MainActor
@Suite(.serialized)
struct MarkdownAccessibilityModelTests {
    private static let fixture = """
    # Title

    Text with [one](https://a.test) and [two](https://b.test), an ![a cat](https://i.test/p.png) and $x^2$.

    - first
    - second

    ```swift
    let a = 1
    ```

    | Name | Age |
    |---|---|
    | Ada | 36 |
    """

    private func tree(_ markdown: String, generation: UInt64 = 0, width: Double = 360) throws -> AccessibilityTree {
        let configuration = RenderStyle.default.snapshot(generation: generation)
        let input = RenderInput(
            document: MarkdownDocument(parsing: markdown), source: markdown,
            availableWidth: width, configuration: configuration, placeholderMode: .static
        )
        return try RenderPreparer(configuration: configuration).prepare(input).accessibility
    }

    /// Every node a screen reader stops on, depth-first, as `role|label`.
    private func leaves(_ tree: AccessibilityTree) -> [String] {
        func walk(_ node: AccessibilityNode) -> [String] {
            node.children.isEmpty
                ? ["\(node.role)|\(node.label ?? "")"]
                : node.children.flatMap(walk)
        }
        return tree.roots.flatMap(walk)
    }

    @Test func theExposedLeafSequenceIsTheDocumentReadInOrder() throws {
        let leaves = try self.leaves(self.tree(Self.fixture))
        #expect(leaves == [
            "heading(level: 1)|Title",
            "text|Text with ",
            "link|one",
            "text| and ",
            "link|two",
            "text|, an ",
            "image|a cat",
            "text| and ",
            "math|x^2",
            "text|.",
            "listItem|first",
            "listItem|second",
            "code|let a = 1",
            "columnHeader|Name",
            "columnHeader|Age",
            "cell|Ada",
            "cell|36",
        ])
    }

    /// A container that also spoke its children would read everything twice.
    @Test func containersDoNotRepeatTheirInteractiveChildren() throws {
        let tree = try self.tree(Self.fixture)
        func containers(_ node: AccessibilityNode) -> [AccessibilityNode] {
            node.children.isEmpty ? [] : [node] + node.children.flatMap(containers)
        }
        for container in tree.roots.flatMap(containers) {
            #expect(container.label == nil, "container \(container.role) also speaks: \(container.label ?? "")")
        }
    }

    @Test func linksAreIndependentlyActivatable() throws {
        let tree = try self.tree(Self.fixture)
        func all(_ node: AccessibilityNode) -> [AccessibilityNode] {
            [node] + node.children.flatMap(all)
        }
        let links = tree.roots.flatMap(all).filter { $0.role == .link }
        #expect(links.count == 2)
        #expect(links.map(\.label) == ["one", "two"])
        #expect(links.allSatisfy { $0.activation != nil })
    }

    /// Two links in one paragraph share a block lineage and a source anchor, so
    /// identity needs the leaf's position to tell them apart.
    @Test func everyNodeIdentityIsUnique() throws {
        let tree = try self.tree(Self.fixture)
        func all(_ node: AccessibilityNode) -> [AccessibilityNode] {
            [node] + node.children.flatMap(all)
        }
        let ids = tree.roots.flatMap(all).map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate accessibility identities")
    }

    @Test func tableCellsCarryTheirCoordinatesAndColumnHeader() throws {
        let tree = try self.tree(Self.fixture)
        func all(_ node: AccessibilityNode) -> [AccessibilityNode] {
            [node] + node.children.flatMap(all)
        }
        let cells = tree.roots.flatMap(all).filter { $0.role == .cell }
        #expect(cells.count == 2)
        #expect(cells.first?.detail == .cell(row: 1, column: 0, columnHeader: "Name"))
        #expect(cells.last?.detail == .cell(row: 1, column: 1, columnHeader: "Age"))
    }

    @Test func codeBlocksCarryTheirLanguage() throws {
        let tree = try self.tree(Self.fixture)
        func all(_ node: AccessibilityNode) -> [AccessibilityNode] {
            [node] + node.children.flatMap(all)
        }
        let code = try #require(tree.roots.flatMap(all).first { $0.role == .code })
        #expect(code.detail == .code(language: "swift"))
    }

    @Test func listItemsCarryTheirPositionAndCount() throws {
        let tree = try self.tree(Self.fixture)
        func all(_ node: AccessibilityNode) -> [AccessibilityNode] {
            [node] + node.children.flatMap(all)
        }
        let items = tree.roots.flatMap(all).filter { $0.role == .listItem }
        #expect(items.map(\.detail) == [.listItem(position: 1, count: 2), .listItem(position: 2, count: 2)])
    }

    /// An image without alt text still has to say something.
    @Test func imagesWithoutAltTextFallBackToALocalizedLabel() throws {
        let tree = try self.tree("![](https://i.test/p.png)")
        func all(_ node: AccessibilityNode) -> [AccessibilityNode] {
            [node] + node.children.flatMap(all)
        }
        let image = try #require(tree.roots.flatMap(all).first { $0.role == .image })
        let label = try #require(image.label)
        #expect(!label.isEmpty)
        #expect(label != "markdown.accessibility.image", "the fallback label is not localized")
    }

    /// The tree says *what* a reader stops on; the runs say *where* it is on
    /// screen. They come from two walks over the same block, so nothing but this
    /// assertion stops them drifting — and a drift means an element pointing at
    /// the wrong place, which no other test would notice.
    @Test func everyLeafIsTaggedOnTheRunsThatRenderIt() throws {
        for markdown in [
            Self.fixture,
            "plain paragraph",
            "- [a](https://a.test) and text\n- plain",
            "> quoted [link](https://a.test)\n\n$$\nx\n$$",
            "| a |\n|---|\n| ![alt](https://i.test/p.png) |",
        ] {
            let configuration = RenderStyle.default.snapshot(generation: 0)
            let input = RenderInput(
                document: MarkdownDocument(parsing: markdown), source: markdown,
                availableWidth: 360, configuration: configuration, placeholderMode: .static
            )
            let model = try RenderPreparer(configuration: configuration).prepare(input)
            for bundle in model.bundles {
                func leafOrdinals(_ node: AccessibilityNode) -> [Int] {
                    node.children.isEmpty ? [node.id.ordinal] : node.children.flatMap(leafOrdinals)
                }
                let expected = Set(bundle.accessibilityRoots.flatMap(leafOrdinals))
                var tagged: Set<Int> = []
                func note(_ runs: [PreparedRun]) {
                    // Negative means the run renders no leaf of its own: a bullet.
                    for run in runs where run.accessibilityOrdinal >= 0 {
                        tagged.insert(run.accessibilityOrdinal)
                    }
                }
                for piece in bundle.content {
                    switch piece {
                    case .blockStart: break
                    case .run(let run): note([run])
                    case .table(let table):
                        table.head.forEach(note)
                        table.rows.forEach { $0.forEach(note) }
                    }
                }
                #expect(
                    tagged == expected,
                    "leaf tags drifted in \(markdown.debugDescription): tagged \(tagged.sorted()) vs leaves \(expected.sorted())"
                )
            }
        }
    }

    /// Appending to the last paragraph must not renumber the leaves before it,
    /// or focus jumps on every streamed chunk.
    @Test func appendingKeepsTheIdentitiesOfEverythingBeforeTheGrowingTail() throws {
        let prefix = "# Title\n\nalpha [one](https://a.test) beta"
        let before = try self.tree(prefix)
        let after = try self.tree(prefix + " more and more")
        func all(_ node: AccessibilityNode) -> [AccessibilityNode] {
            [node] + node.children.flatMap(all)
        }
        let beforeIDs = before.roots.flatMap(all).map(\.id)
        let afterIDs = after.roots.flatMap(all).map(\.id)
        #expect(beforeIDs.count > 2)
        #expect(Array(afterIDs.prefix(beforeIDs.count - 1)) == Array(beforeIDs.prefix(beforeIDs.count - 1)))
    }
}
