import Foundation

/// 异步渲染（SVG 代码块 / 数学公式）未命中分支的占位形态。
///
/// `MarkdownLabelView` 据调用入口翻转：
/// - `setMarkdown(_:)` → `.static`：未渲染期透明 attachment 占位（最小布局抖动）
/// - `appendMarkdown(_:)` → `.streaming`：未渲染期显示高亮源码（用户在看着 chunk 到达）
///
/// Async rendering placeholder mode for SVG code blocks / math formulas.
/// `MarkdownLabelView` flips this based on which entry point is called:
/// - `setMarkdown(_:)` → `.static`: transparent attachment placeholder until glyph arrives
/// - `appendMarkdown(_:)` → `.streaming`: keep highlighted source until glyph arrives
public enum PlaceholderMode: Sendable, Equatable {
    case `static`
    case streaming
}
