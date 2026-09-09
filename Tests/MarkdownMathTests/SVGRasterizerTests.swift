import CoreGraphics
import Foundation
@testable import MarkdownMath
import MarkdownRenderKit
import Testing

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite("SVGRasterizer")
@MainActor
struct SVGRasterizerUnitTests {
    private let sample = """
    <svg xmlns="http://www.w3.org/2000/svg" width="2.5ex" height="1.2ex" \
    viewBox="0 -442 1041 466" style="vertical-align: -0.25ex;"><g fill="currentColor">\
    <rect x="0" y="0" width="100" height="100"/></g></svg>
    """

    @Test("注入颜色：currentColor 被替换为指定 hex")
    func colorInjection() {
        let out = SVGRasterizer.injectColor(into: self.sample, hex: "#FF0000")
        #expect(!out.contains("currentColor"))
        #expect(out.contains("#FF0000"))
    }

    @Test("解析 vertical-align(ex) 为基线偏移")
    func parseBaseline() {
        #expect(SVGRasterizer.parseVerticalAlignEx(self.sample) == -0.25)
    }

    @Test("光栅化产出非退化位图 + 基线 + 点尺寸契约")
    func rasterize() throws {
        let glyph = try SVGRasterizer.rasterize(
            svg: self.sample, hex: "#000000", pointSize: 16, scale: 2
        )
        #expect(glyph.image.pointSize.width > 1)
        #expect(glyph.baselineOffsetEx == -0.25)
        let glyph1x = try SVGRasterizer.rasterize(
            svg: self.sample, hex: "#000000", pointSize: 16, scale: 1
        )
        #expect(abs(glyph.image.pointSize.height - glyph1x.image.pointSize.height) < 0.5)
        let glyphBig = try SVGRasterizer.rasterize(
            svg: self.sample, hex: "#000000", pointSize: 32, scale: 2
        )
        #expect(glyphBig.image.pointSize.height > glyph.image.pointSize.height)
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
        #expect(glyph.image.pointSize.width > 0)
    }

    /// Bug 2 pixel regression: 8-digit hex (#RRGGBBAA) is misread by SwiftDraw as a
    /// single integer → alpha byte lands in blue channel → center pixel ≈ pure blue.
    /// After fix (6-digit #RRGGBB), SwiftDraw parses correctly → center pixel ≈ black.
    @Test("像素回归：colorHex 注入后中心像素 ≈ 黑（非蓝）")
    func pixelRegressionBlackNotBlue() throws {
        // Minimal solid-fill SVG: 20×20 px viewBox, 1ex square → pointSize 16 → 8 pt target.
        let svgSource = """
        <svg xmlns="http://www.w3.org/2000/svg" width="1ex" height="1ex" \
        viewBox="0 0 20 20" style="vertical-align: 0ex;">\
        <rect x="0" y="0" width="20" height="20" fill="currentColor"/>\
        </svg>
        """
        let hex = MathMetrics.colorHex(PlatformColor.black)
        let glyph = try SVGRasterizer.rasterize(svg: svgSource, hex: hex, pointSize: 16, scale: 2)

        // Extract center pixel from the rasterized image.
        let image = try glyph.image.materialize()
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else {
            Issue.record("No CGImage from UIImage"); return
        }
        #elseif canImport(AppKit)
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            Issue.record("No CGImage from NSImage"); return
        }
        #endif

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { Issue.record("CGImage has zero dimension"); return }

        // Render into a 1×1 RGBA buffer sampling the center pixel.
        let cx = width / 2
        let cy = height / 2
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixel,
            width: 1, height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Issue.record("Failed to create CGContext"); return
        }
        // Draw only the center pixel by offsetting the source image.
        ctx.draw(cgImage, in: CGRect(x: -cx, y: -cy, width: width, height: height))

        let r = pixel[0], g = pixel[1], b = pixel[2]
        // Bug 2 (before fix): 8-digit hex → SwiftDraw blue-shift → B≈255 while R≈0, G≈0.
        // After fix (6-digit): color is correctly parsed as black → R<30, G<30, B<30.
        #expect(Int(b) < 200, "Blue channel too high — SwiftDraw likely misread an 8-digit hex")
        #expect(
            Int(r) < 30 && Int(g) < 30 && Int(b) < 30,
            "Center pixel should be near-black"
        )
    }
}
