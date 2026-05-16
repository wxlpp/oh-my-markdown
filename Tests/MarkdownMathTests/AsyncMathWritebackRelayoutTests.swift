import Testing
import Foundation
@testable import MarkdownPlatformView
import MarkdownCore
import MarkdownRenderKit
@testable import MarkdownMath
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Bug 1 — 流式渲染大量文字重叠 的非 GUI 复现 / 回归钉死。
///
/// 根因（Phase 1 取证）：math 字形异步解析完成后，write-back 走
/// `MainActor.run { … updateContent() }` → `resetLayout()`。而 `resetLayout()`
/// 只做 `invalidateIntrinsicContentSize()` + `needsDisplay`，**缺**与流式增量路径
/// `applyDocument` 对称的「请求宿主重新布局/重测高度」纪律：`applyDocument` 末尾会
/// `scheduleDeferredHeightUpdate()`（→ `_heightUpdateTask != nil`）并
/// `setNeedsLayout()`/`needsLayout = true`，而 `resetLayout()` 反而在开头
/// cancel + nil 掉 `_heightUpdateTask`，也不请求宿主重新布局。
///
/// math 占位（latex 文本，会换行 → 较高）→ 解析回写成单个小 attachment（缩高）时，
/// 内容层高度确实变了（TextKit 已重排，本测亲测 108 → 70），但宿主
/// （SwiftUI ScrollView）从未被要求重新查询 `intrinsicContentSize`，
/// 仍按陈旧高帧绘制 → 新短内容与旧字形视觉重叠。
///
/// 可观察代理量：`view._hostRelayoutRequestCount`（单调计数器，在 `resetLayout()`
/// 请求宿主重布局 + 延迟重测处自增；纯观察、零生产行为，仅一个 Int++）。延迟重测
/// 任务约 33ms 后自 nil，瞬时 flag 会与测试竞态，故用单调计数器作为持久后置条件。
/// buggy 下异步 write-back 经 resetLayout 不请求宿主重布局 → 计数不增（红）；
/// 补与 applyDocument 对称的失效后 → 计数严格增加（绿）。
@MainActor
@Suite("Async math write-back relayout (Bug 1)")
struct AsyncMathWritebackRelayoutTests {
    @Test("异步 math 字形回写后必须像 applyDocument 一样请求宿主重测（缩高不重叠）")
    func asyncMathWritebackSchedulesHostRemeasure() async {
        // 多个独立 inline $...$：占位是会换行的 latex 文本（较高）；
        // 异步解析回写成一串小 attachment → 内容剧烈缩高，正是触发重叠的几何条件。
        let spans = (0 ..< 8).map { "$x_{\($0)}$" }.joined(separator: " 填充文字 ")
        let markdown = "前置一段普通文字。\n\n\(spans)\n\n后置一段普通文字。"

        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 10_000))
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #elseif canImport(AppKit)
        view.layoutSubtreeIfNeeded()
        #endif

        // 先注入真实 MathJaxRenderer 并让 didSet 的 setRenderer 异步落地，
        // 再喂内容 —— 这样 triggerMathLoads 一定能看到非 nil renderer 并真正派发。
        view.mathRenderer = MathJaxRenderer()
        for _ in 0 ..< 20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        view.setMarkdown(markdown)

        // 等流式 parse 落地，记录 math 解析回写「之前」的占位高度（latex 文本换行 → 较高）。
        var parsed = false
        for _ in 0 ..< 50 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
            if view.blocks.count >= 3 { parsed = true; break }
        }
        #expect(parsed, "流式 parse 未在超时内完成")
        let placeholderHeight = view.intrinsicContentSize.height
        #expect(placeholderHeight > 0)
        // 流式占位由 applyDocument 走（不经 resetLayout）。记录 math 异步 write-back
        // 「之前」的宿主重布局请求计数；此后到 write-back 之间唯一会走
        // updateContent()→resetLayout() 的就是 math 字形回写本身。
        let relayoutCountBeforeWriteback = view._hostRelayoutRequestCount

        // 等异步 math 解析 + write-back 落地：write-back 走 updateContent() 重渲染，
        // mathCache 命中 → 占位 latex 文本被一串小 attachment 取代 → 内容层高度
        // （TextKit usageBounds，headless 可靠）显著下降并稳定。以「高度较占位显著
        // 下降且连续多采样稳定」作为 write-back 完成信号 —— intrinsicContentSize
        // 为 public、随 TextKit 重排，无需触碰任何私有内部。
        var shrunkHeight = placeholderHeight
        var stableCount = 0
        var settled = false
        for _ in 0 ..< 400 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 30_000_000)
            let h = view.intrinsicContentSize.height
            if h < placeholderHeight - 1 {
                if abs(h - shrunkHeight) < 0.5 {
                    stableCount += 1
                    if stableCount >= 5 { settled = true; break }
                } else {
                    stableCount = 0
                }
                shrunkHeight = h
            }
        }
        #expect(
            settled,
            "math 字形未在超时内异步解析并回写：placeholder=\(placeholderHeight) shrunk=\(shrunkHeight)"
        )

        // 内容层正确性（证明 bug 是布局/几何，不是内容）：占位 latex 文本已被
        // 解析出的 attachment 取代，内容剧烈缩高。
        #expect(
            shrunkHeight < placeholderHeight,
            "回写后内容应剧烈缩高：placeholder=\(placeholderHeight) shrunk=\(shrunkHeight)"
        )

        // 关键断言：异步 write-back 必须像 applyDocument 一样请求宿主重布局 +
        // 安排延迟高度重测。buggy：resetLayout 只 invalidateIntrinsicContentSize +
        // needsDisplay，且开头还 cancel/nil 掉 _heightUpdateTask、不 setNeedsLayout，
        // 计数不增 → 红。fixed：write-back 路径补 setNeedsLayout +
        // scheduleDeferredHeightUpdate，计数严格增加 → 绿。
        let afterCount = view._hostRelayoutRequestCount
        #expect(
            afterCount > relayoutCountBeforeWriteback,
            "异步 math 回写未请求宿主重布局/重测（before=\(relayoutCountBeforeWriteback) after=\(afterCount)）——宿主仍用陈旧高帧 → 文字重叠（Bug 1 根因）"
        )
    }
}
