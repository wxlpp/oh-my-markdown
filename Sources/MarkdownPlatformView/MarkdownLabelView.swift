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
        guard
            let sel = layoutManager.textSelections.first,
            let range = sel.textRanges.first,
            let str = contentStorage.attributedString?.string else {
            return
        }
        let start = self.contentStorage.offset(
            from: self.contentStorage.documentRange.location, to: range.location
        )
        let end = self.contentStorage.offset(
            from: self.contentStorage.documentRange.location, to: range.endLocation
        )
        guard start < end else {
            return
        }
        UIPasteboard.general.string = (str as NSString).substring(
            with: NSRange(location: start, length: end - start)
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
        self._parseSerial += 1
        self._parseTask?.cancel()
        self._parseTask = nil
        self._pendingParseAfterCurrent = false
        self.streamingSource = source
        self.scheduleParse(delayNanoseconds: 0)
    }

    public func appendMarkdown(_ chunk: String) {
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
    /// Canonical mutable store — avoids O(n) mutableCopy() per streaming token.
    private var _liveString = NSMutableAttributedString()
    /// Last measured intrinsic height — gates invalidateIntrinsicContentSize() calls.
    private var _lastHeight: CGFloat = 0
    /// Coalesces expensive TextKit height queries during streaming updates.
    private var _heightUpdateTask: Task<Void, Never>?
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
    private let _mathCoordinator = MathLoadCoordinator()
    /// Injected math renderer; swapping it bumps the coordinator's generation.
    public var mathRenderer: (any MathRendering)? {
        // setRenderer 异步派发；落地前发生的渲染会显示 latex 占位，并在下次
        // updateContent/relayout 时解析（有意为之的最终一致性）。
        didSet { Task { await self._mathCoordinator.setRenderer(self.mathRenderer) } }
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
            var renderer = AttributedStringRenderer(style: renderStyle, availableWidth: w)
            renderer.imageCache = self._imageCache
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
        self._pendingTableOverlaySyncStart = nil
        self._syncTableOverlays(from: 0)
    }

    private func scheduleDeferredHeightUpdate() {
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
                self._cachedRenderer?.mathRasterScale = scale
                self._cachedRenderer?.mathRendererGeneration = gen
                for entry in resolved {
                    self._cachedRenderer?.mathCache[entry.key] = entry.glyph
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
                let renderer = AttributedStringRenderer(style: renderStyle, availableWidth: naturalWidth)
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
            let renderer = AttributedStringRenderer(style: renderStyle, availableWidth: naturalWidth)
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
            case "c": self.performCopy()
                return
            default: break
            }
        }
        super.keyDown(with: event)
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

    public func setMarkdown(_ source: String) {
        self._parseSerial += 1
        self._parseTask?.cancel()
        self._parseTask = nil
        self._pendingParseAfterCurrent = false
        self.streamingSource = source
        self.scheduleParse(delayNanoseconds: 0)
    }

    public func appendMarkdown(_ chunk: String) {
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
    /// Canonical mutable store — avoids O(n) mutableCopy() per streaming token.
    private var _liveString = NSMutableAttributedString()
    /// Last measured intrinsic height — gates invalidateIntrinsicContentSize() calls.
    private var _lastHeight: CGFloat = 0
    /// Coalesces expensive TextKit height queries during streaming updates.
    private var _heightUpdateTask: Task<Void, Never>?
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
    private let _mathCoordinator = MathLoadCoordinator()
    /// Injected math renderer; swapping it bumps the coordinator's generation.
    public var mathRenderer: (any MathRendering)? {
        // setRenderer 异步派发；落地前发生的渲染会显示 latex 占位，并在下次
        // updateContent/relayout 时解析（有意为之的最终一致性）。
        didSet { Task { await self._mathCoordinator.setRenderer(self.mathRenderer) } }
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
            var renderer = AttributedStringRenderer(style: renderStyle, availableWidth: w)
            renderer.imageCache = self._imageCache
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
        self._pendingTableOverlaySyncStart = nil
        self._syncTableOverlays(from: 0)
    }

    private func scheduleDeferredHeightUpdate() {
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
                let renderer = AttributedStringRenderer(style: renderStyle, availableWidth: naturalWidth)
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
            let renderer = AttributedStringRenderer(style: renderStyle, availableWidth: naturalWidth)
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
                self._cachedRenderer?.mathRasterScale = scale
                self._cachedRenderer?.mathRendererGeneration = gen
                for entry in resolved {
                    self._cachedRenderer?.mathCache[entry.key] = entry.glyph
                }
                self.updateContent()
            }
        }
    }

    private func performCopy() {
        guard
            let sel = layoutManager.textSelections.first,
            let range = sel.textRanges.first,
            let str = contentStorage.attributedString?.string else {
            return
        }
        let start = self.contentStorage.offset(
            from: self.contentStorage.documentRange.location, to: range.location
        )
        let end = self.contentStorage.offset(
            from: self.contentStorage.documentRange.location, to: range.endLocation
        )
        guard start < end else {
            return
        }
        let nsStr = str as NSString
        let copied = nsStr.substring(with: NSRange(location: start, length: end - start))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copied, forType: .string)
    }
}
#endif
