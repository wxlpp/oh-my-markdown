import Foundation
import MarkdownCore
@testable import MarkdownMath
@testable import MarkdownPlatformView
import MarkdownRenderKit
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Bug 1 — 流式渲染大量文字重叠 的非 GUI 复现 / 回归钉死（真守卫版）。
///
/// 根因（Phase 1 取证）：math 字形异步解析完成后，write-back 走
/// `MainActor.run { … updateContent() }` → `resetLayout()`。修复让 `resetLayout()`
/// 在末尾补齐与流式增量路径 `applyDocument` 对称的「请求宿主重测」纪律：
/// `setNeedsLayout()` / `needsLayout = true`（标记宿主重新布局）+
/// `scheduleDeferredHeightUpdate()`（安排延迟高度重测，~33ms 后把缩高后的
/// 新高度回灌 `intrinsicContentSize`）。buggy 下 `resetLayout()` 只
/// `invalidateIntrinsicContentSize()` + `needsDisplay`，宿主从未被要求重测 →
/// 仍按陈旧高帧绘制 → 新短内容与旧字形视觉重叠。
///
/// 真守卫——观测量与真实失效原语「不可分」绑定（无解耦旁路计数器）：
///
///  - 原语 A `scheduleDeferredHeightUpdate()`：`_deferredHeightScheduleCount`
///    自增是该函数体**首行**（声明见生产侧注释），故「计数++」⟺「该函数真被
///    调用」是同一不可分语义。若 `resetLayout()` 停止调用它，异步 write-back
///    路径不会让该计数前进 → 断言红。
///  - 原语 B `needsLayout = true`（AppKit）：`NSView.needsLayout` 是系统公开
///    可读属性，即该原语的真实、不可分、可观测副作用。测试在 write-back 前用
///    layout pass 把它清回 `false`，write-back 后断言它**确实**被重新置为
///    `true`；若 `resetLayout()` 停止 `needsLayout = true`，write-back 路径不
///    会重新标记 → 保持 `false` → 断言红。iOS（`swift test` 不覆盖，仅
///    `xcodebuild` 验证编译）对应原语为 `setNeedsLayout()`，A 半同样适用。
///
/// 隔离：基线在「流式 parse 落地（blocks>=3）且 math write-back 尚未发生」时
/// 快照——此后到 write-back 之间唯一会走 `updateContent()→resetLayout()` 的就
/// 是 math 字形回写本身，故计数 / needsLayout 的变化可归因于该次 write-back。
@MainActor
@Suite("Async math write-back relayout (Bug 1)")
struct AsyncMathWritebackRelayoutTests {
    @Test("异步 math 字形回写必须真正触发 layout 失效原语（缩高不重叠）")
    func asyncMathWritebackDrivesRealLayoutInvalidationPrimitives() async {
        // 多个独立 inline $...$：占位是会换行的 latex 文本（较高）；
        // 异步解析回写成一串小 attachment → 内容剧烈缩高，正是触发重叠的几何条件。
        let spans = (0 ..< 8).map { "$x_{\($0)}$" }.joined(separator: " 填充文字 ")
        let markdown = "前置一段普通文字。\n\n\(spans)\n\n后置一段普通文字。"

        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 320, height: 10000))
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

        // 等流式 parse 落地。此刻 math 异步解析尚未回写（占位 latex 文本仍在，
        // 高度较高）。在这里快照基线：此后唯一走 resetLayout() 的就是 math
        // write-back 本身。
        var parsed = false
        for _ in 0 ..< 50 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
            if view.blocks.count >= 3 { parsed = true; break }
        }
        #expect(parsed, "流式 parse 未在超时内完成")

        let placeholderHeight = view.intrinsicContentSize.height
        #expect(placeholderHeight > 0)
        let blocksAtBaseline = view.blocks.count
        // 原语 A 基线：math write-back 之前的 deferred-schedule 计数。
        let scheduleCountBeforeWriteback = view._deferredHeightScheduleCount

        // 等异步 math 解析 + write-back 落地：mathCache 命中 → 占位 latex 文本被
        // 一串小 attachment 取代 → 内容层高度（TextKit usageBounds，headless 可靠）
        // 显著下降并稳定。
        //
        // 原语 B 隔离：write-back 之前每个采样都把 needsLayout 清回 false（用真实
        // layout pass）。一旦观测到 write-back 的缩高就停止清除——此后只有
        // resetLayout() 里 `needsLayout = true` 这条真实原语能把它重新置 true。
        var shrunkHeight = placeholderHeight
        var stableCount = 0
        var settled = false
        var sawShrink = false
        for _ in 0 ..< 400 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 30_000_000)
            let h = view.intrinsicContentSize.height
            if h < placeholderHeight - 1 {
                sawShrink = true
                if abs(h - shrunkHeight) < 0.5 {
                    stableCount += 1
                    if stableCount >= 5 { settled = true; break }
                } else {
                    stableCount = 0
                }
                shrunkHeight = h
            } else if !sawShrink {
                // write-back 尚未发生：持续把 needsLayout 清回 false，使后续
                // 出现的 true 必定来自 write-back 路径的真实 `needsLayout = true`。
                #if canImport(AppKit)
                view.layoutSubtreeIfNeeded()
                #endif
            }
        }
        #expect(
            settled,
            "math 字形未在超时内异步解析并回写：placeholder=\(placeholderHeight) shrunk=\(shrunkHeight)"
        )

        // 内容层正确性（证明 bug 是布局/几何，不是内容）：占位 latex 文本已被
        // 解析出的 attachment 取代，内容剧烈缩高。无 applyDocument 介入：blocks 不变。
        #expect(
            shrunkHeight < placeholderHeight,
            "回写后内容应剧烈缩高：placeholder=\(placeholderHeight) shrunk=\(shrunkHeight)"
        )
        #expect(
            view.blocks.count == blocksAtBaseline,
            "隔离失败：基线后 blocks 变了，说明期间有 applyDocument 介入（\(blocksAtBaseline) → \(view.blocks.count)）"
        )

        // 关键断言 A：异步 write-back 必须真正调用 `scheduleDeferredHeightUpdate()`
        // （安排延迟高度重测）。计数自增是该函数体首行，与「函数真被调用」不可分。
        // 移除 resetLayout() 末尾的 scheduleDeferredHeightUpdate() → 计数不增 → 红。
        let scheduleCountAfterWriteback = view._deferredHeightScheduleCount
        #expect(
            scheduleCountAfterWriteback > scheduleCountBeforeWriteback,
            "异步 math 回写未调用 scheduleDeferredHeightUpdate()（before=\(scheduleCountBeforeWriteback) after=\(scheduleCountAfterWriteback)）——延迟高度重测从未安排，宿主用陈旧高帧 → 文字重叠（Bug 1 根因，原语 A）"
        )

        // 关键断言 B：异步 write-back 必须真正标记宿主重新布局。needsLayout 是
        // NSView 公开属性，是 `needsLayout = true` 原语的真实不可分副作用；
        // write-back 前已被反复清回 false。移除 resetLayout() 末尾的
        // `needsLayout = true` → write-back 不再标记 → 保持 false → 红。
        #if canImport(AppKit)
        #expect(
            view.needsLayout,
            "异步 math 回写未标记宿主重新布局（needsLayout 仍为 false）——宿主不会重新查询尺寸，用陈旧高帧 → 文字重叠（Bug 1 根因，原语 B）"
        )
        #endif
    }
}
