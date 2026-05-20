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

    @Test("极端纵横比 svg → .failed（OOM 防御，Copilot PR #5 R1 #1）")
    func extremeAspectRatioRefused() async {
        // viewBox 极小 width + 极大 height：fit-width 保留小宽度（≤ available），
        // 由 native 纵横比派生的 target.height = width × (native.h / native.w) 会
        // 膨胀至几十万 pt，光栅化分配巨型位图（无上界守卫前是 OOM 攻击向量）。
        let evil = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 1000000\" width=\"100\" height=\"1000000\"><rect width=\"100\" height=\"1000000\" fill=\"red\"/></svg>"
        let r = SwiftDrawSVGBlockRenderer()
        if case .failed = await r.render(svg: evil, availableWidth: 100, scale: 2) {
            // ok：守卫拒绝
        } else {
            #expect(Bool(false), "expected .failed for extreme aspect ratio (target height would exceed maxRasterPointDimension)")
        }
    }
}
