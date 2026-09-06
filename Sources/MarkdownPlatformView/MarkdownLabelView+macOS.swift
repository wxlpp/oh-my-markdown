import Foundation
import MarkdownCore
import MarkdownRenderKit

#if canImport(AppKit)
import AppKit

// MARK: - MarkdownLabelView (macOS)

@MainActor
public final class MarkdownLabelView: NSView, RenderSessionSink, RenderSessionResourceProviding {
    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        self.rasterScaleDidChange(to: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
    }

    package private(set) var currentSnapshot: RenderSnapshot?
    package private(set) var currentCommitToken: RenderCommitToken?
    package private(set) var lastRenderError: RenderSessionError?
    private let sessionRegistry = RenderSessionSinkRegistry()
    private let sessionID = RenderSessionID(rawValue: UUID())
    private let configurationID = MarkdownConfigurationID.uniqueInstance()
    private var sessionDriver: (any RenderSessionDriving)?
    private var isDismantled = false
    private var requestedWidth: CGFloat = 1
    private var mathRendererUpdateTask: Task<Void, Never>?
    private var svgRendererUpdateTask: Task<Void, Never>?
    private var displayScale: CGFloat = 1
    private var renderedBlocks: [BlockNode] = []

    package convenience init(frame: CGRect, driver: any RenderSessionDriving) {
        self.init(frame: frame)
        self.sessionDriver = driver
    }

    private func configurationSnapshot() -> RenderConfigurationSnapshot {
        MarkdownRenderConfiguration(style: self.renderStyle, configurationID: self.configurationID).snapshot(generation: 0)
    }

    private func driver() -> any RenderSessionDriving {
        if let sessionDriver { return sessionDriver }
        let session = MarkdownRenderSession(id: sessionID, registry: sessionRegistry, availableWidth: requestedWidth, configuration: configurationSnapshot())
        self.sessionRegistry.register(self, for: self.sessionID)
        let driver = MarkdownRenderSessionDriver(session: session)
        sessionDriver = driver
        return driver
    }

    package func rasterScaleDidChange(to scale: CGFloat) {
        guard !self.isDismantled, scale.isFinite, scale > 0, scale != self.displayScale else { return }
        self.displayScale = scale
        self._mathRasterScale = scale
        self._svgRasterScale = scale
        self._mathCache.removeAll()
        self._svgBlockCache.removeAll()
        self._cachedRenderer = nil
        self.updateContent()
    }

    package func replaceSnapshot(_ snapshot: RenderSnapshot, token: RenderCommitToken) {
        precondition(self.currentCommitToken.map { token.sequence >= $0.sequence } ?? true)
        self.currentCommitToken = token
        self.lastRenderError = nil
        let previousSnapshot = self.currentSnapshot
        self.contentStorage.performEditingTransaction {
            self.contentStorage.attributedString = NSAttributedString(string: "")
            self.currentSnapshot = nil
            self.currentSnapshot = snapshot
            self.contentStorage.attributedString = snapshot.attributedString
        }
        self._liveString = NSMutableAttributedString(attributedString: snapshot.attributedString)
        self.blockStarts = snapshot.blockStarts
        self.parsedBlocks = snapshot.displayModel.preparedBlocks ?? []
        self.renderedBlocks = self.parsedBlocks.map(\.block)
        self.lastParsedSource = snapshot.displayModel.source ?? ""
        self._cachedRenderer = nil
        self._cachedRendererWidth = snapshot.displayModel.availableWidth
        self.resetLayout()
        let range = NSRange(location: 0, length: snapshot.attributedString.length)
        self.triggerImageLoads(in: range)
        self.triggerMathLoads(in: range)
        self.triggerSVGBlockLoads(in: range)
        withExtendedLifetime(previousSnapshot) {}
    }

    package func receive(error: RenderSessionError) {
        self.lastRenderError = error
    }

