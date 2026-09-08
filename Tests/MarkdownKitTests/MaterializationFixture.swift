import Foundation
import MarkdownCore
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit

/// Test setup for the real prepare/materialize boundary; it has no rendering logic.
@MainActor
struct MaterializationFixture {
    var style: RenderStyle
    var availableWidth: CGFloat
    var placeholderMode: PlaceholderMode
    var contentSizeCategory: MarkdownContentSizeCategory = .large
    var images: [String: PlatformImage] = [:]
    var math: [String: (PlatformImage, Double)] = [:]
    var svg: [String: PlatformImage] = [:]

    init(style: RenderStyle = .default, availableWidth: CGFloat = .greatestFiniteMagnitude, placeholderMode: PlaceholderMode = .streaming) {
        self.style = style
        self.availableWidth = availableWidth
        self.placeholderMode = placeholderMode
    }

    func snapshot(_ blocks: [BlockNode]) -> RenderSnapshot {
        let configuration = self.style.snapshot(generation: 0, contentSizeCategory: self.contentSizeCategory)
        let document = MarkdownDocument(parsedBlocks: blocks.map { ParsedBlockNode(block: $0) })
        let input = RenderInput(
            document: document,
            source: nil,
            availableWidth: availableWidth,
            configuration: configuration,
            placeholderMode: placeholderMode
        )
        let model = try! RenderPreparer(configuration: configuration).prepare(input)
        var values: [ResourceID: ResolvedPlatformResource] = [:]
        for resource in model.resources {
            switch resource {
            case .image(let id, let source, _):
                if let image = images[source] { values[id] = .image(image, owner: TestResourceOwner(retaining: image)) }
            case .math(let id, let latex, _):
                if let (image, baseline) = math[latex] {
                    values[id] = .math(owner: RenderedResourceRecord(image: image, baselineOffset: baseline).acquireLease())
                }
            case .svg(let id, let source):
                if let image = svg[source] {
                    values[id] = .svg(owner: RenderedResourceRecord(image: image, baselineOffset: 0).acquireLease())
                }
            }
        }
        return RenderMaterializer(configuration: configuration).materialize(model, resources: .init(values: values))
    }

    func render(_ blocks: [BlockNode]) -> NSAttributedString {
        self.snapshot(blocks).attributedString
    }

    func renderBlock(_ block: BlockNode) -> NSAttributedString {
        self.render([block])
    }
}

@MainActor
func fixtureColor(_ color: PlatformColor) -> PlatformColor {
    #if canImport(UIKit)
    let resolved = color.resolvedColor(with: .current)
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    precondition(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
    return PlatformColor(red: red, green: green, blue: blue, alpha: alpha)
    #else
    return color.usingColorSpace(.sRGB)!
    #endif
}
