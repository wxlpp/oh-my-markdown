import Foundation
import MarkdownCore
import MarkdownRenderKit

private func firstChangedMarkdownBlockIndex(
    prevParsedBlocks: [ParsedBlockNode],
    newParsedBlocks: [ParsedBlockNode],
    prevBlocks: [BlockNode],
    newBlocks: [BlockNode]
)
    -> Int {
    let sharedCount = min(prevBlocks.count, newBlocks.count)
    for index in 0 ..< sharedCount {
        let prevParsed = index < prevParsedBlocks.count ? prevParsedBlocks[index] : nil
        let newParsed = index < newParsedBlocks.count ? newParsedBlocks[index] : nil
        if
            markdownBlocksMatch(
                prevParsed: prevParsed,
                newParsed: newParsed,
                prevBlock: prevBlocks[index],
                newBlock: newBlocks[index]
            ) == false {
            return index
        }
    }
    return sharedCount
}

private func markdownBlocksMatch(
    prevParsed: ParsedBlockNode?,
    newParsed: ParsedBlockNode?,
    prevBlock: BlockNode,
    newBlock: BlockNode
)
    -> Bool {
    if
        let prevFingerprint = prevParsed?.fingerprint,
        let newFingerprint = newParsed?.fingerprint {
        return prevFingerprint == newFingerprint
    }
    return prevBlock == newBlock
}

// MARK: - Copy: rendered selection → original Markdown source

/// Converts a UTF-8 byte offset into a `String.Index` without losing surrogate
/// pairs. Same correct form used by `MarkdownCore`'s internal `utf8Index(at:)`
/// (`String.Index(_:within:)` on the UTF-8 view), not a code-unit-by-code-unit
/// walk which would mis-handle multi-byte scalars.
///
/// Complexity: `String.UTF8View` is not random-access, so `utf8.index(_:offsetBy:)`
/// is O(byteOffset). On the copy path this is called exactly twice per copy
/// operation (once for lowerByte, once for upperByte) and is not a hot path —
/// the cost is intentionally accepted here; do not call in a loop or hot path.
private func utf8StringIndex(in source: String, at byteOffset: Int) -> String.Index? {
    guard byteOffset >= 0, byteOffset <= source.utf8.count else {
        return nil
    }
    let utf8 = source.utf8
    guard let scalarIndex = utf8.index(
        utf8.startIndex, offsetBy: byteOffset, limitedBy: utf8.endIndex
    ) else {
        return nil
    }
    return String.Index(scalarIndex, within: source)
}

/// Bug 4 — read-only copy must yield the *original Markdown source* the user
/// selected, not the rendered plain text (where math/image collapse to the
/// object-replacement char `\u{FFFC}` and tables lose their pipes).
///
/// Strategy (block-level granularity, first version): the rendered selection
/// `[selStart, selEnd)` is mapped to the set of blocks it overlaps via
/// `blockStarts` (the rendered char offset of each block's start, maintained in
/// `updateContent`/`applyDocument`). The returned string is the *continuous*
/// original-source substring from the first overlapped block's
/// `sourceRange.lowerBound` to the last overlapped block's
/// `sourceRange.upperBound` in `lastParsedSource` — the most faithful form
/// because it preserves the original inter-block text verbatim (`# `, `- `,
/// `$$…$$`, `![alt](url)`, `| a | b |`, blank-line separators, …).
///
/// Falls back to the rendered-plain-text substring when there is no usable
/// source mapping (e.g. blocks were set directly without a Markdown source),
/// so non-Markdown content still copies.
///
/// Known limitation: granularity is block-level. A selection touching any part
/// of a block expands to that block's full original source. Inline-precise
/// source extraction is intentionally out of scope for this first version; the
/// core guarantee — formulas/images/tables never lost — holds regardless.
private func markdownSourceForRenderedSelection(
    renderedRange: NSRange,
    renderedPlainText: String,
    blockStarts: [Int],
    parsedBlocks: [ParsedBlockNode],
    renderedLength: Int,
    originalSource: String
)
    -> String {
    func plainFallback() -> String {
        let ns = renderedPlainText as NSString
        let clamped = NSRange(
            location: min(renderedRange.location, ns.length),
            length: min(renderedRange.length, max(0, ns.length - renderedRange.location))
        )
        return ns.substring(with: clamped)
    }

    let selStart = renderedRange.location
    let selEnd = renderedRange.location + renderedRange.length
    guard selStart < selEnd, !blockStarts.isEmpty else {
        return plainFallback()
    }

    // Rendered span of block i is [blockStarts[i], blockStarts[i+1]) with the
    // last block running to renderedLength. A block is overlapped when its span
    // intersects [selStart, selEnd).
    var firstBlock: Int?
    var lastBlock: Int?
    for index in blockStarts.indices {
        let blockStart = blockStarts[index]
        let blockEnd = index + 1 < blockStarts.count ? blockStarts[index + 1] : renderedLength
        if blockStart < selEnd, selStart < blockEnd {
            if firstBlock == nil {
                firstBlock = index
            }
            lastBlock = index
        }
    }
    guard
        let lower = firstBlock,
        let upper = lastBlock,
        lower < parsedBlocks.count,
        upper < parsedBlocks.count else {
        return plainFallback()
    }

    // Continuous original-source span: first overlapped block's lowerBound to
    // last overlapped block's upperBound. Preserves original block separators.
    //
    // Known block-level limitation: if the first or last overlapped block has
    // `sourceRange == nil` (e.g. blocks injected via `setBlocks` without a
    // Markdown source), the *entire* selection — including any middle blocks that
    // do carry a sourceRange — falls back to rendered plain text (all-or-nothing,
    // determined by the boundary blocks). Per-block mixed restoration is deferred
    // to a future version.
    guard
        let lowerByte = parsedBlocks[lower].sourceRange?.lowerBound,
        let upperByte = parsedBlocks[upper].sourceRange?.upperBound,
        lowerByte <= upperByte,
        let startIndex = utf8StringIndex(in: originalSource, at: lowerByte),
        let endIndex = utf8StringIndex(in: originalSource, at: upperByte),
        startIndex <= endIndex else {
        return plainFallback()
    }
    return String(originalSource[startIndex ..< endIndex])
}

#if canImport(UIKit)
import UIKit

// MARK: - Helper types for UITextInput

final class MarkdownTextPosition: UITextPosition {
    init(_ offset: Int) {
        self.offset = offset
    }

    let offset: Int
}

final class MarkdownTextRange: UITextRange {
    init(from: Int, to: Int) {
        self._start = MarkdownTextPosition(from)
        self._end = MarkdownTextPosition(to)
    }

    override var start: UITextPosition {
        self._start
    }

    override var end: UITextPosition {
        self._end
    }

    override var isEmpty: Bool {
        self._start.offset == self._end.offset
    }

    var nsRange: NSRange {
        NSRange(location: self._start.offset, length: self._end.offset - self._start.offset)
    }

    private let _start: MarkdownTextPosition
    private let _end: MarkdownTextPosition
}

final class MarkdownSelectionRect: UITextSelectionRect {
    init(_ rect: CGRect) {
        self._rect = rect
    }

    override var rect: CGRect {
        self._rect
    }

    override var writingDirection: NSWritingDirection {
        .leftToRight
    }

    override var containsStart: Bool {
        false
    }

    override var containsEnd: Bool {
        false
    }

    override var isVertical: Bool {
        false
    }

    private let _rect: CGRect
}

// MARK: - MarkdownLabelView (iOS)

@MainActor
public final class MarkdownLabelView: UIView {
    // MARK: Init

    override public init(frame: CGRect) {
        super.init(frame: frame)
        self.buildStack()
        self.buildInteraction()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("Use init(frame:)")
    }

    // MARK: First responder

    override public var canBecomeFirstResponder: Bool {
        true
    }

    /// Return an empty view so the software keyboard never appears for this read-only view.
    override public var inputView: UIView? {
        UIView(frame: .zero)
    }

