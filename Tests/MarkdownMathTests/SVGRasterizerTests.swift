import Testing
import Foundation
@testable import MarkdownMath
import MarkdownRenderKit

@Suite("SVGRasterizer")
struct SVGRasterizerUnitTests {
    private let sample = """
    <svg xmlns="http://www.w3.org/2000/svg" width="2.5ex" height="1.2ex" \
    viewBox="0 -442 1041 466" style="vertical-align: -0.25ex;"><g fill="currentColor">\
    <rect x="0" y="0" width="100" height="100"/></g></svg>
    """

    @Test("注入颜色：currentColor 被替换为指定 hex")
    func colorInjection() {
        let out = SVGRasterizer.injectColor(into: sample, hex: "#FF0000")
        #expect(!out.contains("currentColor"))
        #expect(out.contains("#FF0000"))
    }

    @Test("解析 vertical-align(ex) 为基线偏移")
    func parseBaseline() {
        #expect(SVGRasterizer.parseVerticalAlignEx(sample) == -0.25)
    }

    @Test("光栅化产出非退化位图 + 基线 + 点尺寸契约")
    func rasterize() throws {
        let glyph = try SVGRasterizer.rasterize(
            svg: sample, hex: "#000000", pointSize: 16, scale: 2)
        #expect(glyph.image.size.width > 1)
        #expect(glyph.baselineOffsetEx == -0.25)
        let glyph1x = try SVGRasterizer.rasterize(
            svg: sample, hex: "#000000", pointSize: 16, scale: 1)
        #expect(abs(glyph.image.size.height - glyph1x.image.size.height) < 0.5)
        let glyphBig = try SVGRasterizer.rasterize(
            svg: sample, hex: "#000000", pointSize: 32, scale: 2)
        #expect(glyphBig.image.size.height > glyph.image.size.height)
    }

    @Test("正的 vertical-align 也能解析")
    func parseBaselinePositive() {
        let s = #"<svg style="vertical-align: 0.4ex;" width="1ex" height="1ex" viewBox="0 0 1 1"></svg>"#
        #expect(SVGRasterizer.parseVerticalAlignEx(s) == 0.4)
    }

    @Test("前导点尺寸 .5ex 经归一化后可被 SwiftDraw 解析")
    func leadingDotDimensionNormalizes() throws {
        let s = ##"<svg width=".5ex" height=".5ex" viewBox="0 -10 20 20" style="vertical-align: 0ex;"><rect x="0" y="0" width="10" height="10" fill="#000000"/></svg>"##
        // 不应 .parseFailed（Fix C 的前导点正则使 .5ex→.5px，SwiftDraw 可解析）
        let glyph = try SVGRasterizer.rasterize(svg: s, hex: "#000000", pointSize: 16, scale: 1)
        #expect(glyph.image.size.width > 0)
    }
}
