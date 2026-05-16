import MarkdownRenderKit
import Testing
import Foundation

@Suite("Math rendering types")
struct MathRenderingTypeTests {
    @Test("有效字号 = 文本字号 × mathScale，单点计算")
    func effectivePointSize() {
        #expect(MathMetrics.effectivePointSize(textPointSize: 16, mathScale: 1.0) == 16)
        #expect(MathMetrics.effectivePointSize(textPointSize: 16, mathScale: 1.5) == 24)
    }

    @Test("MathCacheKey 任一维度不同则不相等")
    func cacheKeyIdentity() {
        let base = MathCacheKey(latex: "x", display: false, pointSize: 16,
                                colorHex: "#000", rasterScale: 2, rendererGeneration: 1)
        #expect(base == MathCacheKey(latex: "x", display: false, pointSize: 16,
                                     colorHex: "#000", rasterScale: 2, rendererGeneration: 1))
        #expect(base != MathCacheKey(latex: "x", display: false, pointSize: 24,
                                     colorHex: "#000", rasterScale: 2, rendererGeneration: 1))
        #expect(base != MathCacheKey(latex: "x", display: false, pointSize: 16,
                                     colorHex: "#000", rasterScale: 2, rendererGeneration: 2))
        #expect(base != MathCacheKey(latex: "y", display: false, pointSize: 16,
                                     colorHex: "#000", rasterScale: 2, rendererGeneration: 1))
        #expect(base != MathCacheKey(latex: "x", display: true, pointSize: 16,
                                     colorHex: "#000", rasterScale: 2, rendererGeneration: 1))
        #expect(base != MathCacheKey(latex: "x", display: false, pointSize: 16,
                                     colorHex: "#111", rasterScale: 2, rendererGeneration: 1))
        #expect(base != MathCacheKey(latex: "x", display: false, pointSize: 16,
                                     colorHex: "#000", rasterScale: 3, rendererGeneration: 1))
    }
}
