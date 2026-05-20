import Testing
import CoreGraphics
import Foundation
@testable import MarkdownRenderKit

@Suite("SVG block rendering types")
struct SVGBlockRenderingTypesTests {
    @Test("SVGBlockCacheKey distinct on every dimension")
    func keyDimensions() {
        let base = SVGBlockCacheKey(svg: "<svg/>", availableWidth: 100, rasterScale: 2, rendererGeneration: 0)
        #expect(base == SVGBlockCacheKey(svg: "<svg/>", availableWidth: 100, rasterScale: 2, rendererGeneration: 0))
        #expect(base != SVGBlockCacheKey(svg: "<svg />", availableWidth: 100, rasterScale: 2, rendererGeneration: 0))
        #expect(base != SVGBlockCacheKey(svg: "<svg/>", availableWidth: 101, rasterScale: 2, rendererGeneration: 0))
        #expect(base != SVGBlockCacheKey(svg: "<svg/>", availableWidth: 100, rasterScale: 3, rendererGeneration: 0))
        #expect(base != SVGBlockCacheKey(svg: "<svg/>", availableWidth: 100, rasterScale: 2, rendererGeneration: 1))
    }
    @Test("markdownSVGBlockSource attribute key is stable")
    func attrKey() {
        #expect(NSAttributedString.Key.markdownSVGBlockSource.rawValue == "MarkdownKit.svgBlockSource")
    }
}
