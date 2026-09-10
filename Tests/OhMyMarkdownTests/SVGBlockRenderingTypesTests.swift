import CoreGraphics
import Foundation
@testable import MarkdownRenderKit
import Testing

@Suite("SVG block rendering types")
struct SVGBlockRenderingTypesTests {
    @Test("SVGBlockCacheKey distinct on every dimension")
    func keyDimensions() {
        let base = SVGBlockCacheKey(svg: "<svg/>", availableWidth: 100, rasterScale: 2, configurationID: .semantic(namespace: "fixture", version: 0))
        #expect(base == SVGBlockCacheKey(svg: "<svg/>", availableWidth: 100, rasterScale: 2, configurationID: .semantic(namespace: "fixture", version: 0)))
        #expect(base != SVGBlockCacheKey(svg: "<svg />", availableWidth: 100, rasterScale: 2, configurationID: .semantic(namespace: "fixture", version: 0)))
        #expect(base != SVGBlockCacheKey(svg: "<svg/>", availableWidth: 101, rasterScale: 2, configurationID: .semantic(namespace: "fixture", version: 0)))
        #expect(base != SVGBlockCacheKey(svg: "<svg/>", availableWidth: 100, rasterScale: 3, configurationID: .semantic(namespace: "fixture", version: 0)))
        #expect(base != SVGBlockCacheKey(svg: "<svg/>", availableWidth: 100, rasterScale: 2, configurationID: .semantic(namespace: "fixture", version: 1)))
    }

    @Test("markdownSVGBlockSource attribute key is stable")
    func attrKey() {
        #expect(NSAttributedString.Key.markdownSVGBlockSource.rawValue == "OhMyMarkdown.svgBlockSource")
    }
}