    override public var intrinsicContentSize: CGSize {
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: ceil(self.layoutManager.usageBoundsForTextContainer.height)
        )
    }

    public var renderStyle: RenderStyle = .default {
        didSet {
            guard !self.renderStyle.isSemanticallyEqual(to: oldValue) else {
                return
            }
            self._cachedRenderer = nil
            // Scroll overlays were built with the old style — discard them.
            self._tableOverlays.values.forEach { $0.scroll.removeFromSuperview() }
            self._tableOverlays.removeAll()
            self.updateContent()
        }
    }

    public var blocks: [BlockNode] = [] {
        didSet {
            guard !self._isIncrementalUpdate else {
                return
            }
            self.parsedBlocks = self.blocks.map { ParsedBlockNode(block: $0) }
            self.updateContent()
        }
    }

    // MARK: Copy action

    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(self.copy(_:)) {
            return !(self.layoutManager.textSelections.first?.textRanges.first?.isEmpty ?? true)
        }
        return false
    }

    @objc
    override public func copy(_ sender: Any?) {
        guard let copied = self._copiedStringForCurrentSelection() else {
            return
        }
        UIPasteboard.general.string = copied
    }

    /// Single source of truth for "current selection → copied original-source
    /// string": resolve the active TextKit2 selection, convert it to a
    /// rendered-plain-text offset range, and map that range back to the
    /// original Markdown source via `copyString`. Returns `nil` when there is
    /// no usable selection (no selection / empty range) so callers can no-op.
    /// Production `copy(_:)` writes the result to the pasteboard; the
    /// test seam returns it — keeping both paths on identical logic so they
    /// cannot drift.
    private func _copiedStringForCurrentSelection() -> String? {
        guard
            let sel = layoutManager.textSelections.first,
            let range = sel.textRanges.first,
            let str = contentStorage.attributedString?.string else {
            return nil
        }
        let start = self.contentStorage.offset(
            from: self.contentStorage.documentRange.location, to: range.location
        )
        let end = self.contentStorage.offset(
            from: self.contentStorage.documentRange.location, to: range.endLocation
        )
        guard start < end else {
            return nil
        }
        return self.copyString(
            forRenderedRange: NSRange(location: start, length: end - start),
            renderedPlainText: str
        )
    }

    /// Test-support: select the entire document. Headless tests have no
    /// UITextInteraction, so they drive `layoutManager.textSelections` through
    /// this internal seam instead of widening TextKit object visibility.
    func _selectEntireDocumentForTesting() {
        self.layoutManager.textSelections = [
            NSTextSelection(
                range: self.contentStorage.documentRange,
                affinity: .downstream,
                granularity: .character
            ),
        ]
    }

    /// Test-support: the original-source string that the production copy path
    /// (`copy(_:)`) would put on the pasteboard for the *current* selection,
    /// without touching the system pasteboard (avoids a global side effect /
    /// headless-CI flakiness). Shares the exact production
    /// selection→range→`copyString` logic via `_copiedStringForCurrentSelection`
    /// so the regression coverage is not narrowed. Mirrors the AppKit seam.
    func _copiedStringForCurrentSelectionForTesting() -> String {
        self._copiedStringForCurrentSelection() ?? ""
    }

    /// Test-support: the laid-out frame union of the block at `index` in the
    /// *main* TextKit 2 stack — i.e. the vertical space the block actually
    /// reserves in the document flow. Read-only forwarder to the private
    /// `decorations.blockFrameUnion`; mirrors `_selectEntireDocumentForTesting`.
    /// The observed quantity is driven by real TextKit2 layout (which depends
    /// on placeholder attachment bounds), not a decoupled counter.
    func _blockFrameUnionForTesting(at index: Int) -> CGRect? {
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        return self.decorations.blockFrameUnion(at: index)
    }

    /// Test-support: math-resolution state of the *actual* production-rendered
    /// string (`contentStorage.attributedString`, i.e. what is drawn).
    /// Read-only forwarder; mirrors `_blockFrameUnionForTesting`.
    ///
    /// `mathSourceCount` = residual unresolved-math placeholders;
    /// `attachmentCount` = resolved math glyphs spliced in as attachments.
    /// After streaming settles, a fully math-resolved document has
    /// `mathSourceCount == 0` and `attachmentCount == <#math spans>`. If the
    /// async math glyph write-back fails to survive `resetLayout()`'s renderer
    /// recreation (Bug 1 math sub-symptom), `renderMath` keeps missing the
    /// cache → placeholders keep reappearing → these counts oscillate / never
    /// reach the resolved form. This is the true, undecoupled signal for "did
    /// the resolved math survive renderer recreation" — distinct from the
    /// separately-guarded TextKit2 relayout-timing concern.
    func _renderedMathStateForTesting() -> (mathSourceCount: Int, attachmentCount: Int) {
        guard let str = self.contentStorage.attributedString else {
            return (0, 0)
        }
        var srcCount = 0
        var attachCount = 0
        let full = NSRange(location: 0, length: str.length)
        str.enumerateAttribute(.markdownMathSource, in: full) { v, _, _ in
            if v is String { srcCount += 1 }
        }
        str.enumerateAttribute(.attachment, in: full) { v, _, _ in
            if v != nil { attachCount += 1 }
        }
        return (srcCount, attachCount)
    }

    /// 测试钩子：枚举 `.markdownSVGBlockSource` 未解析占位与 `.attachment` 数量。
    /// 镜像 `_renderedMathStateForTesting`，是「已解析 svg 是否熬过 renderer 重建」
    /// 的无解耦直读信号（看 view 真正绘制的串）。
    func _renderedSVGBlockStateForTesting() -> (markerCount: Int, attachmentCount: Int) {
        guard let str = self.contentStorage.attributedString else {
            return (0, 0)
        }
        var markerCount = 0
        var attachCount = 0
        let full = NSRange(location: 0, length: str.length)
        str.enumerateAttribute(.markdownSVGBlockSource, in: full) { v, _, _ in
            if v is String { markerCount += 1 }
        }
        str.enumerateAttribute(.attachment, in: full) { v, _, _ in
            if v != nil { attachCount += 1 }
        }
        return (markerCount, attachCount)
    }

    /// 测试钩子：读取第一个 svg 渲染 attachment 的 image 尺寸（用于 R1→R2
    /// swap 测试 —— 不同 renderer 配置不同 stub size，验证 swap 后 attachment
    /// 真的换成新 renderer 输出。返回 nil 表示还没解析为 attachment。
    func _firstSVGAttachmentImageSizeForTesting() -> CGSize? {
        guard let str = self.contentStorage.attributedString else { return nil }
        var found: CGSize?
        let full = NSRange(location: 0, length: str.length)
        str.enumerateAttribute(.attachment, in: full) { value, _, stop in
            if let a = value as? NSTextAttachment, let img = a.image {
                found = img.size
                stop.pointee = true
            }
        }
        return found
    }

    /// Maps a rendered selection range to the original Markdown source it
    /// covers (block-level). Shared between platforms via the file-scope
    /// `markdownSourceForRenderedSelection`.
    func copyString(forRenderedRange range: NSRange, renderedPlainText: String) -> String {
        markdownSourceForRenderedSelection(
            renderedRange: range,
            renderedPlainText: renderedPlainText,
            blockStarts: self.blockStarts,
            parsedBlocks: self.parsedBlocks,
            renderedLength: self._liveString.length,
            originalSource: self.lastParsedSource
        )
    }

    // MARK: Layout

    override public func layoutSubviews() {
        super.layoutSubviews()
        self.highlightContainerView.frame = bounds
        if abs(self.textContainer.size.width - bounds.width) > 0.5 {
            self.resetLayout()
        } else {
            // Ensure layout is fully computed before querying fragment positions for overlays.
            self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
            let startIndex = self._pendingTableOverlaySyncStart ?? 0
            self._pendingTableOverlaySyncStart = nil
            self._syncTableOverlays(from: startIndex)
        }
    }

    override public func sizeThatFits(_ size: CGSize) -> CGSize {
        let targetWidth = max(size.width, 1)
        // Fast path: width unchanged — ensureLayout is a no-op if layout is already valid.
        if abs(self.textContainer.size.width - targetWidth) < 0.5 {
            self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
            return CGSize(
                width: size.width,
                height: ceil(self.layoutManager.usageBoundsForTextContainer.height)
            )
        }
        // Different width: measure at proposed width, then restore the real width.
        // layoutSubviews will call resetLayout at the actual bounds width when needed,
        // so we avoid a gratuitous second ensureLayout here.
        let prev = self.textContainer.size.width
        self.textContainer.size = CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        let h = ceil(layoutManager.usageBoundsForTextContainer.height)
        self.textContainer.size = CGSize(width: prev, height: .greatestFiniteMagnitude)
        return CGSize(width: size.width, height: h)
    }

    // MARK: Drawing

    override public func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else {
            return
        }
        self.decorations.drawAll(blocks: self.blocks, in: ctx)
        self.layoutManager.enumerateTextLayoutFragments(
            from: self.layoutManager.documentRange.location,
            options: [.ensuresLayout, .ensuresExtraLineFragment]
        ) { fragment in
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: ctx)
            return true
        }
    }

    // MARK: Streaming

    public func setMarkdown(_ source: String) {
        // 完整重置 → 静态首屏。cache-miss 形态由 renderer 看 `.static` 出透明 attachment。
        self.renderMode = .static
        self._parseSerial += 1
        self._parseTask?.cancel()
        self._parseTask = nil
        self._pendingParseAfterCurrent = false
        self.streamingSource = source
        self.scheduleParse(delayNanoseconds: 0)
    }

    public func appendMarkdown(_ chunk: String) {
        // 增量流式 → 保持既有 streaming 行为，cache-miss 显示源码占位。
        self.renderMode = .streaming
        self.streamingSource += chunk
        self.scheduleParse(delayNanoseconds: 50_000_000)
    }

    // MARK: TextKit 2 stack (internal – UITextInput extension reads them)

    let contentStorage = NSTextContentStorage()
    let layoutManager = NSTextLayoutManager()
    let textContainer = NSTextContainer(
        size: CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    )

    // MARK: Location helpers

    var documentLength: Int {
        self.contentStorage.offset(
            from: self.contentStorage.documentRange.location,
            to: self.contentStorage.documentRange.endLocation
        )
    }

    func updateContent() {
        let renderer = self.cachedRenderer
        let result = NSMutableAttributedString()
        var starts: [Int] = []
        for (index, block) in self.blocks.enumerated() {
            if index > 0 {
                result.append(renderer.separator)
            }
            starts.append(result.length)
            result.append(renderer.renderBlock(block))
        }
        self.blockStarts = starts
        self._liveString = result
        self.contentStorage.performEditingTransaction {
            self.contentStorage.attributedString = self._liveString
        }
        self.resetLayout()
        self.triggerImageLoads(in: NSRange(location: 0, length: self._liveString.length))
        self.triggerMathLoads(in: NSRange(location: 0, length: self._liveString.length))
        self.triggerSVGBlockLoads(in: NSRange(location: 0, length: self._liveString.length))
    }

    func offsetOf(_ location: any NSTextLocation) -> Int {
        self.contentStorage.offset(from: self.contentStorage.documentRange.location, to: location)
    }

    func locationAt(_ offset: Int) -> (any NSTextLocation)? {
        self.contentStorage.location(self.contentStorage.documentRange.location, offsetBy: offset)
    }

    func makeTextRange(from: Int, to: Int) -> NSTextRange? {
        guard let s = locationAt(from), let e = locationAt(to) else {
            return nil
        }
        return NSTextRange(location: s, end: e)
    }

    private var _isIncrementalUpdate = false

    /// Receives the system `highlightView` as a subview. Inserted at index 0
    /// so it sits below the main view's `draw(_:)` content in z-order.
    private let highlightContainerView = UIView()

    /// Bundles long-press selection, handle dragging, and Copy/Share menu (no keyboard).
    private var textInteraction: UITextInteraction!

    private var streamingSource = ""
    private var lastParsedSource = ""
    private var parsedBlocks: [ParsedBlockNode] = []
    // Cached renderer — invalidated when renderStyle or available width changes.
    private var _cachedRenderer: AttributedStringRenderer?
    private var _cachedRendererWidth: CGFloat = 0
    /// 占位 mode 跟踪：`setMarkdown` 翻 `.static`、`appendMarkdown` 翻 `.streaming`。
    /// 传给 `AttributedStringRenderer.init(...)` 决定 cache-miss 占位形态（透明 vs 源码）。
    /// 默认 `.static`（构造时空内容场景）。
    /// `_cachedRenderer.placeholderMode` 是 `let`，因此 mode 真正翻转时必须把
    /// `_cachedRenderer` 清掉，下次 `cachedRenderer` 取值会用新 mode 重建。
    /// Tracks placeholder mode; flipped by setMarkdown/appendMarkdown.
    /// `public internal(set)`: tests read, only the module writes.
    public internal(set) var renderMode: PlaceholderMode = .static {
        didSet {
            if oldValue != self.renderMode {
                // mode 翻转 → cached renderer 的 placeholderMode 是 let，必须重建。
                self._cachedRenderer = nil
            }
        }
    }
    /// Canonical mutable store — avoids O(n) mutableCopy() per streaming token.
    private var _liveString = NSMutableAttributedString()
    /// Last measured intrinsic height — gates invalidateIntrinsicContentSize() calls.
    private var _lastHeight: CGFloat = 0
    /// Coalesces expensive TextKit height queries during streaming updates.
    private var _heightUpdateTask: Task<Void, Never>?
    /// Test-only monotonic counter incremented as the *first line* of
    /// `scheduleDeferredHeightUpdate()` itself, so "counter++" and "that primitive
    /// was actually invoked" are one indivisible semantic — there is no decoupled
    /// bypass. If a caller (e.g. `resetLayout()` on the async write-back path) stops
    /// invoking `scheduleDeferredHeightUpdate()`, this counter cannot advance, so a
    /// regression test bound to it necessarily turns red. The deferred task auto-nils
    /// after ~33ms so a transient flag would race, hence a durable counter. Zero
    /// production behavior beyond an Int increment at the primitive's entry.
    var _deferredHeightScheduleCount = 0
    /// In-flight parse task. Streaming keeps this single-flight so large documents do not
    /// accumulate cancelled full-document parses as tokens arrive.
    private var _parseTask: Task<Void, Never>?
    private var _parseSerial = 0
    private var _pendingParseAfterCurrent = false
    /// In-memory image cache keyed by source URL string.
    private var _imageCache: [String: UIImage] = [:]
    /// Source URLs currently being fetched (prevents duplicate requests).
    private var _imageLoading: Set<String> = []
    /// Platform-agnostic async math render coordinator (dedup/三态/代际).
    /// View-private by default to keep test isolation (each MarkdownLabelView
    /// 自带独立 coordinator，避免不同 test 的 setRenderer 互相清 cache)。需要
    /// 跨 view 共享 cache 的调用方可显式注入 `MathLoadCoordinator.shared`。
    private let _mathCoordinator = MathLoadCoordinator()
    /// View-held math glyph cache / raster scale / renderer generation —
    /// the **canonical store** for async math write-back, mirroring
    /// `_imageCache`. The transient `_cachedRenderer` is discarded by
    /// `resetLayout()` whenever `bounds.width` changes (streaming churn);
    /// keeping math state on the view (and re-seeding it into every freshly
    /// built renderer in `cachedRenderer`) is what makes resolved glyphs
    /// survive renderer recreation — exactly as `_imageCache` already does.
    private var _mathCache: [MathCacheKey: MathRenderedGlyph] = [:]
    private var _mathRasterScale: CGFloat = 1
    private var _mathRendererGeneration: Int = 0
    /// Injected math renderer; swapping it bumps the coordinator's generation.
    public var mathRenderer: (any MathRendering)? {
        // setRenderer 异步派发；落地前发生的渲染会显示 latex 占位，并在下次
        // updateContent/relayout 时解析（有意为之的最终一致性）。
        didSet { Task { await self._mathCoordinator.setRenderer(self.mathRenderer) } }
    }
    /// Platform-agnostic async ```svg block render coordinator (dedup/三态/代际).
    /// View-private by default to keep test isolation (each MarkdownLabelView
    /// 自带独立 coordinator，避免不同 test 的 setRenderer 互相清 cache)。需要
    /// 跨 view 共享 cache 的调用方可显式注入 `SVGBlockLoadCoordinator.shared`。
    private let _svgBlockCoordinator = SVGBlockLoadCoordinator()
    /// View-held svg-block glyph cache / raster scale / renderer generation —
    /// the **canonical store** for async svg write-back, mirroring `_mathCache`
    /// discipline. The transient `_cachedRenderer` is discarded by `resetLayout()`
    /// on width churn; keeping svg state on the view (and re-seeding it into
    /// every freshly built renderer in `cachedRenderer`) is what makes resolved
    /// svg images survive renderer recreation — identical to `_mathCache`.
    private var _svgBlockCache: [SVGBlockCacheKey: SVGBlockGlyph] = [:]
    private var _svgRasterScale: CGFloat = 1
    private var _svgBlockRendererGeneration: Int = 0
    /// Injected ```svg block renderer; swapping it bumps the coordinator's generation.
    public var svgBlockRenderer: (any SVGBlockRendering)? {
        // didSet 行为契约：
        // 1) 异步把 renderer 推给 coordinator（gen bump + 清协调器自身的 caches）。
        // 2) 在 coordinator 落地**之后**回到 MainActor 做后续：
        //    - nil 分支：清 view-held + transient renderer 的 svg cache（让
        //      已渲染 svg 立刻降级回高亮源码，匹配 .svgRenderer(nil) 的
        //      「disable」文档契约——Copilot PR #5 R4 #1）。
        //    - 任何分支：触发一次 updateContent 让 triggerSVGBlockLoads 在
        //      新 renderer 下重新派发；解决 nil→非nil 时源串不变 → representable
        //      早 return 不调 setMarkdown → svg 永停 marker 的死锁（Copilot
        //      PR #5 R7 #1 + suppressed）。先 await setRenderer 再 updateContent
        //      可避免 triggerSVGBlockLoads 抢在 setRenderer 之前用旧 coordinator
        //      状态派发并被随后的 setRenderer drop 的竞态。
        didSet {
            Task { [weak self] in
                guard let self else { return }
                await self._svgBlockCoordinator.setRenderer(self.svgBlockRenderer)
                await MainActor.run {
                    // **任何 renderer 变更**都失效 view-held svg cache：
                    // - nil 分支：原 R4 #1 disable 契约要求清 cache 让已渲染
                    //   svg 降级回高亮源码 + marker。
                    // - 非 nil→非 nil swap：若不清，已 attachment 的 svg 会
                    //   继续命中旧 cache（view-held _svgBlockRendererGeneration
                    //   仍是旧值），renderSVGBlock 直接输出 attachment 而非
                    //   marker，triggerSVGBlockLoads 枚举不到 marker → 新
                    //   renderer 永不派发 → renderer swap 不真正生效
                    //   （Copilot PR #5 R8 #1 + suppressed）。
                    // 清 cache 后 updateContent 让所有 svg 走 miss→marker→
                    // 新 coordinator 派发→回写链路；任何 renderer 切换都生效。
                    self._svgBlockCache.removeAll()
                    self._cachedRenderer?.svgBlockCache.removeAll()
                    self.updateContent()
                }
            }
        }
    }
    /// Horizontal-scroll overlays for table blocks wider than the view, keyed by block index.
    private var _tableOverlays: [Int: (
        scroll: UIScrollView,
        content: TableContentView,
        block: BlockNode,
        naturalWidth: CGFloat
    )] = [:]
    private var _pendingTableOverlaySyncStart: Int?
    /// Set by UITextInteraction so it can be notified of selection changes.
    private weak var _inputDelegate: (any UITextInputDelegate)?

    // MARK: Content

    private var blockStarts: [Int] = []

    private var cachedRenderer: AttributedStringRenderer {
        let w = max(bounds.width, 1)
        if self._cachedRenderer == nil || abs(w - self._cachedRendererWidth) > 0.5 {
            var renderer = AttributedStringRenderer(
                style: renderStyle, availableWidth: w, placeholderMode: self.renderMode)
            renderer.imageCache = self._imageCache
            // Re-seed view-held math state so resolved glyphs survive the
            // renderer recreation `resetLayout()` performs on width churn
            // (identical discipline to `imageCache` above).
            renderer.mathCache = self._mathCache
            renderer.mathRasterScale = self._mathRasterScale
            renderer.mathRendererGeneration = self._mathRendererGeneration
            // 同款 svg 重播种：让解析后的 svg 字形熬过 width churn 引发的 renderer 重建。
            renderer.svgBlockCache = self._svgBlockCache
            renderer.svgRasterScale = self._svgRasterScale
            renderer.svgRendererGeneration = self._svgBlockRendererGeneration
            self._cachedRenderer = renderer
            self._cachedRendererWidth = w
        }
        return self._cachedRenderer!
    }

    private var decorations: MarkdownLabelDecorations {
        MarkdownLabelDecorations(
            style: self.renderStyle,
            bounds: bounds,
            layoutManager: self.layoutManager,
            contentStorage: self.contentStorage,
            liveString: self._liveString,
            blockStarts: self.blockStarts
        )
    }

    // MARK: Setup

    private func buildStack() {
        self.textContainer.lineFragmentPadding = 0
        self.textContainer.widthTracksTextView = false
        self.layoutManager.textContainer = self.textContainer
        self.contentStorage.addTextLayoutManager(self.layoutManager)
        // Seed backing store so textStorage is always non-nil.
        self.contentStorage.attributedString = NSAttributedString(string: "")
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        // Insert the highlight container as the bottommost subview.
        // UITextSelectionDisplayInteraction will place highlightView here,
        // keeping selection highlights visually below draw(_:) text content.
        self.highlightContainerView.isUserInteractionEnabled = false
        insertSubview(self.highlightContainerView, at: 0)
    }

    private func buildInteraction() {
        // UITextInteraction(for: .nonEditable) provides long-press selection,
        // handle dragging, and the Copy/Share/Look Up context menu automatically.
        // It does NOT trigger the software keyboard.
        self.textInteraction = UITextInteraction(for: .nonEditable)
        self.textInteraction.textInput = self
        addInteraction(self.textInteraction)
        // Tap recognizer for link activation / selection dismissal.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    private func resetLayout() {
        let w = max(bounds.width, 1)
        self.textContainer.size = CGSize(width: w, height: .greatestFiniteMagnitude)
        // If the renderer was built for a different width, re-render now so tab stops are correct.
        if abs(w - self._cachedRendererWidth) > 0.5 {
            self._cachedRenderer = nil // force re-creation with the correct width
            self.updateContent() // re-renders and calls resetLayout again with matching width
            return
        }
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        self._heightUpdateTask?.cancel()
        self._heightUpdateTask = nil
        self._lastHeight = ceil(self.layoutManager.usageBoundsForTextContainer.height)
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
        // Mirror applyDocument's host-relayout discipline: async write-back paths
        // (image/math glyph resolution → updateContent → resetLayout) can shrink
        // content dramatically. invalidateIntrinsicContentSize() alone does not make
        // the SwiftUI host re-query our size, so request a host layout pass and a
        // deferred height re-measure exactly as the streaming incremental path does.
        setNeedsLayout()
        self.scheduleDeferredHeightUpdate()
        self._pendingTableOverlaySyncStart = nil
        self._syncTableOverlays(from: 0)
    }

    private func scheduleDeferredHeightUpdate() {
        // Counter is bumped here, at the primitive's entry, so it is indivisible
        // from "scheduleDeferredHeightUpdate() was actually invoked" (see decl).
        self._deferredHeightScheduleCount += 1
        guard self._heightUpdateTask == nil else {
            return
        }
        self._heightUpdateTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 33_000_000)
            } catch {
                return
            }
            self?.updateMeasuredHeightIfNeeded()
        }
    }

    private func updateMeasuredHeightIfNeeded() {
        self._heightUpdateTask = nil
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        let newHeight = ceil(layoutManager.usageBoundsForTextContainer.height)
        if abs(newHeight - self._lastHeight) > 0.5 {
            self._lastHeight = newHeight
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    private func scheduleParse(delayNanoseconds: UInt64) {
        guard self._parseTask == nil else {
            self._pendingParseAfterCurrent = true
            return
        }
        let serial = self._parseSerial
        self._parseTask = Task {
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    self.finishParseTask(serial: serial)
                    return
                }
            }
            guard !Task.isCancelled, serial == self._parseSerial else {
                self.finishParseTask(serial: serial)
                return
            }
            let source = self.streamingSource
            let prevBlocks = self.blocks
            let prevParsedBlocks = self.parsedBlocks
            let prevSource = self.lastParsedSource
            let prevStarts = self.blockStarts
            let newDocument = await Task.detached(priority: .userInitiated) {
                MarkdownDocument(parsedBlocks: prevParsedBlocks)
                    .parsingAppend(to: source, previousSource: prevSource)
            }.value
            guard !Task.isCancelled, serial == self._parseSerial else {
                self.finishParseTask(serial: serial)
                return
            }
            self.applyDocument(
                newDocument,
                source: source,
                prevBlocks: prevBlocks,
                prevParsedBlocks: prevParsedBlocks,
                prevStarts: prevStarts
            )
            let needsFollowUp = self._pendingParseAfterCurrent || self.streamingSource != source
            self.finishParseTask(serial: serial)
            if needsFollowUp {
                self._pendingParseAfterCurrent = false
                self.scheduleParse(delayNanoseconds: 50_000_000)
            }
        }
    }

    private func finishParseTask(serial: Int) {
        guard serial == self._parseSerial else {
            return
        }
        self._parseTask = nil
    }

    /// Applies a newly parsed block array. Must be called on MainActor.
    private func applyDocument(
        _ document: MarkdownDocument,
        source: String,
        prevBlocks: [BlockNode],
        prevParsedBlocks: [ParsedBlockNode],
        prevStarts: [Int]
    ) {
        let newBlocks = document.blocks
        let newParsedBlocks = document.parsedBlocks
        self.parsedBlocks = document.parsedBlocks
        self.lastParsedSource = source

        let firstChanged = firstChangedMarkdownBlockIndex(
            prevParsedBlocks: prevParsedBlocks,
            newParsedBlocks: newParsedBlocks,
            prevBlocks: prevBlocks,
            newBlocks: newBlocks
        )
        guard firstChanged < prevBlocks.count || firstChanged < newBlocks.count else {
            return
        }

        self._isIncrementalUpdate = true
        self.blocks = newBlocks
        self._isIncrementalUpdate = false

        // Character offset in the attributed string where the stable prefix ends
        // (just before the separator that precedes block[firstChanged]).
        let stablePrefixLen: Int = if firstChanged == 0 {
            0
        } else if firstChanged < prevStarts.count {
            prevStarts[firstChanged] - 1
        } else {
            self._liveString.length
        }

        // Render only the changed suffix.
        let renderer = self.cachedRenderer
        let sep = renderer.separator
        let suffix = NSMutableAttributedString()
        var newExtraStarts: [Int] = []
        var pos = stablePrefixLen
        for (offset, block) in newBlocks[firstChanged...].enumerated() {
            if firstChanged + offset > 0 {
                suffix.append(sep)
                pos += sep.length
            }
            newExtraStarts.append(pos)
            let rendered = renderer.renderBlock(block)
            suffix.append(rendered)
            pos += rendered.length
        }
        self.blockStarts = Array(prevStarts.prefix(firstChanged)) + newExtraStarts

        // Splice directly into the canonical mutable store — avoids O(n) mutableCopy() per token.
        self._liveString.replaceCharacters(
            in: NSRange(location: stablePrefixLen, length: self._liveString.length - stablePrefixLen),
            with: suffix
        )
        self.contentStorage.performEditingTransaction {
            self.contentStorage.attributedString = self._liveString
        }

        // Re-layout and redraw only the changed region.
        self.textContainer.size = CGSize(width: max(bounds.width, 1), height: .greatestFiniteMagnitude)
        // Scope ensureLayout to the changed suffix instead of the entire document.
        let docEnd = self.layoutManager.documentRange.endLocation
        let layoutStart: NSTextLocation = if stablePrefixLen > 0, let loc = locationAt(stablePrefixLen) {
            loc
        } else {
            self.layoutManager.documentRange.location
        }
        if let layoutRange = NSTextRange(location: layoutStart, end: docEnd) {
            self.layoutManager.ensureLayout(for: layoutRange)
        }
        self.scheduleDeferredHeightUpdate()
        // Find the Y of the first changed fragment; reuse layoutStart (no extra ensureLayout pass).
        var dirtyY: CGFloat = 0
        if stablePrefixLen > 0 {
            self.layoutManager.enumerateTextLayoutFragments(from: layoutStart, options: []) { frag in
                dirtyY = frag.layoutFragmentFrame.minY
                return false
            }
        }
        setNeedsDisplay(CGRect(
            x: 0,
            y: dirtyY,
            width: bounds.width,
            height: bounds.height - dirtyY
        ))
        self._pendingTableOverlaySyncStart = min(self._pendingTableOverlaySyncStart ?? firstChanged, firstChanged)
        setNeedsLayout()
        self.triggerImageLoads(in: NSRange(location: stablePrefixLen, length: suffix.length))
        self.triggerMathLoads(in: NSRange(location: stablePrefixLen, length: suffix.length))
        self.triggerSVGBlockLoads(in: NSRange(location: stablePrefixLen, length: suffix.length))
    }

    // MARK: Link tap

    @objc
    private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard
            gesture.state == .ended,
            let str = contentStorage.attributedString else {
            return
        }
        let point = gesture.location(in: self)
        guard
            let pos = closestPosition(to: point) as? MarkdownTextPosition,
            pos.offset < documentLength else {
            return
        }
        let attrs = str.attributes(at: pos.offset, effectiveRange: nil)
        let url: URL? = if let u = attrs[.link] as? URL {
            u
        } else if let s = attrs[.link] as? String {
            URL(string: s)
        } else {
            nil
        }
        if let url {
            UIApplication.shared.open(url)
        }
        // Tap on non-link text clears any active selection.
        if url == nil, !self.layoutManager.textSelections.isEmpty {
            self._inputDelegate?.selectionWillChange(self)
            self.layoutManager.textSelections = []
            self._inputDelegate?.selectionDidChange(self)
            setNeedsDisplay()
        }
    }

    // MARK: Image loading

    private func triggerImageLoads(in range: NSRange) {
        guard let str = contentStorage.attributedString else {
            return
        }
        let safeRange = range.clamped(to: str.length)
        guard safeRange.length > 0 else {
            return
        }
        str.enumerateAttribute(
            .markdownImageSource,
            in: safeRange
        ) { value, _, _ in
            guard
                let source = value as? String,
                !_imageLoading.contains(source),
                _imageCache[source] == nil else {
                return
            }
            self._imageLoading.insert(source)
            self.loadImage(source: source)
        }
    }

    private func loadImage(source: String) {
        guard let url = URL(string: source) else {
            self._imageLoading.remove(source)
            return
        }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) {
                    self.finishImageLoad(source: source, image: image)
                } else {
                    self.finishImageLoadFailure(source: source)
                }
            } catch {
                self.finishImageLoadFailure(source: source)
            }
        }
    }

    private func finishImageLoad(source: String, image: UIImage) {
        self._imageCache[source] = image
        _ = self._imageLoading.remove(source)
        self._cachedRenderer?.imageCache[source] = image
        self.updateContent()
    }

    private func finishImageLoadFailure(source: String) {
        _ = self._imageLoading.remove(source)
    }

    // MARK: Math loading

    private func triggerMathLoads(in range: NSRange) {
        guard self.mathRenderer != nil, let str = contentStorage.attributedString else {
            return
        }
        let safe = range.clamped(to: str.length)
        guard safe.length > 0 else {
            return
        }
        let scale = self.window?.screen.scale ?? UIScreen.main.scale
        // 同步枚举收集原始请求（latex/display/color/pt），代际相关的 key 构造
        // 推迟到下面那个唯一的 Task 内一次性完成（generation 受 actor 隔离）。
        var raw: [(latex: String, display: Bool, color: PlatformColor, pt: CGFloat)] = []
        str.enumerateAttribute(.markdownMathSource, in: safe) { value, _, _ in
            guard
                let payload = value as? String,
                let sep = payload.firstIndex(of: "\u{1F}") else {
                return
            }
            let display = payload[payload.startIndex] == "1"
            let latex = String(payload[payload.index(after: sep)...])
            let color = self.renderStyle.mathColorOverride ?? self.renderStyle.textColor
            let pt = MathMetrics.effectivePointSize(
                textPointSize: self.renderStyle.bodyFont.pointSize,
                mathScale: self.renderStyle.mathScale
            )
            raw.append((latex: latex, display: display, color: color, pt: pt))
        }
        guard !raw.isEmpty else {
            return
        }
        Task { [weak self] in
            guard let self else {
                return
            }
            // 一次读取代际，用同一 gen 构造所有 key（保持与原实现一致的键公式）。
            let gen = await self._mathCoordinator.generation
            let requests: [(key: MathCacheKey, latex: String, display: Bool,
                            color: PlatformColor, pt: CGFloat)] = raw.map {
                let key = MathCacheKey(
                    latex: $0.latex, display: $0.display, pointSize: $0.pt,
                    colorHex: MathMetrics.colorHex($0.color),
                    rasterScale: scale, rendererGeneration: gen
                )
                return (key: key, latex: $0.latex, display: $0.display,
                        color: $0.color, pt: $0.pt)
            }
            // 先派发全部渲染（去重由 coordinator 负责）。
            for r in requests {
                await self._mathCoordinator.loadIfNeeded(
                    key: r.key, latex: r.latex, display: r.display,
                    pointSize: r.pt, scale: scale, color: r.color
                )
            }
            // 仅 await 各自 key 的在途任务，收集解析出的字形。
            var resolved: [(key: MathCacheKey, glyph: MathRenderedGlyph)] = []
            for r in requests {
                if let glyph = await self._mathCoordinator.awaitGlyph(for: r.key) {
                    resolved.append((key: r.key, glyph: glyph))
                }
            }
            guard !resolved.isEmpty else {
                return
            }
            // 一次性合并回写并仅触发一次 updateContent（镜像图片加载纪律）。
            await MainActor.run {
                // 真值源是 view-held store —— resetLayout() 在宽度抖动时会
                // 丢弃 _cachedRenderer，下次 cachedRenderer 重建会从这里
                // 重播种；同时也写当前 transient renderer（与
                // finishImageLoad 同时写 _imageCache 与 _cachedRenderer?
                // 完全同构）。
                self._mathRasterScale = scale
                self._mathRendererGeneration = gen
                self._cachedRenderer?.mathRasterScale = scale
                self._cachedRenderer?.mathRendererGeneration = gen
                for entry in resolved {
                    self._mathCache[entry.key] = entry.glyph
                    self._cachedRenderer?.mathCache[entry.key] = entry.glyph
                }
                self.updateContent()
            }
        }
    }

    // MARK: SVG block loading

    private func triggerSVGBlockLoads(in range: NSRange) {
        guard self.svgBlockRenderer != nil, let str = contentStorage.attributedString else {
            return
        }
        let safe = range.clamped(to: str.length)
        guard safe.length > 0 else {
            return
        }
        let scale = self.window?.screen.scale ?? UIScreen.main.scale
        // 与 renderSVGBlock 共用同一宽度：renderSVGBlock 的 lookup key 走
        // self.cachedRenderer.availableWidth（renderer 持有），而 cachedRenderer
        // 只在 |Δw|>0.5pt 时才重建。若 trigger 直接用 max(bounds.width,1)，
        // 在 <0.5pt 抖动下 trigger 写入的 key 与 lookup 用的 key 不一致 →
        // 已解析 svg 永远 cache miss → marker 永留（Copilot PR #5 R5 #1）。
        // math 不受影响：MathCacheKey 不含 availableWidth。
        let availableWidth = self.cachedRenderer.availableWidth
        // 同步枚举收集 svg 源串。代际相关的 key 构造推迟到下面唯一的 Task 内一次性
        // 完成（generation 受 actor 隔离），与 triggerMathLoads 同形。
        // 注：enumerateAttribute 对相同 value 的 .markdownSVGBlockSource 合并成单次
        // 回调（Foundation 文档：returns the maximum range over which the value applies），
        // 故每个 svg block 自然只产一项，无需 Set 去重（详见 SVGBlockRenderTests
        // missEnumerationCoalescesSameValue —— Copilot PR #5 R3 #2/#3 假设不成立）。
        var svgs: [String] = []
        str.enumerateAttribute(.markdownSVGBlockSource, in: safe) { value, _, _ in
            guard let payload = value as? String else { return }
            svgs.append(payload)
        }
        guard !svgs.isEmpty else {
            return
        }
        Task { [weak self] in
            guard let self else {
                return
            }
            let gen = await self._svgBlockCoordinator.generation
            let requests: [(key: SVGBlockCacheKey, svg: String)] = svgs.map { svg in
                (key: SVGBlockCacheKey(
                    svg: svg, availableWidth: availableWidth,
                    rasterScale: scale, rendererGeneration: gen
                ), svg: svg)
            }
            for r in requests {
                await self._svgBlockCoordinator.loadIfNeeded(
                    key: r.key, svg: r.svg, availableWidth: availableWidth, scale: scale
                )
            }
            var resolved: [(key: SVGBlockCacheKey, glyph: SVGBlockGlyph)] = []
            for r in requests {
                if let glyph = await self._svgBlockCoordinator.awaitGlyph(for: r.key) {
                    resolved.append((key: r.key, glyph: glyph))
                }
            }
            guard !resolved.isEmpty else {
                return
            }
            await MainActor.run {
                // 真值源是 view-held store（与 _mathCache 同款）—— resetLayout()
                // 在宽度抖动时丢弃 _cachedRenderer，下次 cachedRenderer 重建会从
                // 这里重播种；同时也写当前 transient renderer。
                self._svgRasterScale = scale
                self._svgBlockRendererGeneration = gen
                self._cachedRenderer?.svgRasterScale = scale
                self._cachedRenderer?.svgRendererGeneration = gen
                for entry in resolved {
                    self._svgBlockCache[entry.key] = entry.glyph
                    self._cachedRenderer?.svgBlockCache[entry.key] = entry.glyph
                }
                self.updateContent()
            }
        }
    }

    // MARK: Table overlay helpers (iOS)

    private func _tableNaturalWidth(at blockIndex: Int) -> CGFloat {
        self.decorations.tableNaturalWidth(at: blockIndex)
    }

    /// Creates, repositions, or removes UIScrollView overlays for tables that overflow the view width.
    private func _syncTableOverlays(from startIndex: Int) {
        let startIndex = max(0, min(startIndex, blocks.count))
        // Remove overlays whose index no longer corresponds to a table block.
        let stale = self._tableOverlays.keys.filter { i -> Bool in
            guard i >= startIndex else {
                return false
            }
            guard i < self.blocks.count, case .table = self.blocks[i] else {
                return true
            }
            return false
        }
        for i in stale {
            self._tableOverlays[i]?.scroll.removeFromSuperview()
            self._tableOverlays.removeValue(forKey: i)
        }

        let viewWidth = bounds.width
        guard startIndex < self.blocks.count else {
            return
        }

        // The reserved height in the main stack is already correct by
        // construction: `AttributedStringRenderer.overflowTablePlaceholder` and
        // the overlay's `TableContentView` both size off the *same*
        // `TableMeasurement.height` call, so there is no write-back and no
        // convergence pass — this loop only positions/sizes the overlay against
        // the (already-correct) reserved geometry from `blockFrameUnion`.
        for i in startIndex ..< self.blocks.count {
            let block = self.blocks[i]
            guard case .table = block else {
                if let o = _tableOverlays[i] {
                    o.scroll.removeFromSuperview()
                    self._tableOverlays.removeValue(forKey: i)
                }
                continue
            }
            let naturalWidth = self._tableNaturalWidth(at: i)
            guard naturalWidth > viewWidth + 0.5 else {
                // Table fits — remove any stale overlay.
                if let o = _tableOverlays[i] {
                    o.scroll.removeFromSuperview()
                    self._tableOverlays.removeValue(forKey: i)
                }
                continue
            }
            guard
                let blockFrame = decorations.blockFrameUnion(at: i),
                !blockFrame.isNull, blockFrame.height > 0 else {
                continue
            }

            if let existing = _tableOverlays[i], existing.block == block {
                // Identical content — only reposition. Disable CA implicit animation to prevent jitter.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                existing.scroll.frame = CGRect(
                    x: 0,
                    y: blockFrame.minY - 8,
                    width: viewWidth,
                    height: existing.scroll.frame.height
                )
                CATransaction.commit()
                continue
            }

            // Same column structure (naturalWidth unchanged) — update content in place.
            // This is the common streaming case: cells grow but column count stays fixed.
            // Reusing the existing UIScrollView preserves contentOffset so the user's
            // horizontal scroll position is not reset on every streaming token.
            if let existing = _tableOverlays[i], abs(existing.naturalWidth - naturalWidth) < 0.5 {
                let renderer = AttributedStringRenderer(
                    style: renderStyle, availableWidth: naturalWidth, placeholderMode: self.renderMode)
                let tableStr = renderer.renderBlock(block)
                existing.content.update(tableString: tableStr)
                let newH = existing.content.frame.height
                existing.scroll.contentSize = CGSize(width: naturalWidth, height: newH)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                existing.scroll.frame = CGRect(
                    x: 0,
                    y: blockFrame.minY - 8,
                    width: viewWidth,
                    height: newH
                )
                CATransaction.commit()
                self._tableOverlays[i] = (
                    scroll: existing.scroll,
                    content: existing.content,
                    block: block,
                    naturalWidth: naturalWidth
                )
                continue
            }

            // Column structure changed — (re)create the scroll view.
            self._tableOverlays[i]?.scroll.removeFromSuperview()
            let renderer = AttributedStringRenderer(
                style: renderStyle, availableWidth: naturalWidth, placeholderMode: self.renderMode)
            let tableStr = renderer.renderBlock(block)
            let contentView = TableContentView(
                tableString: tableStr,
                style: renderStyle,
                naturalWidth: naturalWidth
            )
            let scrollH = contentView.frame.height
            let scrollView = UIScrollView(frame: CGRect(
                x: 0,
                y: blockFrame.minY - 8,
                width: viewWidth,
                height: scrollH
            ))
            scrollView.contentSize = CGSize(width: naturalWidth, height: scrollH)
            scrollView.showsHorizontalScrollIndicator = true
            scrollView.showsVerticalScrollIndicator = false
            scrollView.alwaysBounceVertical = false
            scrollView.addSubview(contentView)
            // Suppress the implicit fade-in / position animation that UIKit applies
            // when a view is added to the hierarchy during an active touch session.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            addSubview(scrollView)
            CATransaction.commit()
            self._tableOverlays[i] = (
                scroll: scrollView,
                content: contentView,
                block: block,
                naturalWidth: naturalWidth
            )
        }
    }
}

