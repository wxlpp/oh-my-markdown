import Foundation
import MarkdownCore
import MarkdownRenderKit
import Observation

#if canImport(AppKit)
import AppKit

// MARK: - MarkdownLabelView (macOS)

@MainActor
public final class MarkdownLabelView: NSView, RenderSessionSink, RenderSessionResourceProviding, Observable {
    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        self.rasterScaleDidChange(to: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
    }

    private let snapshotRegistrar = ObservationRegistrar()
    private var snapshotStorage: RenderSnapshot?
    package private(set) var currentSnapshot: RenderSnapshot? {
        get {
            self.snapshotRegistrar.access(self, keyPath: \.currentSnapshot)
            return self.snapshotStorage
        }
        set {
            self.snapshotRegistrar.withMutation(of: self, keyPath: \.currentSnapshot) {
                self.snapshotStorage = newValue
            }
        }
    }

    package private(set) var currentCommitToken: RenderCommitToken?
    package private(set) var lastRenderError: RenderSessionError?
    private let sessionRegistry = RenderSessionSinkRegistry()
    private let sessionID = RenderSessionID(rawValue: UUID())
    private let configurationID = MarkdownConfigurationID.uniqueInstance()
    package private(set) var sessionDriver: (any RenderSessionDriving)?
    private var isDismantled = false
    private var requestedWidth: CGFloat = 1
    private var displayScale: CGFloat = 1
    private var renderedDocument: MarkdownDocument?

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
        self.updateContent()
    }

    package func replaceSnapshot(_ snapshot: RenderSnapshot, token: RenderCommitToken) {
        precondition(self.currentCommitToken.map { token.sequence >= $0.sequence } ?? true)
        self.currentCommitToken = token
        self.imageRequests = self.imageRequests.filter { $0.key.token == token }
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
        self.renderedDocument = snapshot.displayModel.preparedDocument
        self.resetLayout()
        let range = NSRange(location: 0, length: snapshot.attributedString.length)
        self.triggerImageLoads(in: range)
        self.triggerMathLoads(in: range)
        self.triggerSVGBlockLoads(in: range)
        for table in snapshot.tableOverlays.values {
            let range = NSRange(location: 0, length: table.attributedString.length)
            self.triggerImageLoads(in: range, string: table.attributedString)
            self.triggerMathLoads(in: range, string: table.attributedString)
            self.triggerSVGBlockLoads(in: range, string: table.attributedString)
        }
        withExtendedLifetime(previousSnapshot) {}
    }

    package func receive(error: RenderSessionError) {
        self.lastRenderError = error
    }

    package func resolvedResources(for model: RenderDisplayModel, configuration: RenderConfigurationSnapshot) -> ResolvedResourceSnapshot {
        var values: [ResourceID: ResolvedPlatformResource] = [:]
        for resource in model.resourceValues {
            switch resource {
            case .image(let id, let source, _):
                if let image = _imageCache[source] {
                    values[id] = .image(image, owner: LegacyResourceOwner(retaining: image))
                }
            case .math(let id, let latex, let display):
                if let key = self.mathKey(latex: latex, display: display, configuration: configuration),
                   let lease = self.driver().resourceTaskOwner.math.publication(for: key) {
                    values[id] = .math(owner: lease)
                }
            case .svg(let id, let source):
                if let key = self.svgKey(source: source, width: model.availableWidth),
                   let lease = self.driver().resourceTaskOwner.svg.publication(for: key) {
                    values[id] = .svg(owner: lease)
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
        self.renderedDocument = nil
        self._tableOverlays.values.forEach { $0.scroll.removeFromSuperview() }
        self._tableOverlays.removeAll()
        self.sessionDriver?.send(.dismantle)
        self.sessionRegistry.revokeAndUnregister(self.sessionID)
        self.sessionDriver = nil
        self._imageCache.removeAll()
        self.imageRequests.removeAll()
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
            self._tableOverlays.values.forEach { $0.scroll.removeFromSuperview() }
            self._tableOverlays.removeAll()
            self.updateContent()
        }
    }

    public var blocks: [BlockNode] {
        get { self.renderedDocument?.blocks ?? [] }
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
    private var lastParsedSource: String {
        self.currentSnapshot?.displayModel.source ?? ""
    }

    private var parsedBlocks: [ParsedBlockNode] {
        self.renderedDocument?.parsedBlocks ?? []
    }

    /// Tracks the public set/append placeholder mode.
    public internal(set) var renderMode: PlaceholderMode = .static

    /// Platform drawing mirror. The immutable current snapshot owns attachments.
    private var _liveString = NSMutableAttributedString()
    /// Last measured intrinsic height — gates invalidateIntrinsicContentSize() calls.
    private var _lastHeight: CGFloat = 0
    /// Coalesces expensive TextKit height queries during streaming updates.
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
    package private(set) var imageRequests: [RenderImageRequest: RenderImageLoadState] = [:]
    package var imageLoader: RenderImageLoader = { url in
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    /// Install a stable wrapper to preserve its completed-cache identity.
    public var mathRenderer: MathRendererConfiguration? {
        didSet {
            guard !self.isDismantled, oldValue?.configurationID != self.mathRenderer?.configurationID else { return }
            self.driver().resourceTaskOwner.math.configure(self.mathRenderer)
            self.updateContent()
        }
    }

    public var svgBlockRenderer: SVGRendererConfiguration? {
        didSet {
            guard !self.isDismantled, oldValue?.configurationID != self.svgBlockRenderer?.configurationID else { return }
            self.driver().resourceTaskOwner.svg.configure(self.svgBlockRenderer)
            self.updateContent()
        }
    }

    /// Horizontal-scroll overlays for table blocks wider than the view, keyed by block index.
    var _tableOverlays: [Int: (
        scroll: NSScrollView,
        content: TableContentView,
        data: RenderTableOverlay,
        naturalWidth: CGFloat
    )] = [:]
    private var _pendingTableOverlaySyncStart: Int?

    private var blockStarts: [Int] = []

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
            self.sessionDriver?.send(.replaceWidth(w))
        }
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
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
        self.driver().resourceTaskOwner.deferAction(key: "height") { [weak self] in
            self?.updateMeasuredHeightIfNeeded()
        }
    }

    private func updateMeasuredHeightIfNeeded() {
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        let newHeight = ceil(layoutManager.usageBoundsForTextContainer.height)
        if abs(newHeight - self._lastHeight) > 0.5 {
            self._lastHeight = newHeight
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    // MARK: Image loading

    private func triggerImageLoads(in range: NSRange, string: NSAttributedString? = nil) {
        guard let str = string ?? contentStorage.attributedString, let token = self.currentCommitToken else { return }
        let safeRange = range.clamped(to: str.length)
        guard safeRange.length > 0 else { return }
        str.enumerateAttribute(.markdownImageSource, in: safeRange) { value, _, _ in
            guard let source = value as? String, self._imageCache[source] == nil else { return }
            let request = RenderImageRequest(token: token, source: source)
            guard self.imageRequests[request] == nil else { return }
            self.imageRequests[request] = .loading
            self.loadImage(request)
        }
    }

    private func loadImage(_ request: RenderImageRequest) {
        let registry = self.sessionRegistry
        guard let url = URL(string: request.source) else {
            registry.withAuthorizedSink(for: request.token) { sink in
                (sink as? MarkdownLabelView)?.finishImageLoadFailure(request)
            }
            return
        }
        let loader = self.imageLoader
        self.driver().resourceTaskOwner.start {
            do {
                let data = try await loader(url)
                try Task.checkCancellation()
                let image = NSImage(data: data)
                registry.withAuthorizedSink(for: request.token) { sink in
                    guard let view = sink as? MarkdownLabelView else { return }
                    if let image { view.finishImageLoad(request, image: image) }
                    else { view.finishImageLoadFailure(request) }
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                      (error as? URLError)?.code != .cancelled else { return }
                registry.withAuthorizedSink(for: request.token) { sink in
                    (sink as? MarkdownLabelView)?.finishImageLoadFailure(request)
                }
            }
        }
    }

    private func finishImageLoad(_ request: RenderImageRequest, image: NSImage) {
        self._imageCache[request.source] = image
        self.imageRequests.removeValue(forKey: request)
        self.updateContent()
    }

    private func finishImageLoadFailure(_ request: RenderImageRequest) {
        self.imageRequests[request] = .failed
    }

    // MARK: Rendered resources

    private func refreshResolvedResources() {
        guard let snapshot = self.currentSnapshot, let token = self.currentCommitToken else { return }
        let configuration = self.configurationSnapshot()
        let resources = self.resolvedResources(for: snapshot.displayModel, configuration: configuration)
        let replacement = RenderMaterializer(configuration: configuration).materialize(snapshot.displayModel, resources: resources)
        self.replaceSnapshot(replacement, token: token)
    }

    private func mathKey(latex: String, display: Bool, configuration: RenderConfigurationSnapshot) -> MathCacheKey? {
        guard let renderer = self.mathRenderer else { return nil }
        let pointSize = MathMetrics.effectivePointSize(textPointSize: configuration.typography.pointSizes[.body] ?? 16, mathScale: configuration.mathScale)
        return MathCacheKey(
            latex: latex,
            display: display,
            pointSize: pointSize,
            colorHex: MathMetrics.colorHex(self.renderStyle.mathColorOverride ?? self.renderStyle.textColor),
            rasterScale: self.displayScale,
            configurationID: renderer.configurationID
        )
    }

    private func svgKey(source: String, width: Double) -> SVGBlockCacheKey? {
        guard let renderer = self.svgBlockRenderer else { return nil }
        return SVGBlockCacheKey(svg: source, availableWidth: width, rasterScale: self.displayScale, configurationID: renderer.configurationID)
    }

    private func triggerMathLoads(in range: NSRange, string: NSAttributedString? = nil) {
        guard let str = string ?? contentStorage.attributedString, let token = self.currentCommitToken else { return }
        let registry = self.sessionRegistry
        let owner = self.driver().resourceTaskOwner
        let configuration = self.configurationSnapshot()
        str.enumerateAttribute(.markdownMathSource, in: range.clamped(to: str.length)) { value, _, _ in
            guard let payload = value as? String, let separator = payload.firstIndex(of: "\u{1F}"),
                  let key = self.mathKey(latex: String(payload[payload.index(after: separator)...]), display: payload.first == "1", configuration: configuration) else { return }
            owner.math.load(key, isCurrent: {
                registry.withAuthorizedSink(for: token) { _ in }
            }, completed: { [weak owner] in
                owner?.deferAction(key: "resources") {
                    registry.withAuthorizedSink(for: token) { sink in
                        (sink as? MarkdownLabelView)?.refreshResolvedResources()
                    }
                }
            })
        }
    }

    private func triggerSVGBlockLoads(in range: NSRange, string: NSAttributedString? = nil) {
        guard let str = string ?? contentStorage.attributedString, let token = self.currentCommitToken else { return }
        let registry = self.sessionRegistry
        let owner = self.driver().resourceTaskOwner
        let width = self.currentSnapshot?.displayModel.availableWidth ?? self.requestedWidth
        str.enumerateAttribute(.markdownSVGBlockSource, in: range.clamped(to: str.length)) { value, _, _ in
            guard let source = value as? String, let key = self.svgKey(source: source, width: width) else { return }
            owner.svg.load(key, isCurrent: {
                registry.withAuthorizedSink(for: token) { _ in }
            }, completed: { [weak owner] in
                owner?.deferAction(key: "resources") {
                    registry.withAuthorizedSink(for: token) { sink in
                        (sink as? MarkdownLabelView)?.refreshResolvedResources()
                    }
                }
            })
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