    package func resolvedResources(for model: RenderDisplayModel, configuration: RenderConfigurationSnapshot) -> ResolvedResourceSnapshot {
        var values: [ResourceID: ResolvedPlatformResource] = [:]
        for resource in model.resources {
            switch resource {
            case .image(let id, let source, _):
                if let image = _imageCache[source] {
                    values[id] = .image(image, owner: LegacyResourceOwner(retaining: image))
                }
            case .math(let id, let latex, let display):
                let pt = MathMetrics.effectivePointSize(textPointSize: configuration.typography.pointSizes[.body] ?? 16, mathScale: configuration.mathScale)
                let key = MathCacheKey(latex: latex, display: display, pointSize: pt, colorHex: MathMetrics.colorHex(self.renderStyle.mathColorOverride ?? self.renderStyle.textColor), rasterScale: self._mathRasterScale, rendererGeneration: self._mathRendererGeneration)
                if let glyph = _mathCache[key] {
                    values[id] = .math(image: glyph.image, baselineOffset: glyph.baselineOffsetEx * pt * 0.5, owner: LegacyResourceOwner(retaining: glyph as AnyObject))
                }
            case .svg(let id, let source):
                let key = SVGBlockCacheKey(svg: source, availableWidth: model.availableWidth, rasterScale: self._svgRasterScale, rendererGeneration: self._svgBlockRendererGeneration)
                if let glyph = _svgBlockCache[key] {
                    values[id] = .svg(glyph.image, owner: LegacyResourceOwner(retaining: glyph as AnyObject))
                }
            }
        }
        return ResolvedResourceSnapshot(values: values)
    }

    package func dismantleRenderSession() {
        guard !self.isDismantled else { return }
        self.isDismantled = true
        let previousSnapshot = self.currentSnapshot
        self.contentStorage.performEditingTransaction {
            self.contentStorage.attributedString = NSAttributedString(string: "")
            self.currentSnapshot = nil
        }
        self._liveString = NSMutableAttributedString(string: "")
        self.blockStarts = []
        self.parsedBlocks = []
        self.renderedBlocks = []
        self.lastParsedSource = ""
        self.mathRendererUpdateTask?.cancel()
        self.svgRendererUpdateTask?.cancel()
        self.mathRendererUpdateTask = nil
        self.svgRendererUpdateTask = nil
        self._heightUpdateTask?.cancel()
        self._heightUpdateTask = nil
        self._tableOverlays.values.forEach { $0.scroll.removeFromSuperview() }
        self._tableOverlays.removeAll()
        self.sessionDriver?.send(.dismantle)
        self.sessionRegistry.revokeAndUnregister(self.sessionID)
        self.sessionDriver = nil
        self._cachedRenderer = nil
        self._imageCache.removeAll()
        self._mathCache.removeAll()
        self._svgBlockCache.removeAll()
        withExtendedLifetime(previousSnapshot) {}
    }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        self.requestedWidth = max(frame.width, 1)
        self.displayScale = NSScreen.main?.backingScaleFactor ?? 1
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

    public var blocks: [BlockNode] {
        get { self.renderedBlocks }
        set {
            guard !self.isDismantled else { return }
            self.driver().send(.setDocument(MarkdownDocument(parsedBlocks: newValue.map { ParsedBlockNode(block: $0) }), self.configurationSnapshot()))
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
        guard !self.isDismantled else { return }
        self.renderMode = .static
        self.driver().send(.setSource(source, self.configurationSnapshot()))
    }

    public func appendMarkdown(_ chunk: String) {
        guard !self.isDismantled else { return }
        self.renderMode = .streaming
        self.driver().send(.append(chunk))
    }

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(
        size: CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    )
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

    /// Platform drawing mirror. The immutable current snapshot owns attachments.
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
        didSet {
            guard !self.isDismantled, oldValue !== self.mathRenderer else { return }
            self._mathCache.removeAll()
            self._cachedRenderer = nil
            let coordinator = self._mathCoordinator
            let renderer = self.mathRenderer
            let previousUpdate = self.mathRendererUpdateTask
            self.mathRendererUpdateTask = self.driver().resourceTaskOwner.start {
                await previousUpdate?.value
                guard !Task.isCancelled else { return }
                await coordinator.setRenderer(renderer)
            }
            self.updateContent()
        }
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
        didSet {
            guard !self.isDismantled, oldValue !== self.svgBlockRenderer else { return }
            self._svgBlockCache.removeAll()
            self._cachedRenderer = nil
            let coordinator = self._svgBlockCoordinator
            let renderer = self.svgBlockRenderer
            let previousUpdate = self.svgRendererUpdateTask
            self.svgRendererUpdateTask = self.driver().resourceTaskOwner.start {
                await previousUpdate?.value
                guard !Task.isCancelled else { return }
                await coordinator.setRenderer(renderer)
            }
            self.updateContent()
        }
    }