// MARK: - UITextSelectionDisplayInteractionDelegate

extension MarkdownLabelView: UITextSelectionDisplayInteractionDelegate {
    /// Return the dedicated container so UITextInteraction's internal
    /// UITextSelectionDisplayInteraction places highlight views below the
    /// draw(_:) text content (correct z-order).
    public func selectionContainerViewBelowText(
        for interaction: UITextSelectionDisplayInteraction
    )
        -> UIView? {
        self.highlightContainerView
    }
}

// MARK: - UITextInput

extension MarkdownLabelView: UITextInput {
    // MARK: UIKeyInput (required by UITextInput)

    public var hasText: Bool {
        self.documentLength > 0
    }

    // MARK: UITextInput delegate

    /// UITextInteraction sets this to receive selection-change notifications.
    public var inputDelegate: (any UITextInputDelegate)? {
        get { self._inputDelegate }
        set { self._inputDelegate = newValue }
    }

    public var selectedTextRange: UITextRange? {
        get {
            guard
                let sel = layoutManager.textSelections.first,
                let r = sel.textRanges.first else {
                return nil
            }
            return MarkdownTextRange(
                from: self.offsetOf(r.location),
                to: self.offsetOf(r.endLocation)
            )
        }
        set {
            self._inputDelegate?.selectionWillChange(self)
            guard
                let r = newValue as? MarkdownTextRange,
                let tr = makeTextRange(
                    from: r.nsRange.location,
                    to: NSMaxRange(r.nsRange)
                ) else {
                self.layoutManager.textSelections = []
                self._inputDelegate?.selectionDidChange(self)
                setNeedsDisplay()
                return
            }
            self.layoutManager.textSelections = [
                NSTextSelection(range: tr, affinity: .downstream, granularity: .character),
            ]
            self._inputDelegate?.selectionDidChange(self)
            setNeedsDisplay()
        }
    }

