import Foundation
@testable import MarkdownCore
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 验证 svg hit 状态时跳过代码块灰底，miss 状态保留——即装饰层
/// `svgBlockIsResolved(at:)` 与 `drawAll` 的 `.codeBlock(language:"svg", _)`
/// 分支共同实现的行为契约（user feedback after codex adversarial review）。
@Suite("SVG code-block background suppression on cache hit")
struct SVGBlockBackgroundSuppressionTests {
    private func makeDecorations(liveString: NSAttributedString, blockStarts: [Int]) -> MarkdownLabelDecorations {
        // layoutManager/contentStorage 仅用于布局相关查询（blockFrameUnion 等），
        // 与 svgBlockIsResolved 无关；构造空壳即可让结构体初始化通过。
        let storage = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        storage.addTextLayoutManager(layout)
        return MarkdownLabelDecorations(
            style: .default,
            bounds: .zero,
            layoutManager: layout,
            contentStorage: storage,
            liveString: liveString,
            blockStarts: blockStarts
        )
    }

    @Test("miss 状态：`.markdownSVGBlockSource` 占位存在 → 仍画灰底（保留可读降级）")
    func missStateKeepsBackground() {
        let miss = NSMutableAttributedString(string: "<svg/>")
        miss.addAttribute(
            .markdownSVGBlockSource,
            value: "<svg/>",
            range: NSRange(location: 0, length: miss.length)
        )
        let dec = self.makeDecorations(liveString: miss, blockStarts: [0])
        #expect(dec.svgBlockIsResolved(at: 0) == false)
    }

    @Test("hit 状态：占位被剥离换成 attachment → 不画灰底")
    func hitStateSkipsBackground() {
        let attachment = NSTextAttachment()
        let hit = NSMutableAttributedString(attachment: attachment)
        let dec = self.makeDecorations(liveString: hit, blockStarts: [0])
        #expect(dec.svgBlockIsResolved(at: 0) == true)
    }
}
