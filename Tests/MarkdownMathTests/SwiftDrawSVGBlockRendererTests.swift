@testable import MarkdownMath
@testable import MarkdownRenderKit
import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite("SwiftDrawSVGBlockRenderer")
struct SwiftDrawSVGBlockRendererTests {
    private static let valid = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 200 100\" width=\"200\" height=\"100\"><rect width=\"200\" height=\"100\" fill=\"#3366cc\"/></svg>"

    @Test("valid svg → 点尺寸（非 pixel×scale）、fit-width、保持纵横比、不放大")
    func renderedPointSize() async {
        let r = SwiftDrawSVGBlockRenderer()
        let out = await r.render(svg: Self.valid, availableWidth: 100, scale: 3)
        guard case .rendered(let g) = out else {
            #expect(Bool(false), "expected .rendered")
            return
        }
        #expect(abs(g.image.size.width - 100) <= 0.5)
        #expect(abs(g.image.size.height - 50) <= 0.5)
    }

    @Test("availableWidth ≥ 原生宽 → 不放大，保持原生尺寸")
    func noUpscale() async {
        let r = SwiftDrawSVGBlockRenderer()
        guard case .rendered(let g) = await r.render(svg: Self.valid, availableWidth: 999, scale: 1) else {
            #expect(Bool(false)); return
        }
        #expect(abs(g.image.size.width - 200) <= 0.5)
        #expect(abs(g.image.size.height - 100) <= 0.5)
    }

    @Test("非法 svg → .failed")
    func invalid() async {
        let r = SwiftDrawSVGBlockRenderer()
        if case .failed = await r.render(svg: "not svg at all", availableWidth: 100, scale: 1) {
            // ok
        } else {
            #expect(Bool(false), "expected .failed for invalid svg")
        }
    }
}
