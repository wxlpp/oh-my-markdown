import Foundation
@testable import MarkdownCore
@testable import MarkdownRenderKit
import Testing

@Suite("SVG block degradation")
@MainActor
struct SVGBlockDegradationTests {
    @Test("无渲染器（空 cache）→ ```svg 保持为可读高亮源码块，不崩、不空")
    func noRendererDegrades() {
        let r = MaterializationFixture(style: .default, availableWidth: 320) // svgBlockCache 空
        let out = r.renderBlock(.codeBlock(language: "svg", body: "<svg viewBox=\"0 0 4 4\"/>"))
        #expect(out.length > 0)
        #expect(out.string.contains("<svg")) // 源串可见（降级可读态）
        #expect(!out.string.contains("\u{FFFC}")) // 未渲染时不应出现 attachment 字符
        var marked = false
        out.enumerateAttribute(.markdownSVGBlockSource, in: NSRange(location: 0, length: out.length)) { v, _, _ in
            if v != nil { marked = true }
        }
        #expect(marked) // 仍打了占位标记，待平台层异步触发
    }
}