    /// Horizontal-scroll overlays for table blocks wider than the view, keyed by block index.
    var _tableOverlays: [Int: (
        scroll: NSScrollView,
        content: TableContentView,
        block: BlockNode,
        naturalWidth: CGFloat
    )] = [:]
    private var _pendingTableOverlaySyncStart: Int?

    private var blockStarts: [Int] = []

    private var cachedRenderer: AttributedStringRenderer {
        let w = self.requestedWidth
        if self._cachedRenderer == nil || abs(w - self._cachedRendererWidth) > 0.5 {
            var renderer = AttributedStringRenderer(
                style: renderStyle, availableWidth: w, placeholderMode: self.renderMode
            )
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

    var decorations: MarkdownLabelDecorations {
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
        guard !self.isDismantled else { return }
        self.driver().send(.replaceConfiguration(self.configurationSnapshot()))
    }

    private func resetLayout() {
        let w = max(bounds.width, 1)
        self.textContainer.size = CGSize(width: w, height: .greatestFiniteMagnitude)
        if abs(w - self.requestedWidth) > 0.5 {
            self.requestedWidth = w
            self._cachedRenderer = nil
            self.sessionDriver?.send(.replaceWidth(w))
        }
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        self._heightUpdateTask?.cancel()
        self._heightUpdateTask = nil
        self._lastHeight = ceil(self.layoutManager.usageBoundsForTextContainer.height)
        invalidateIntrinsicContentSize()
        needsDisplay = true
        // Preserve host-relayout discipline: asynchronous resource snapshots
        // can shrink
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
        guard let url = URL(string: source), let token = currentCommitToken else {
            self._imageLoading.remove(source)
            return
        }
        let registry = self.sessionRegistry
        self.driver().resourceTaskOwner.start { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try Task.checkCancellation()
                if let image = NSImage(data: data) {
                    let applied = registry.withAuthorizedSink(for: token) { sink in
                        (sink as? MarkdownLabelView)?.finishImageLoad(source: source, image: image)
                    }
                    if !applied { self?._imageLoading.remove(source) }
                } else { self?.finishImageLoadFailure(source: source) }
            } catch { self?.finishImageLoadFailure(source: source) }
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
        let scale = self.displayScale
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
        guard let token = currentCommitToken else { return }
        let registry = self.sessionRegistry
        let coordinator = self._mathCoordinator
        let rendererUpdate = self.mathRendererUpdateTask
        self.driver().resourceTaskOwner.start {
            await rendererUpdate?.value
            guard !Task.isCancelled else { return }
            let gen = await coordinator.generation
            guard !Task.isCancelled else { return }
            let requests: [(
                key: MathCacheKey,
                latex: String,
                display: Bool,
                color: PlatformColor,
                pt: CGFloat
            )] = raw.map {
                let key = MathCacheKey(
                    latex: $0.latex, display: $0.display, pointSize: $0.pt,
                    colorHex: MathMetrics.colorHex($0.color),
                    rasterScale: scale, rendererGeneration: gen
                )
                return (
                    key: key,
                    latex: $0.latex,
                    display: $0.display,
                    color: $0.color,
                    pt: $0.pt
                )
            }
            // 先派发全部渲染（去重由 coordinator 负责）。
            for r in requests {
                guard !Task.isCancelled else { return }
                await coordinator.loadIfNeeded(
                    key: r.key, latex: r.latex, display: r.display,
                    pointSize: r.pt, scale: scale, color: r.color
                )
            }
            // 仅 await 各自 key 的在途任务，收集解析出的字形。
            var resolved: [(key: MathCacheKey, glyph: MathRenderedGlyph)] = []
            for r in requests {
                guard !Task.isCancelled else { return }
                if let glyph = await coordinator.awaitGlyph(for: r.key) {
                    resolved.append((key: r.key, glyph: glyph))
                }
            }
            guard !Task.isCancelled, !resolved.isEmpty else {
                return
            }
            // 一次性合并回写并仅触发一次 updateContent（镜像图片加载纪律）。
            registry.withAuthorizedSink(for: token) { sink in
                guard let view = sink as? MarkdownLabelView else { return }
                // 真值源是 view-held store —— resetLayout() 在宽度抖动时会
                // 丢弃 _cachedRenderer，下次 cachedRenderer 重建会从这里
                // 重播种；同时也写当前 transient renderer（与
                // finishImageLoad 同时写 _imageCache 与 _cachedRenderer?
                // 完全同构）。
                view._mathRasterScale = scale
                view._mathRendererGeneration = gen
                view._cachedRenderer?.mathRasterScale = scale
                view._cachedRenderer?.mathRendererGeneration = gen
                for entry in resolved {
                    view._mathCache[entry.key] = entry.glyph
                    view._cachedRenderer?.mathCache[entry.key] = entry.glyph
                }
                view.updateContent()
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
        let scale = self.displayScale
        // 与 renderSVGBlock 共用同一宽度：renderSVGBlock 的 lookup key 走
        // self.cachedRenderer.availableWidth（renderer 持有），而 cachedRenderer
        // 只在 |Δw|>0.5pt 时才重建。若 trigger 直接用 max(bounds.width,1)，
        // 在 <0.5pt 抖动下 trigger 写入的 key 与 lookup 用的 key 不一致 →
        // 已解析 svg 永远 cache miss → marker 永留（Copilot PR #5 R5 #1）。
        // math 不受影响：MathCacheKey 不含 availableWidth。
        let availableWidth = self.currentSnapshot?.displayModel.availableWidth ?? self.requestedWidth
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
        guard let token = currentCommitToken else { return }
        let registry = self.sessionRegistry
        let coordinator = self._svgBlockCoordinator
        let rendererUpdate = self.svgRendererUpdateTask
        self.driver().resourceTaskOwner.start {
            await rendererUpdate?.value
            guard !Task.isCancelled else { return }
            let gen = await coordinator.generation
            guard !Task.isCancelled else { return }
            let requests: [(key: SVGBlockCacheKey, svg: String)] = svgs.map { svg in
                (key: SVGBlockCacheKey(
                    svg: svg, availableWidth: availableWidth,
                    rasterScale: scale, rendererGeneration: gen
                ), svg: svg)
            }
            for r in requests {
                guard !Task.isCancelled else { return }
                await coordinator.loadIfNeeded(
                    key: r.key, svg: r.svg, availableWidth: availableWidth, scale: scale
                )
            }
            var resolved: [(key: SVGBlockCacheKey, glyph: SVGBlockGlyph)] = []
            for r in requests {
                guard !Task.isCancelled else { return }
                if let glyph = await coordinator.awaitGlyph(for: r.key) {
                    resolved.append((key: r.key, glyph: glyph))
                }
            }
            guard !Task.isCancelled, !resolved.isEmpty else {
                return
            }
            registry.withAuthorizedSink(for: token) { sink in
                guard let view = sink as? MarkdownLabelView else { return }
                // 真值源是 view-held store（与 _mathCache 同款）—— resetLayout()
                // 在宽度抖动时丢弃 _cachedRenderer，下次 cachedRenderer 重建会从
                // 这里重播种；同时也写当前 transient renderer。
                view._svgRasterScale = scale
                view._svgBlockRendererGeneration = gen
                view._cachedRenderer?.svgRasterScale = scale
                view._cachedRenderer?.svgRendererGeneration = gen
                for entry in resolved {
                    view._svgBlockCache[entry.key] = entry.glyph
                    view._cachedRenderer?.svgBlockCache[entry.key] = entry.glyph
                }
                view.updateContent()
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
