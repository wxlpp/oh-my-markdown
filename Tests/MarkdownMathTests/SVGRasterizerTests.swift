import Testing
import Foundation
import MathJaxSwift
import SwiftDraw

@Suite("SwiftDraw × MathJax spike")
struct SVGRasterizerSpikeTests {
    @Test("tex2svg 产出可被 SwiftDraw 光栅化为非空位图")
    func mathjaxSVGRasterizes() async throws {
        let mathjax = try MathJax(preferredOutputFormat: .svg)
        let svg = try await mathjax.tex2svg("x^2 + \\frac{a}{b}")
        #expect(svg.contains("<svg"))

        // MathJax emits `ex` CSS units for width/height (e.g. "7.64ex").
        // SwiftDraw does not support `ex` units and returns nil; normalise to `px`
        // before handing off. This pre-processing is part of the real rasteriser
        // pipeline (Task 13 SVGRasterizer) — verified here as part of the spike.
        let normalisedSVG = svg.replacingOccurrences(
            of: #"(\d+\.?\d*)ex"#,
            with: "$1px",
            options: .regularExpression
        )

        let data = try #require(normalisedSVG.data(using: .utf8))
        let optionalDrawing = SVG(data: data)
        let drawing = try #require(optionalDrawing)
        // On macOS (AppKit), SwiftDraw exposes rasterize(with:scale:) -> NSImage.
        let image = drawing.rasterize(with: nil, scale: 2.0)
        #expect(image.size.width > 1)
        #expect(image.size.height > 1)
    }
}
