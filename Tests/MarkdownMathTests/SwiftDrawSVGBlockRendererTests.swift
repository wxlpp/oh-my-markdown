import Foundation
@testable import MarkdownMath
@testable import MarkdownRenderKit
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
        #expect(abs(g.image.pointSize.width - 100) <= 0.5)
        #expect(abs(g.image.pointSize.height - 50) <= 0.5)
    }

    @Test("availableWidth ≥ 原生宽 → 不放大，保持原生尺寸")
    func noUpscale() async {
        let r = SwiftDrawSVGBlockRenderer()
        guard case .rendered(let g) = await r.render(svg: Self.valid, availableWidth: 999, scale: 1) else {
            #expect(Bool(false)); return
        }
        #expect(abs(g.image.pointSize.width - 200) <= 0.5)
        #expect(abs(g.image.pointSize.height - 100) <= 0.5)
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
            #expect(Bool(false), "expected .failed for extreme aspect ratio (target height would exceed maxRasterPixelDimension)")
        }
    }

    @Test("高 scale 放大像素 → .failed（codex adversarial R #2：point cap 漏 Retina）")
    func highScalePixelCapEnforced() async {
        // 2000pt × 2000pt 方形 SVG，在 scale=3 下像素维度 = 6000px，超过 4096
        // 像素上限 → .failed。证明守卫按像素而非点判定，Retina 不能绕过。
        // 比照：scale=1 下 2000pt × 1 = 2000px，<4096 → 应 .rendered。
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 2000 2000\" width=\"2000\" height=\"2000\"><rect width=\"2000\" height=\"2000\" fill=\"green\"/></svg>"
        let r = SwiftDrawSVGBlockRenderer()
        if case .failed = await r.render(svg: svg, availableWidth: 9999, scale: 3) {
            // ok：scale 3 下像素超界
        } else {
            #expect(Bool(false), "expected .failed when point × scale exceeds maxRasterPixelDimension")
        }
        // 同一 SVG 在低 scale 下应能渲染
        if case .rendered = await r.render(svg: svg, availableWidth: 9999, scale: 1) {
            // ok
        } else {
            #expect(Bool(false), "expected .rendered when point × scale ≤ maxRasterPixelDimension")
        }
    }
}