    public var markedTextRange: UITextRange? {
        nil
    }

    public var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil } set {}
    }

    public var beginningOfDocument: UITextPosition {
        MarkdownTextPosition(0)
    }

    public var endOfDocument: UITextPosition {
        MarkdownTextPosition(self.documentLength)
    }

    public var tokenizer: UITextInputTokenizer {
        UITextInputStringTokenizer(textInput: self)
    }

    public func insertText(_ text: String) { /* read-only */ }
    public func deleteBackward() { /* read-only */ }

    public func text(in range: UITextRange) -> String? {
        guard
            let r = range as? MarkdownTextRange,
            let str = contentStorage.attributedString?.string,
            NSMaxRange(r.nsRange) <= (str as NSString).length else {
            return nil
        }
        return (str as NSString).substring(with: r.nsRange)
    }

    public func replace(_ range: UITextRange, withText text: String) {}

    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    public func unmarkText() {}

    public func textRange(
        from fromPosition: UITextPosition,
        to toPosition: UITextPosition
    )
        -> UITextRange? {
        guard
            let a = fromPosition as? MarkdownTextPosition,
            let b = toPosition as? MarkdownTextPosition else {
            return nil
        }
        return MarkdownTextRange(from: min(a.offset, b.offset), to: max(a.offset, b.offset))
    }

    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let p = position as? MarkdownTextPosition else {
            return nil
        }
        return MarkdownTextPosition(max(0, min(p.offset + offset, self.documentLength)))
    }

    public func position(
        from position: UITextPosition,
        in direction: UITextLayoutDirection,
        offset: Int
    )
        -> UITextPosition? {
        let d = (direction == .right || direction == .down) ? offset : -offset
        return self.position(from: position, offset: d)
    }

    public func compare(
        _ position: UITextPosition,
        to other: UITextPosition
    )
        -> ComparisonResult {
        guard
            let a = position as? MarkdownTextPosition,
            let b = other as? MarkdownTextPosition else {
            return .orderedSame
        }
        if a.offset < b.offset {
            return .orderedAscending
        }
        if a.offset > b.offset {
            return .orderedDescending
        }
        return .orderedSame
    }

    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard
            let a = from as? MarkdownTextPosition,
            let b = toPosition as? MarkdownTextPosition else {
            return 0
        }
        return b.offset - a.offset
    }

    public func position(
        within range: UITextRange,
        farthestIn direction: UITextLayoutDirection
    )
        -> UITextPosition? {
        guard let r = range as? MarkdownTextRange else {
            return nil
        }
        return (direction == .left || direction == .up) ? r.start : r.end
    }

    public func characterRange(
        byExtending position: UITextPosition,
        in direction: UITextLayoutDirection
    )
        -> UITextRange? {
        guard let p = position as? MarkdownTextPosition else {
            return nil
        }
        switch direction {
        case .left, .up: return MarkdownTextRange(from: max(0, p.offset - 1), to: p.offset)
        default: return MarkdownTextRange(from: p.offset, to: min(self.documentLength, p.offset + 1))
        }
    }

    public func baseWritingDirection(
        for position: UITextPosition,
        in direction: UITextStorageDirection
    )
        -> NSWritingDirection {
        .natural
    }

    public func setBaseWritingDirection(
        _ writingDirection: NSWritingDirection,
        for range: UITextRange
    ) {}

    /// Geometry
    public func firstRect(for range: UITextRange) -> CGRect {
        guard
            let r = range as? MarkdownTextRange,
            let tr = makeTextRange(
                from: r.nsRange.location,
                to: NSMaxRange(r.nsRange)
            ) else {
            return .null
        }
        var result = CGRect.null
        self.layoutManager.enumerateTextSegments(in: tr, type: .standard, options: []) { _, frame, _, _ in
            result = frame
            return false
        }
        return result == .null ? .null : convert(result, to: nil)
    }

    public func caretRect(for position: UITextPosition) -> CGRect {
        guard
            let p = position as? MarkdownTextPosition,
            let loc = locationAt(p.offset) else {
            return .null
        }
        let zr = NSTextRange(location: loc)
        var result = CGRect.null
        self.layoutManager.enumerateTextSegments(in: zr, type: .selection, options: []) { _, frame, _, _ in
            result = CGRect(x: frame.minX, y: frame.minY, width: 2, height: frame.height)
            return false
        }
        return result
    }

    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard
            let r = range as? MarkdownTextRange,
            let tr = makeTextRange(
                from: r.nsRange.location,
                to: NSMaxRange(r.nsRange)
            ) else {
            return []
        }
        var rects: [MarkdownSelectionRect] = []
        self.layoutManager.enumerateTextSegments(in: tr, type: .highlight, options: []) { _, frame, _, _ in
            rects.append(MarkdownSelectionRect(frame))
            return true
        }
        return rects
    }

    /// Hit testing
    public func closestPosition(to point: CGPoint) -> UITextPosition? {
        let sels = self.layoutManager.textSelectionNavigation.textSelections(
            interactingAt: point,
            inContainerAt: self.contentStorage.documentRange.location,
            anchors: [],
            modifiers: [],
            selecting: false,
            bounds: CGRect(origin: .zero, size: self.textContainer.size)
        )
        guard let loc = sels.first?.textRanges.first?.location else {
            return self.beginningOfDocument
        }
        return MarkdownTextPosition(self.offsetOf(loc))
    }

    public func closestPosition(
        to point: CGPoint,
        within range: UITextRange
    )
        -> UITextPosition? {
        self.closestPosition(to: point)
    }

    public func characterRange(at point: CGPoint) -> UITextRange? {
        guard
            let pos = closestPosition(to: point) as? MarkdownTextPosition,
            pos.offset < documentLength else {
            return nil
        }
        return MarkdownTextRange(from: pos.offset, to: pos.offset + 1)
    }
}

