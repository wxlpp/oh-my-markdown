import Foundation
@testable import MarkdownCore
@testable import MarkdownRenderKit
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite("SVG code-block rendering branch")
@MainActor
struct SVGBlockRenderTests {
    private func render(
        _ block: BlockNode,
        cache: [SVGBlockCacheKey: PlatformImage] = [:],
        width: CGFloat = 320
    ) -> NSAttributedString {
        var r = MaterializationFixture(style: .default, availableWidth: width)
        r.svg = Dictionary(uniqueKeysWithValues: cache.map { ($0.key.svg, $0.value) })
        return r.renderBlock(block)
    }

    @Test("language svg (case/space-insensitive), cache miss → highlighted code block + marker attr")
    func missKeepsHighlightedCodeWithMarker() {
        let out = self.render(.codeBlock(language: " SVG ", body: "<svg/>"))
        var found = false
        out.enumerateAttribute(.markdownSVGBlockSource, in: NSRange(location: 0, length: out.length)) { v, _, _ in
            if (v as? String) == "<svg/>" { found = true }
        }
        #expect(found)
        #expect(out.length > 0)
        #expect(!out.string.contains("\u{FFFC}"))
    }

    @Test("cache hit → single centered attachment sized to image, origin.y == 0；paragraphSpacing 与 miss 对齐（无解析跳动）")
    func hitProducesCenteredAttachment() throws {
        let sized = makeImage(width: 200, height: 90)
        let key = SVGBlockCacheKey(svg: "<svg/>", availableWidth: 320, rasterScale: 1, configurationID: .semantic(namespace: "fixture", version: 0))
        let out = self.render(.codeBlock(language: "svg", body: "<svg/>"), cache: [key: sized])
        var att: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { v, _, _ in
            att = v as? NSTextAttachment
        }
        let a = try #require(att)
        #expect(a.bounds.size.width == 200)
        #expect(a.bounds.size.height == 90)
        #expect(a.bounds.origin.y == 0)
        let para = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(para?.alignment == .center)
        // Copilot PR #5 R6 #1：hit 的 paragraphSpacing 必须与 miss 路径
        // （renderHighlightedCodeBlock 的 0）一致，否则 marker→attachment 解析
        // 瞬间会引起垂直跳动。
        #expect(para?.paragraphSpacing == 0)
    }

    @Test("non-svg code block unchanged (regression)")
    func nonSvgUnchanged() {
        let a = self.render(.codeBlock(language: "swift", body: "let x = 1"))
        let b: NSAttributedString = {
            let r = MaterializationFixture(style: .default, availableWidth: 320)
            return r.renderBlock(.codeBlock(language: "swift", body: "let x = 1"))
        }()
        #expect(a.isEqual(to: b))
    }

    @Test("miss 状态 enumerateAttribute 对相同 value 合并成单次回调（验证：Copilot R3 #2/#3 假设不成立，去重保留为防御性代码）")
    func missEnumerationCoalescesSameValue() {
        // Copilot R3 #2/#3 假设：SyntaxHighlighter 切多 token run 会让
        // enumerateAttribute 对同一 svg payload 多次回调 → 重复 dispatch。
        // 实测：Foundation 的 `enumerateAttribute(_:in:options:using:)` 文档
        // 即「returns the maximum range over which the attribute's value applies」，
        // 同 value 的 .markdownSVGBlockSource 跨多 foregroundColor token run
        // 仍合并成**单次**回调（同 attribute 不同 value 才会分段）。
        // 本测试将假设钉死：若一日 enumeration 改成按 run 拆分（如 token-by-token
        // 上色发生在加 marker 之后），本测试红，去重才真正生效——届时需要
        // 双向确认（修测试 or 升级 dedup 实现）。
        let body = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><rect width=\"10\" height=\"10\" fill=\"red\"/></svg>"
        let out = self.render(.codeBlock(language: "svg", body: body))
        var callbackCount = 0
        var distinctValues: Set<String> = []
        out.enumerateAttribute(.markdownSVGBlockSource, in: NSRange(location: 0, length: out.length)) { v, _, _ in
            if let s = v as? String {
                callbackCount += 1
                distinctValues.insert(s)
            }
        }
        #expect(callbackCount == 1, "expect single coalesced callback for same value (Copilot R3 dedup premise is moot in practice; got \(callbackCount))")
        #expect(distinctValues.count == 1)
    }
}

private func makeImage(width: CGFloat, height: CGFloat) -> PlatformImage {
    #if canImport(UIKit)
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in }
    #elseif canImport(AppKit)
    return NSImage(size: NSSize(width: width, height: height))
    #else
    return PlatformImage()
    #endif
}