#elseif canImport(AppKit)
import AppKit

// MARK: - MarkdownLabelView (macOS)

@MainActor
public final class MarkdownLabelView: NSView {
    override public init(frame: NSRect) {
        super.init(frame: frame)
        self.buildStack()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override public var isFlipped: Bool {
        true
    }

    override public var acceptsFirstResponder: Bool {
        true
    }

    override public var intrinsicContentSize: NSSize {
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: ceil(self.layoutManager.usageBoundsForTextContainer.height)
        )
    }

    public var renderStyle: RenderStyle = .default {
        didSet {
            guard !self.renderStyle.isSemanticallyEqual(to: oldValue) else {
                return
            }
            self._cachedRenderer = nil
            self._tableOverlays.values.forEach { $0.scroll.removeFromSuperview() }
            self._tableOverlays.removeAll()
            self.updateContent()
        }
    }

    public var blocks: [BlockNode] = [] {
        didSet {
            guard !self._isIncrementalUpdate else {
                return
            }
            self.parsedBlocks = self.blocks.map { ParsedBlockNode(block: $0) }
            self.updateContent()
        }
    }

    override public func layout() {
        super.layout()
        if abs(self.textContainer.size.width - bounds.width) > 0.5 {
            self.resetLayout()
        } else {
            self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
            let startIndex = self._pendingTableOverlaySyncStart ?? 0
            self._pendingTableOverlaySyncStart = nil
            self._syncTableOverlays(from: startIndex)
        }
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            return
        }
        self.decorations.drawAll(blocks: self.blocks, in: ctx)
        // Selection highlights
        if !self.layoutManager.textSelections.isEmpty {
            NSColor.selectedTextBackgroundColor.withAlphaComponent(0.4).setFill()
            for sel in self.layoutManager.textSelections {
                for range in sel.textRanges {
                    self.layoutManager.enumerateTextSegments(in: range, type: .highlight, options: []) {
                        _, frame, _, _ in NSBezierPath(rect: frame).fill()
                        return true
                    }
                }
            }
        }
        // Text fragments
        self.layoutManager.enumerateTextLayoutFragments(
            from: self.layoutManager.documentRange.location,
            options: [.ensuresLayout, .ensuresExtraLineFragment]
        ) { fragment in
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: ctx)
            return true
        }
    }

    // MARK: Mouse selection

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        let sels = self.layoutManager.textSelectionNavigation.textSelections(
            interactingAt: pt,
            inContainerAt: self.contentStorage.documentRange.location,
            anchors: [], modifiers: [], selecting: false,
            bounds: CGRect(origin: .zero, size: self.textContainer.size)
        )
        self.layoutManager.textSelections = sels
        needsDisplay = true
    }

    override public func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let anchors = self.layoutManager.textSelections
        let sels = self.layoutManager.textSelectionNavigation.textSelections(
            interactingAt: pt,
            inContainerAt: self.contentStorage.documentRange.location,
            anchors: anchors, modifiers: [], selecting: true,
            bounds: CGRect(origin: .zero, size: self.textContainer.size)
        )
        self.layoutManager.textSelections = sels
        needsDisplay = true
    }

    override public func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let sels = self.layoutManager.textSelectionNavigation.textSelections(
            interactingAt: pt,
            inContainerAt: self.contentStorage.documentRange.location,
            anchors: [], modifiers: [], selecting: false,
            bounds: CGRect(origin: .zero, size: self.textContainer.size)
        )
        guard
            let selLoc = sels.first?.textRanges.first?.location,
            let str = contentStorage.attributedString else {
            return
        }
        let offset = self.contentStorage.offset(
            from: self.contentStorage.documentRange.location, to: selLoc
        )
        let docLen = self.contentStorage.offset(
            from: self.contentStorage.documentRange.location,
            to: self.contentStorage.documentRange.endLocation
        )
        guard offset < docLen else {
            return
        }
        let attrs = str.attributes(at: offset, effectiveRange: nil)
        let url: URL? = if let u = attrs[.link] as? URL {
            u
        } else if let s = attrs[.link] as? String {
            URL(string: s)
        } else {
            nil
        }
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Keyboard

    override public func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.characters {
            case "a": self.selectAll(nil)
                return
            case "c": self.copy(nil)
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    /// AppKit first-responder copy entry point (Edit menu / `cmd+C`); mirrors the
    /// iOS copy entry point (not an NSView override — NSView has no `copy(_:)`).
    /// `@objc` is sufficient for responder-chain dispatch; `public` is not needed.
    @objc
    func copy(_: Any?) {
        self.performCopy()
    }

    @objc
    override public func selectAll(_ sender: Any?) {
        self.layoutManager.textSelections = [
            NSTextSelection(
                range: self.contentStorage.documentRange,
                affinity: .downstream,
                granularity: .character
            ),
        ]
        needsDisplay = true
    }

    /// Test-support: select the entire document. Mirrors the iOS seam so the
    /// headless copy regression test drives both platforms symmetrically.
    func _selectEntireDocumentForTesting() {
        self.selectAll(nil)
    }

    /// Test-support: the original-source string that the production copy path
    /// (`performCopy()`) would put on the pasteboard for the *current*
    /// selection, without touching the system pasteboard (avoids a global side
    /// effect / headless-CI flakiness). Shares the exact production
    /// selection→range→`copyString` logic via `_copiedStringForCurrentSelection`
    /// so the regression coverage is not narrowed. Mirrors the iOS seam.
    func _copiedStringForCurrentSelectionForTesting() -> String {
        self._copiedStringForCurrentSelection() ?? ""
    }

    /// Test-support: the laid-out frame union of the block at `index` in the
    /// *main* TextKit 2 stack. Mirrors the iOS seam so the headless wide-table
    /// overlap regression test drives both platforms symmetrically. The
    /// observed quantity is driven by real TextKit2 layout (which depends on
    /// placeholder attachment bounds), not a decoupled counter.
    func _blockFrameUnionForTesting(at index: Int) -> CGRect? {
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        return self.decorations.blockFrameUnion(at: index)
    }

    /// Test-support: math-resolution state of the *actual* production-rendered
    /// string (`contentStorage.attributedString`, i.e. what is drawn).
    /// Read-only forwarder; mirrors `_blockFrameUnionForTesting`.
    ///
    /// `mathSourceCount` = residual unresolved-math placeholders;
    /// `attachmentCount` = resolved math glyphs spliced in as attachments.
    /// After streaming settles, a fully math-resolved document has
    /// `mathSourceCount == 0` and `attachmentCount == <#math spans>`. If the
    /// async math glyph write-back fails to survive `resetLayout()`'s renderer
    /// recreation (Bug 1 math sub-symptom), `renderMath` keeps missing the
    /// cache → placeholders keep reappearing → these counts oscillate / never
    /// reach the resolved form. This is the true, undecoupled signal for "did
    /// the resolved math survive renderer recreation" — distinct from the
    /// separately-guarded TextKit2 relayout-timing concern.
    func _renderedMathStateForTesting() -> (mathSourceCount: Int, attachmentCount: Int) {
        guard let str = self.contentStorage.attributedString else {
            return (0, 0)
        }
        var srcCount = 0
        var attachCount = 0
        let full = NSRange(location: 0, length: str.length)
        str.enumerateAttribute(.markdownMathSource, in: full) { v, _, _ in
            if v is String { srcCount += 1 }
        }
        str.enumerateAttribute(.attachment, in: full) { v, _, _ in
            if v != nil { attachCount += 1 }
        }
        return (srcCount, attachCount)
    }

    /// 测试钩子：枚举 `.markdownSVGBlockSource` 未解析占位与 `.attachment` 数量。
    /// 镜像 `_renderedMathStateForTesting`，是「已解析 svg 是否熬过 renderer 重建」
    /// 的无解耦直读信号（看 view 真正绘制的串）。
    func _renderedSVGBlockStateForTesting() -> (markerCount: Int, attachmentCount: Int) {
        guard let str = self.contentStorage.attributedString else {
            return (0, 0)
        }
        var markerCount = 0
        var attachCount = 0
        let full = NSRange(location: 0, length: str.length)
        str.enumerateAttribute(.markdownSVGBlockSource, in: full) { v, _, _ in
            if v is String { markerCount += 1 }
        }
        str.enumerateAttribute(.attachment, in: full) { v, _, _ in
            if v != nil { attachCount += 1 }
        }
        return (markerCount, attachCount)
    }

    /// 测试钩子：读取第一个 svg 渲染 attachment 的 image 尺寸（用于 R1→R2
    /// swap 测试 —— 不同 renderer 配置不同 stub size，验证 swap 后 attachment
    /// 真的换成新 renderer 输出。返回 nil 表示还没解析为 attachment。
    func _firstSVGAttachmentImageSizeForTesting() -> CGSize? {
        guard let str = self.contentStorage.attributedString else { return nil }
        var found: CGSize?
        let full = NSRange(location: 0, length: str.length)
        str.enumerateAttribute(.attachment, in: full) { value, _, stop in
            if let a = value as? NSTextAttachment, let img = a.image {
                found = img.size
                stop.pointee = true
            }
        }
        return found
    }

    public func setMarkdown(_ source: String) {
        // 完整重置 → 静态首屏。cache-miss 形态由 renderer 看 `.static` 出透明 attachment。
        self.renderMode = .static
        self._parseSerial += 1
        self._parseTask?.cancel()
        self._parseTask = nil
        self._pendingParseAfterCurrent = false
        self.streamingSource = source
        self.scheduleParse(delayNanoseconds: 0)
    }

    public func appendMarkdown(_ chunk: String) {
        // 增量流式 → 保持既有 streaming 行为，cache-miss 显示源码占位。
        self.renderMode = .streaming
        self.streamingSource += chunk
        self.scheduleParse(delayNanoseconds: 50_000_000)
    }

    private var _isIncrementalUpdate = false

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(
        size: CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    )
    private var streamingSource = ""
    private var lastParsedSource = ""
    private var parsedBlocks: [ParsedBlockNode] = []
    // Cached renderer — invalidated when renderStyle or available width changes.
    private var _cachedRenderer: AttributedStringRenderer?
    private var _cachedRendererWidth: CGFloat = 0
    /// 占位 mode 跟踪：`setMarkdown` 翻 `.static`、`appendMarkdown` 翻 `.streaming`。
    /// 传给 `AttributedStringRenderer.init(...)` 决定 cache-miss 占位形态（透明 vs 源码）。
    /// 默认 `.static`（构造时空内容场景）。
    /// `_cachedRenderer.placeholderMode` 是 `let`，因此 mode 真正翻转时必须把
    /// `_cachedRenderer` 清掉，下次 `cachedRenderer` 取值会用新 mode 重建。
    /// Tracks placeholder mode; flipped by setMarkdown/appendMarkdown.
    /// `public internal(set)`: tests read, only the module writes.
    public internal(set) var renderMode: PlaceholderMode = .static {
        didSet {
            if oldValue != self.renderMode {
                // mode 翻转 → cached renderer 的 placeholderMode 是 let，必须重建。
                self._cachedRenderer = nil
            }
        }
    }
    /// Canonical mutable store — avoids O(n) mutableCopy() per streaming token.
    private var _liveString = NSMutableAttributedString()
    /// Last measured intrinsic height — gates invalidateIntrinsicContentSize() calls.
    private var _lastHeight: CGFloat = 0
    /// Coalesces expensive TextKit height queries during streaming updates.
    private var _heightUpdateTask: Task<Void, Never>?
    /// Test-only monotonic counter incremented as the *first line* of
    /// `scheduleDeferredHeightUpdate()` itself, so "counter++" and "that primitive
    /// was actually invoked" are one indivisible semantic — there is no decoupled
    /// bypass. If a caller (e.g. `resetLayout()` on the async write-back path) stops
    /// invoking `scheduleDeferredHeightUpdate()`, this counter cannot advance, so a
    /// regression test bound to it necessarily turns red. The deferred task auto-nils
    /// after ~33ms so a transient flag would race, hence a durable counter. Zero
    /// production behavior beyond an Int increment at the primitive's entry.
    var _deferredHeightScheduleCount = 0
    /// In-flight parse task. Streaming keeps this single-flight so large documents do not
    /// accumulate cancelled full-document parses as tokens arrive.
    private var _parseTask: Task<Void, Never>?
    private var _parseSerial = 0
    private var _pendingParseAfterCurrent = false
    /// In-memory image cache keyed by source URL string.
    private var _imageCache: [String: NSImage] = [:]
    /// Source URLs currently being fetched (prevents duplicate requests).
    private var _imageLoading: Set<String> = []
    /// Platform-agnostic async math render coordinator (dedup/三态/代际).
    /// View-private by default to keep test isolation (each MarkdownLabelView
    /// 自带独立 coordinator，避免不同 test 的 setRenderer 互相清 cache)。需要
    /// 跨 view 共享 cache 的调用方可显式注入 `MathLoadCoordinator.shared`。
    private let _mathCoordinator = MathLoadCoordinator()
    /// View-held math glyph cache / raster scale / renderer generation —
    /// the **canonical store** for async math write-back, mirroring
    /// `_imageCache`. The transient `_cachedRenderer` is discarded by
    /// `resetLayout()` whenever `bounds.width` changes (streaming churn);
    /// keeping math state on the view (and re-seeding it into every freshly
    /// built renderer in `cachedRenderer`) is what makes resolved glyphs
    /// survive renderer recreation — exactly as `_imageCache` already does.
    private var _mathCache: [MathCacheKey: MathRenderedGlyph] = [:]
    private var _mathRasterScale: CGFloat = 1
    private var _mathRendererGeneration: Int = 0
    /// Injected math renderer; swapping it bumps the coordinator's generation.
    public var mathRenderer: (any MathRendering)? {
        // setRenderer 异步派发；落地前发生的渲染会显示 latex 占位，并在下次
        // updateContent/relayout 时解析（有意为之的最终一致性）。
        didSet { Task { await self._mathCoordinator.setRenderer(self.mathRenderer) } }
    }
    /// Platform-agnostic async ```svg block render coordinator (dedup/三态/代际).
    /// View-private by default to keep test isolation (each MarkdownLabelView
    /// 自带独立 coordinator，避免不同 test 的 setRenderer 互相清 cache)。需要
    /// 跨 view 共享 cache 的调用方可显式注入 `SVGBlockLoadCoordinator.shared`。
    private let _svgBlockCoordinator = SVGBlockLoadCoordinator()
    /// View-held svg-block glyph cache / raster scale / renderer generation —
    /// the **canonical store** for async svg write-back, mirroring `_mathCache`
    /// discipline. The transient `_cachedRenderer` is discarded by `resetLayout()`
    /// on width churn; keeping svg state on the view (and re-seeding it into
    /// every freshly built renderer in `cachedRenderer`) is what makes resolved
    /// svg images survive renderer recreation — identical to `_mathCache`.
    private var _svgBlockCache: [SVGBlockCacheKey: SVGBlockGlyph] = [:]
    private var _svgRasterScale: CGFloat = 1
    private var _svgBlockRendererGeneration: Int = 0
    /// Injected ```svg block renderer; swapping it bumps the coordinator's generation.
    public var svgBlockRenderer: (any SVGBlockRendering)? {
        // didSet 行为契约：
        // 1) 异步把 renderer 推给 coordinator（gen bump + 清协调器自身的 caches）。
        // 2) 在 coordinator 落地**之后**回到 MainActor 做后续：
        //    - nil 分支：清 view-held + transient renderer 的 svg cache（让
        //      已渲染 svg 立刻降级回高亮源码，匹配 .svgRenderer(nil) 的
        //      「disable」文档契约——Copilot PR #5 R4 #1）。
        //    - 任何分支：触发一次 updateContent 让 triggerSVGBlockLoads 在
        //      新 renderer 下重新派发；解决 nil→非nil 时源串不变 → representable
        //      早 return 不调 setMarkdown → svg 永停 marker 的死锁（Copilot
        //      PR #5 R7 #1 + suppressed）。先 await setRenderer 再 updateContent
        //      可避免 triggerSVGBlockLoads 抢在 setRenderer 之前用旧 coordinator
        //      状态派发并被随后的 setRenderer drop 的竞态。
        didSet {
            Task { [weak self] in
                guard let self else { return }
                await self._svgBlockCoordinator.setRenderer(self.svgBlockRenderer)
                await MainActor.run {
                    // **任何 renderer 变更**都失效 view-held svg cache：
                    // - nil 分支：原 R4 #1 disable 契约要求清 cache 让已渲染
                    //   svg 降级回高亮源码 + marker。
                    // - 非 nil→非 nil swap：若不清，已 attachment 的 svg 会
                    //   继续命中旧 cache（view-held _svgBlockRendererGeneration
                    //   仍是旧值），renderSVGBlock 直接输出 attachment 而非
                    //   marker，triggerSVGBlockLoads 枚举不到 marker → 新
                    //   renderer 永不派发 → renderer swap 不真正生效
                    //   （Copilot PR #5 R8 #1 + suppressed）。
                    // 清 cache 后 updateContent 让所有 svg 走 miss→marker→
                    // 新 coordinator 派发→回写链路；任何 renderer 切换都生效。
                    self._svgBlockCache.removeAll()
                    self._cachedRenderer?.svgBlockCache.removeAll()
                    self.updateContent()
                }
            }
        }
    }
    /// Horizontal-scroll overlays for table blocks wider than the view, keyed by block index.
    private var _tableOverlays: [Int: (
        scroll: NSScrollView,
        content: TableContentView,
        block: BlockNode,
        naturalWidth: CGFloat
    )] = [:]
    private var _pendingTableOverlaySyncStart: Int?

    private var blockStarts: [Int] = []

    private var cachedRenderer: AttributedStringRenderer {
        let w = max(bounds.width, 1)
        if self._cachedRenderer == nil || abs(w - self._cachedRendererWidth) > 0.5 {
            var renderer = AttributedStringRenderer(
                style: renderStyle, availableWidth: w, placeholderMode: self.renderMode)
            renderer.imageCache = self._imageCache
            // Re-seed view-held math state so resolved glyphs survive the
            // renderer recreation `resetLayout()` performs on width churn
            // (identical discipline to `imageCache` above).
            renderer.mathCache = self._mathCache
            renderer.mathRasterScale = self._mathRasterScale
            renderer.mathRendererGeneration = self._mathRendererGeneration
            // 同款 svg 重播种：让解析后的 svg 字形熬过 width churn 引发的 renderer 重建。
            renderer.svgBlockCache = self._svgBlockCache
            renderer.svgRasterScale = self._svgRasterScale
            renderer.svgRendererGeneration = self._svgBlockRendererGeneration
            self._cachedRenderer = renderer
            self._cachedRendererWidth = w
        }
        return self._cachedRenderer!
    }

    private var decorations: MarkdownLabelDecorations {
        MarkdownLabelDecorations(
            style: self.renderStyle,
            bounds: bounds,
            layoutManager: self.layoutManager,
            contentStorage: self.contentStorage,
            liveString: self._liveString,
            blockStarts: self.blockStarts
        )
    }

    private func buildStack() {
        self.textContainer.lineFragmentPadding = 0
        self.layoutManager.textContainer = self.textContainer
        self.contentStorage.addTextLayoutManager(self.layoutManager)
        self.contentStorage.attributedString = NSAttributedString(string: "")
    }

    private func updateContent() {
        let renderer = self.cachedRenderer
        let result = NSMutableAttributedString()
        var starts: [Int] = []
        for (index, block) in self.blocks.enumerated() {
            if index > 0 {
                result.append(renderer.separator)
            }
            starts.append(result.length)
            result.append(renderer.renderBlock(block))
        }
        self.blockStarts = starts
        self._liveString = result
        self.contentStorage.performEditingTransaction {
            self.contentStorage.attributedString = self._liveString
        }
        self.resetLayout()
        self.triggerImageLoads(in: NSRange(location: 0, length: self._liveString.length))
        self.triggerMathLoads(in: NSRange(location: 0, length: self._liveString.length))
        self.triggerSVGBlockLoads(in: NSRange(location: 0, length: self._liveString.length))
    }

    private func resetLayout() {
        let w = max(bounds.width, 1)
        self.textContainer.size = CGSize(width: w, height: .greatestFiniteMagnitude)
        if abs(w - self._cachedRendererWidth) > 0.5 {
            self._cachedRenderer = nil
            self.updateContent()
            return
        }
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        self._heightUpdateTask?.cancel()
        self._heightUpdateTask = nil
        self._lastHeight = ceil(self.layoutManager.usageBoundsForTextContainer.height)
        invalidateIntrinsicContentSize()
        needsDisplay = true
        // Mirror applyDocument's host-relayout discipline: async write-back paths
        // (image/math glyph resolution → updateContent → resetLayout) can shrink
        // content dramatically. invalidateIntrinsicContentSize() alone does not make
        // the SwiftUI host re-query our size, so request a host layout pass and a
        // deferred height re-measure exactly as the streaming incremental path does.
        needsLayout = true
        self.scheduleDeferredHeightUpdate()
        self._pendingTableOverlaySyncStart = nil
        self._syncTableOverlays(from: 0)
    }

    private func scheduleDeferredHeightUpdate() {
        // Counter is bumped here, at the primitive's entry, so it is indivisible
        // from "scheduleDeferredHeightUpdate() was actually invoked" (see decl).
        self._deferredHeightScheduleCount += 1
        guard self._heightUpdateTask == nil else {
            return
        }
        self._heightUpdateTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 33_000_000)
            } catch {
                return
            }
            self?.updateMeasuredHeightIfNeeded()
        }
    }

    private func updateMeasuredHeightIfNeeded() {
        self._heightUpdateTask = nil
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        let newHeight = ceil(layoutManager.usageBoundsForTextContainer.height)
        if abs(newHeight - self._lastHeight) > 0.5 {
            self._lastHeight = newHeight
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    private func scheduleParse(delayNanoseconds: UInt64) {
        guard self._parseTask == nil else {
            self._pendingParseAfterCurrent = true
            return
        }
        let serial = self._parseSerial
        self._parseTask = Task {
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    self.finishParseTask(serial: serial)
                    return
                }
            }
            guard !Task.isCancelled, serial == self._parseSerial else {
                self.finishParseTask(serial: serial)
                return
            }
            let source = self.streamingSource
            let prevBlocks = self.blocks
            let prevParsedBlocks = self.parsedBlocks
            let prevSource = self.lastParsedSource
            let prevStarts = self.blockStarts
            let newDocument = await Task.detached(priority: .userInitiated) {
                MarkdownDocument(parsedBlocks: prevParsedBlocks)
                    .parsingAppend(to: source, previousSource: prevSource)
            }.value
            guard !Task.isCancelled, serial == self._parseSerial else {
                self.finishParseTask(serial: serial)
                return
            }
            self.applyDocument(
                newDocument,
                source: source,
                prevBlocks: prevBlocks,
                prevParsedBlocks: prevParsedBlocks,
                prevStarts: prevStarts
            )
            let needsFollowUp = self._pendingParseAfterCurrent || self.streamingSource != source
            self.finishParseTask(serial: serial)
            if needsFollowUp {
                self._pendingParseAfterCurrent = false
                self.scheduleParse(delayNanoseconds: 50_000_000)
            }
        }
    }

    private func finishParseTask(serial: Int) {
        guard serial == self._parseSerial else {
            return
        }
        self._parseTask = nil
    }

    /// Applies a newly parsed block array. Must be called on MainActor.
    private func applyDocument(
        _ document: MarkdownDocument,
        source: String,
        prevBlocks: [BlockNode],
        prevParsedBlocks: [ParsedBlockNode],
        prevStarts: [Int]
    ) {
        let newBlocks = document.blocks
        let newParsedBlocks = document.parsedBlocks
        self.parsedBlocks = document.parsedBlocks
        self.lastParsedSource = source

        let firstChanged = firstChangedMarkdownBlockIndex(
            prevParsedBlocks: prevParsedBlocks,
            newParsedBlocks: newParsedBlocks,
            prevBlocks: prevBlocks,
            newBlocks: newBlocks
        )
        guard firstChanged < prevBlocks.count || firstChanged < newBlocks.count else {
            return
        }

        self._isIncrementalUpdate = true
        self.blocks = newBlocks
        self._isIncrementalUpdate = false

        let stablePrefixLen: Int = if firstChanged == 0 {
            0
        } else if firstChanged < prevStarts.count {
            prevStarts[firstChanged] - 1
        } else {
            self._liveString.length
        }

        let renderer = self.cachedRenderer
        let sep = renderer.separator
        let suffix = NSMutableAttributedString()
        var newExtraStarts: [Int] = []
        var pos = stablePrefixLen
        for (offset, block) in newBlocks[firstChanged...].enumerated() {
            if firstChanged + offset > 0 {
                suffix.append(sep)
                pos += sep.length
            }
            newExtraStarts.append(pos)
            let rendered = renderer.renderBlock(block)
            suffix.append(rendered)
            pos += rendered.length
        }
        self.blockStarts = Array(prevStarts.prefix(firstChanged)) + newExtraStarts

        // Splice directly into the canonical mutable store — avoids O(n) mutableCopy() per token.
        self._liveString.replaceCharacters(
            in: NSRange(location: stablePrefixLen, length: self._liveString.length - stablePrefixLen),
            with: suffix
        )
        self.contentStorage.performEditingTransaction {
            self.contentStorage.attributedString = self._liveString
        }

        self.textContainer.size = CGSize(width: max(bounds.width, 1), height: .greatestFiniteMagnitude)
        // Scope ensureLayout to the changed suffix instead of the entire document.
        let docEnd = self.layoutManager.documentRange.endLocation
        let layoutStart: NSTextLocation = if
            stablePrefixLen > 0,
            let loc = contentStorage.location(
                contentStorage.documentRange.location,
                offsetBy: stablePrefixLen
            ) {
            loc
        } else {
            self.layoutManager.documentRange.location
        }
        if let layoutRange = NSTextRange(location: layoutStart, end: docEnd) {
            self.layoutManager.ensureLayout(for: layoutRange)
        }
        self.scheduleDeferredHeightUpdate()
        // Find the Y of the first changed fragment; reuse layoutStart (no extra ensureLayout pass).
        var dirtyY: CGFloat = 0
        if stablePrefixLen > 0 {
            self.layoutManager.enumerateTextLayoutFragments(from: layoutStart, options: []) { frag in
                dirtyY = frag.layoutFragmentFrame.minY
                return false
            }
        }
        setNeedsDisplay(NSRect(
            x: 0,
            y: dirtyY,
            width: bounds.width,
            height: bounds.height - dirtyY
        ))
        self._pendingTableOverlaySyncStart = min(self._pendingTableOverlaySyncStart ?? firstChanged, firstChanged)
        needsLayout = true
        self.triggerImageLoads(in: NSRange(location: stablePrefixLen, length: suffix.length))
        self.triggerMathLoads(in: NSRange(location: stablePrefixLen, length: suffix.length))
        self.triggerSVGBlockLoads(in: NSRange(location: stablePrefixLen, length: suffix.length))
    }

    // MARK: Table overlay helpers (macOS)

    private func _tableNaturalWidth(at blockIndex: Int) -> CGFloat {
        self.decorations.tableNaturalWidth(at: blockIndex)
    }

    private func _syncTableOverlays(from startIndex: Int) {
        let startIndex = max(0, min(startIndex, blocks.count))
        let stale = self._tableOverlays.keys.filter { i -> Bool in
            guard i >= startIndex else {
                return false
            }
            guard i < self.blocks.count, case .table = self.blocks[i] else {
                return true
            }
            return false
        }
        for i in stale {
            self._tableOverlays[i]?.scroll.removeFromSuperview()
            self._tableOverlays.removeValue(forKey: i)
        }

        let viewWidth = bounds.width
        guard startIndex < self.blocks.count else {
            return
        }

        // The reserved height in the main stack is already correct by
        // construction: `AttributedStringRenderer.overflowTablePlaceholder` and
        // the overlay's `TableContentView` both size off the *same*
        // `TableMeasurement.height` call, so there is no write-back and no
        // convergence pass — this loop only positions/sizes the overlay against
        // the (already-correct) reserved geometry from `blockFrameUnion`.
        for i in startIndex ..< self.blocks.count {
            let block = self.blocks[i]
            guard case .table = block else {
                if let o = _tableOverlays[i] {
                    o.scroll.removeFromSuperview()
                    self._tableOverlays.removeValue(forKey: i)
                }
                continue
            }
            let naturalWidth = self._tableNaturalWidth(at: i)
            guard naturalWidth > viewWidth + 0.5 else {
                if let o = _tableOverlays[i] {
                    o.scroll.removeFromSuperview()
                    self._tableOverlays.removeValue(forKey: i)
                }
                continue
            }
            guard
                let blockFrame = decorations.blockFrameUnion(at: i),
                !blockFrame.isNull, blockFrame.height > 0 else {
                continue
            }

            if let existing = _tableOverlays[i], existing.block == block {
                // Identical content — only reposition without implicit animation.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                existing.scroll.frame = NSRect(
                    x: 0,
                    y: blockFrame.minY - 8,
                    width: viewWidth,
                    height: existing.scroll.frame.height
                )
                CATransaction.commit()
                continue
            }

            // Same column structure — update content in place to preserve scroll offset.
            if let existing = _tableOverlays[i], abs(existing.naturalWidth - naturalWidth) < 0.5 {
                let renderer = AttributedStringRenderer(
                    style: renderStyle, availableWidth: naturalWidth, placeholderMode: self.renderMode)
                let tableStr = renderer.renderBlock(block)
                existing.content.update(tableString: tableStr)
                let newH = existing.content.frame.height
                existing.scroll.documentView?.setFrameSize(NSSize(width: naturalWidth, height: newH))
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                existing.scroll.frame = NSRect(
                    x: 0,
                    y: blockFrame.minY - 8,
                    width: viewWidth,
                    height: newH
                )
                CATransaction.commit()
                self._tableOverlays[i] = (
                    scroll: existing.scroll,
                    content: existing.content,
                    block: block,
                    naturalWidth: naturalWidth
                )
                continue
            }

            // Column structure changed — (re)create the scroll view.
            self._tableOverlays[i]?.scroll.removeFromSuperview()
            let renderer = AttributedStringRenderer(
                style: renderStyle, availableWidth: naturalWidth, placeholderMode: self.renderMode)
            let tableStr = renderer.renderBlock(block)
            let contentView = TableContentView(
                tableString: tableStr,
                style: renderStyle,
                naturalWidth: naturalWidth
            )
            let scrollH = contentView.frame.height
            let scrollView = NSScrollView(frame: NSRect(
                x: 0,
                y: blockFrame.minY - 8,
                width: viewWidth,
                height: scrollH
            ))
            scrollView.hasHorizontalScroller = true
            scrollView.hasVerticalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            scrollView.drawsBackground = false
            scrollView.horizontalScrollElasticity = .automatic
            scrollView.verticalScrollElasticity = .none
            scrollView.documentView = contentView
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            addSubview(scrollView)
            CATransaction.commit()
            self._tableOverlays[i] = (
                scroll: scrollView,
                content: contentView,
                block: block,
                naturalWidth: naturalWidth
            )
        }
    }

    // MARK: Image loading

    private func triggerImageLoads(in range: NSRange) {
        guard let str = contentStorage.attributedString else {
            return
        }
        let safeRange = range.clamped(to: str.length)
        guard safeRange.length > 0 else {
            return
        }
        str.enumerateAttribute(
            .markdownImageSource,
            in: safeRange
        ) { value, _, _ in
            guard
                let source = value as? String,
                !_imageLoading.contains(source),
                _imageCache[source] == nil else {
                return
            }
            self._imageLoading.insert(source)
            self.loadImage(source: source)
        }
    }

    private func loadImage(source: String) {
        guard let url = URL(string: source) else {
            self._imageLoading.remove(source)
            return
        }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = NSImage(data: data) {
                    self.finishImageLoad(source: source, image: image)
                } else {
                    self.finishImageLoadFailure(source: source)
                }
            } catch {
                self.finishImageLoadFailure(source: source)
            }
        }
    }

    private func finishImageLoad(source: String, image: NSImage) {
        self._imageCache[source] = image
        _ = self._imageLoading.remove(source)
        self._cachedRenderer?.imageCache[source] = image
        self.updateContent()
    }

    private func finishImageLoadFailure(source: String) {
        _ = self._imageLoading.remove(source)
    }

    // MARK: Math loading

    private func triggerMathLoads(in range: NSRange) {
        guard self.mathRenderer != nil, let str = contentStorage.attributedString else {
            return
        }
        let safe = range.clamped(to: str.length)
        guard safe.length > 0 else {
            return
        }
        let scale = self.window?.backingScaleFactor ?? 2
        // 同步枚举收集原始请求（latex/display/color/pt），代际相关的 key 构造
        // 推迟到下面那个唯一的 Task 内一次性完成（generation 受 actor 隔离）。
        var raw: [(latex: String, display: Bool, color: PlatformColor, pt: CGFloat)] = []
        str.enumerateAttribute(.markdownMathSource, in: safe) { value, _, _ in
            guard
                let payload = value as? String,
                let sep = payload.firstIndex(of: "\u{1F}") else {
                return
            }
            let display = payload[payload.startIndex] == "1"
            let latex = String(payload[payload.index(after: sep)...])
            let color = self.renderStyle.mathColorOverride ?? self.renderStyle.textColor
            let pt = MathMetrics.effectivePointSize(
                textPointSize: self.renderStyle.bodyFont.pointSize,
                mathScale: self.renderStyle.mathScale
            )
            raw.append((latex: latex, display: display, color: color, pt: pt))
        }
        guard !raw.isEmpty else {
            return
        }
        Task { [weak self] in
            guard let self else {
                return
            }
            // 一次读取代际，用同一 gen 构造所有 key（保持与原实现一致的键公式）。
            let gen = await self._mathCoordinator.generation
            let requests: [(key: MathCacheKey, latex: String, display: Bool,
                            color: PlatformColor, pt: CGFloat)] = raw.map {
                let key = MathCacheKey(
                    latex: $0.latex, display: $0.display, pointSize: $0.pt,
                    colorHex: MathMetrics.colorHex($0.color),
                    rasterScale: scale, rendererGeneration: gen
                )
                return (key: key, latex: $0.latex, display: $0.display,
                        color: $0.color, pt: $0.pt)
            }
            // 先派发全部渲染（去重由 coordinator 负责）。
            for r in requests {
                await self._mathCoordinator.loadIfNeeded(
                    key: r.key, latex: r.latex, display: r.display,
                    pointSize: r.pt, scale: scale, color: r.color
                )
            }
            // 仅 await 各自 key 的在途任务，收集解析出的字形。
            var resolved: [(key: MathCacheKey, glyph: MathRenderedGlyph)] = []
            for r in requests {
                if let glyph = await self._mathCoordinator.awaitGlyph(for: r.key) {
                    resolved.append((key: r.key, glyph: glyph))
                }
            }
            guard !resolved.isEmpty else {
                return
            }
            // 一次性合并回写并仅触发一次 updateContent（镜像图片加载纪律）。
            await MainActor.run {
                // 真值源是 view-held store —— resetLayout() 在宽度抖动时会
                // 丢弃 _cachedRenderer，下次 cachedRenderer 重建会从这里
                // 重播种；同时也写当前 transient renderer（与
                // finishImageLoad 同时写 _imageCache 与 _cachedRenderer?
                // 完全同构）。
                self._mathRasterScale = scale
                self._mathRendererGeneration = gen
                self._cachedRenderer?.mathRasterScale = scale
                self._cachedRenderer?.mathRendererGeneration = gen
                for entry in resolved {
                    self._mathCache[entry.key] = entry.glyph
                    self._cachedRenderer?.mathCache[entry.key] = entry.glyph
                }
                self.updateContent()
            }
        }
    }

    // MARK: SVG block loading

    private func triggerSVGBlockLoads(in range: NSRange) {
        guard self.svgBlockRenderer != nil, let str = contentStorage.attributedString else {
            return
        }
        let safe = range.clamped(to: str.length)
        guard safe.length > 0 else {
            return
        }
        let scale = self.window?.backingScaleFactor ?? 2
        // 与 renderSVGBlock 共用同一宽度：renderSVGBlock 的 lookup key 走
        // self.cachedRenderer.availableWidth（renderer 持有），而 cachedRenderer
        // 只在 |Δw|>0.5pt 时才重建。若 trigger 直接用 max(bounds.width,1)，
        // 在 <0.5pt 抖动下 trigger 写入的 key 与 lookup 用的 key 不一致 →
        // 已解析 svg 永远 cache miss → marker 永留（Copilot PR #5 R5 #1）。
        // math 不受影响：MathCacheKey 不含 availableWidth。
        let availableWidth = self.cachedRenderer.availableWidth
        // 同步枚举收集 svg 源串。代际相关的 key 构造推迟到下面唯一的 Task 内一次性
        // 完成（generation 受 actor 隔离），与 triggerMathLoads 同形。
        // 注：enumerateAttribute 对相同 value 的 .markdownSVGBlockSource 合并成单次
        // 回调（Foundation 文档：returns the maximum range over which the value applies），
        // 故每个 svg block 自然只产一项，无需 Set 去重（详见 SVGBlockRenderTests
        // missEnumerationCoalescesSameValue —— Copilot PR #5 R3 #2/#3 假设不成立）。
        var svgs: [String] = []
        str.enumerateAttribute(.markdownSVGBlockSource, in: safe) { value, _, _ in
            guard let payload = value as? String else { return }
            svgs.append(payload)
        }
        guard !svgs.isEmpty else {
            return
        }
        Task { [weak self] in
            guard let self else {
                return
            }
            let gen = await self._svgBlockCoordinator.generation
            let requests: [(key: SVGBlockCacheKey, svg: String)] = svgs.map { svg in
                (key: SVGBlockCacheKey(
                    svg: svg, availableWidth: availableWidth,
                    rasterScale: scale, rendererGeneration: gen
                ), svg: svg)
            }
            for r in requests {
                await self._svgBlockCoordinator.loadIfNeeded(
                    key: r.key, svg: r.svg, availableWidth: availableWidth, scale: scale
                )
            }
            var resolved: [(key: SVGBlockCacheKey, glyph: SVGBlockGlyph)] = []
            for r in requests {
                if let glyph = await self._svgBlockCoordinator.awaitGlyph(for: r.key) {
                    resolved.append((key: r.key, glyph: glyph))
                }
            }
            guard !resolved.isEmpty else {
                return
            }
            await MainActor.run {
                // 真值源是 view-held store（与 _mathCache 同款）—— resetLayout()
                // 在宽度抖动时丢弃 _cachedRenderer，下次 cachedRenderer 重建会从
                // 这里重播种；同时也写当前 transient renderer。
                self._svgRasterScale = scale
                self._svgBlockRendererGeneration = gen
                self._cachedRenderer?.svgRasterScale = scale
                self._cachedRenderer?.svgRendererGeneration = gen
                for entry in resolved {
                    self._svgBlockCache[entry.key] = entry.glyph
                    self._cachedRenderer?.svgBlockCache[entry.key] = entry.glyph
                }
                self.updateContent()
            }
        }
    }

    private func performCopy() {
        guard let copied = self._copiedStringForCurrentSelection() else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copied, forType: .string)
    }

    /// Single source of truth for "current selection → copied original-source
    /// string": resolve the active TextKit2 selection, convert it to a
    /// rendered-plain-text offset range, and map that range back to the
    /// original Markdown source via `copyString`. Returns `nil` when there is
    /// no usable selection (no selection / empty range) so callers can no-op.
    /// Production `performCopy()` writes the result to the pasteboard; the
    /// test seam returns it — keeping both paths on identical logic so they
    /// cannot drift. Symmetric with the iOS implementation.
    private func _copiedStringForCurrentSelection() -> String? {
        guard
            let sel = layoutManager.textSelections.first,
            let range = sel.textRanges.first,
            let str = contentStorage.attributedString?.string else {
            return nil
        }
        let start = self.contentStorage.offset(
            from: self.contentStorage.documentRange.location, to: range.location
        )
        let end = self.contentStorage.offset(
            from: self.contentStorage.documentRange.location, to: range.endLocation
        )
        guard start < end else {
            return nil
        }
        return self.copyString(
            forRenderedRange: NSRange(location: start, length: end - start),
            renderedPlainText: str
        )
    }

    /// Maps a rendered selection range to the original Markdown source it
    /// covers (block-level). Symmetric with the iOS implementation; shared
    /// logic lives in the file-scope `markdownSourceForRenderedSelection`.
    func copyString(forRenderedRange range: NSRange, renderedPlainText: String) -> String {
        markdownSourceForRenderedSelection(
            renderedRange: range,
            renderedPlainText: renderedPlainText,
            blockStarts: self.blockStarts,
            parsedBlocks: self.parsedBlocks,
            renderedLength: self._liveString.length,
            originalSource: self.lastParsedSource
        )
    }
}
#endif
