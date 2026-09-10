import Foundation
import MarkdownCore
import MarkdownRenderKit
import Observation

#if canImport(UIKit)
import UIKit

// MARK: - MarkdownLabelView (iOS)

@MainActor
public final class MarkdownLabelView: UIView, RenderSessionSink, RenderSessionResourceProviding, Observable {
    override public func didMoveToWindow() {
        super.didMoveToWindow()
        self.rasterScaleDidChange(to: window?.screen.scale ?? UIScreen.main.scale)
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
    /// Session-owned image admission, exposed for residency assertions.
    package var imageCoordinator: ImageLoadCoordinator? {
        self.sessionDriver?.resourceTaskOwner.images
    }

    private var isDismantled = false
    private var requestedWidth: CGFloat = 1
    private var displayScale: CGFloat = 1
    private var renderedDocument: MarkdownDocument?

    package convenience init(frame: CGRect, driver: any RenderSessionDriving) {
        self.init(frame: frame)
        self.sessionDriver = driver
    }

    private func configurationSnapshot() -> RenderConfigurationSnapshot {
        MarkdownRenderConfiguration(
            style: self.renderStyle, configurationID: self.configurationID,
            contentSizeCategory: self.contentSizeCategory
        ).snapshot(generation: 0)
    }

    /// The reader's text size, mirrored from the trait environment. Assigning it
    /// directly is what a host does to pin a size; a trait change overwrites that.
    public var contentSizeCategory: MarkdownContentSizeCategory {
        get { self.contentSizeCategoryStorage }
        set {
            guard newValue != self.contentSizeCategoryStorage else { return }
            self.contentSizeCategoryStorage = newValue
            self.discardStyleDependentChrome()
            self.updateContent()
        }
    }

    /// Written directly during init: going through the setter there would build
    /// the render session before a `package` caller can supply its own driver.
    private var contentSizeCategoryStorage: MarkdownContentSizeCategory = .large

    /// Table overlays carry the metrics they were built with, so a typography
    /// change has to drop them rather than reuse them at the new size.
    private func discardStyleDependentChrome() {
        self._tableOverlays.values.forEach { $0.scroll.removeFromSuperview() }
        self._tableOverlays.removeAll()
    }

    private func driver() -> any RenderSessionDriving {
        if let sessionDriver { return sessionDriver }
        let session = MarkdownRenderSession(
            id: sessionID, executor: sessionOverrides.executor, registry: self.sessionRegistry,
            clock: self.sessionOverrides.clock, availableWidth: self.requestedWidth, configuration: self.configurationSnapshot()
        )
        self.sessionRegistry.register(self, for: self.sessionID)
        let driver = MarkdownRenderSessionDriver(session: session, residency: self.sessionOverrides.residency)
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
        // Rebuilds the accessibility elements on the way out, once: the frames
        // come from laid-out text segments, and `_syncTableOverlays` is the last
        // step that can move them.
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
        self.observation.signal()
    }

    package func receive(error: RenderSessionError) {
        self.lastRenderError = error
        self.observation.signal()
    }

    package func resolvedResources(for model: RenderDisplayModel, configuration: RenderConfigurationSnapshot) -> ResolvedResourceSnapshot {
        guard !self.isDismantled else { return ResolvedResourceSnapshot(values: [:]) }
        var values: [ResourceID: ResolvedPlatformResource] = [:]
        for resource in model.resourceValues {
            switch resource {
            case .image(let id, let source, _):
                if let url = URL(string: source), let lease = self.driver().resourceTaskOwner.images.publication(for: url) {
                    values[id] = .image(lease.backing.image, owner: lease)
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
        self.imageRequests.removeAll()
        withExtendedLifetime(previousSnapshot) {}
    }

    // MARK: Init

    override public init(frame: CGRect) {
        super.init(frame: frame)
        self.requestedWidth = max(frame.width, 1)
        self.displayScale = UIScreen.main.scale
        self.buildStack()
        self.buildInteraction()
        self.contentSizeCategoryStorage = MarkdownContentSizeCategory(traitCollection.preferredContentSizeCategory)
        self.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: Self, _) in
            view.contentSizeCategory = MarkdownContentSizeCategory(view.traitCollection.preferredContentSizeCategory)
        }
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
            self.discardStyleDependentChrome()
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

    // MARK: Copy action

    /// Don't widen this to `super` for the default menu: returning `false` for
    /// everything but the two copy commands is what keeps Share, Look Up and
    /// Translate — each of which can hand a URL to the system — off a rendered
    /// link.
    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(self.copy(_:)) || action == #selector(self.copyMarkdownSource(_:)) {
            return !(self.layoutManager.textSelections.first?.textRanges.first?.isEmpty ?? true)
        }
        return false
    }

    /// Cmd-C and the Copy menu item: exactly the selected text, as a reader sees
    /// it. Copying the Markdown source is a separate, explicit command — before
    /// Task 9 this pasted the whole source block of anything the selection
    /// touched, which is more than the user selected.
    @objc
    override public func copy(_ sender: Any?) {
        guard let result = renderedSelectionResult() else { return }
        UIPasteboard.general.string = result.text
    }

    @objc
    public func copyMarkdownSource(_ sender: Any?) {
        guard let result = markdownSourceSelectionResult() else { return }
        UIPasteboard.general.string = result.text
    }

    /// Adds the command to the **main menu**, which is the menu bar on iPad and
    /// Mac Catalyst. It does not reach the selection callout: that menu is
    /// presented by `UITextInteraction`, not built from this responder. SwiftUI
    /// hosts reach the command through `MarkdownSelectionProxy` instead.
    override public func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        // Explicit identifiers: UIKit builds the menu once per responder in the
        // chain, so anonymous ones would append a duplicate item per Markdown
        // view rather than replace.
        let command = UICommand(
            title: MarkdownCopyCommandTitle.markdownSource,
            action: #selector(self.copyMarkdownSource(_:)),
            propertyList: nil,
            alternates: []
        )
        let menu = UIMenu(
            title: "", identifier: UIMenu.Identifier("OhMyMarkdown.copyMarkdownSource"),
            options: .displayInline, children: [command]
        )
        builder.insertSibling(menu, afterMenu: .standardEdit)
    }

    /// Rendered offsets of the active selection, or `nil` when nothing is
    /// selected. Kept per platform so the shared copy code needs no access to
    /// the private TextKit objects.
    func currentRenderedSelectionRange() -> NSRange? {
        guard
            let selection = layoutManager.textSelections.first,
            let range = selection.textRanges.first else { return nil }
        let start = self.contentStorage.offset(from: self.contentStorage.documentRange.location, to: range.location)
        let end = self.contentStorage.offset(from: self.contentStorage.documentRange.location, to: range.endLocation)
        guard start < end else { return nil }
        return NSRange(location: start, length: end - start)
    }

    var renderedAttributedStringForCopy: NSAttributedString? {
        self.contentStorage.attributedString
    }

    /// Reused platform objects, keyed by the identity that survives streaming.
    var accessibilityElementStore: [AccessibilityNodeID: MarkdownAccessibilityElement] = [:]
    var orderedAccessibilityElements: [MarkdownAccessibilityElement] = []
    var isRebuildingAccessibilityElements = false
    var needsAccessibilityRebuild = false
    /// The objects the accessibility client holds, reused across snapshots so a
    /// surviving leaf keeps the element a reader is focused on.
    var accessibilityWrapperStore: [AccessibilityNodeID: MarkdownAccessibilityUIElement] = [:]

    /// Public read-only view of what a screen reader would traverse.
    package var markdownAccessibilityElements: [MarkdownAccessibilityElement] {
        self.orderedAccessibilityElements
    }

    /// On-screen extents for leaf ranges, in one pass.
    ///
    /// Resolving each range from the document start is O(offset), so doing it
    /// per leaf is quadratic in document size — measured at 0.4 s for a
    /// 400-paragraph document, on the main actor, once per streamed chunk. The
    /// ranges are walked in ascending order with a single advancing cursor
    /// instead.
    func accessibilityFrames(forRenderedRanges ranges: [(key: AccessibilityLeafKey, range: NSRange)]) -> [AccessibilityLeafKey: CGRect] {
        guard !ranges.isEmpty else { return [:] }
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        let start = self.contentStorage.documentRange.location
        var cursor = start
        var cursorOffset = 0
        var result: [AccessibilityLeafKey: CGRect] = [:]
        for (key, range) in ranges.sorted(by: { $0.range.location < $1.range.location }) {
            guard
                let from = self.contentStorage.location(cursor, offsetBy: range.location - cursorOffset),
                let to = self.contentStorage.location(from, offsetBy: range.length),
                let textRange = NSTextRange(location: from, end: to) else { continue }
            cursor = from
            cursorOffset = range.location
            var frame = CGRect.null
            self.layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
                frame = frame.isNull ? rect : frame.union(rect)
                return true
            }
            if !frame.isNull, !frame.isEmpty { result[key] = frame }
        }
        return result
    }

    func activateAccessibilityLink(_ url: URL) {
        self.driver().activateLink(url, sourceRange: nil)
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

    /// Maps a rendered selection to the Markdown source it covers, reporting how
    /// faithful the result is. Symmetric with the other platform; the mapping
    /// itself is the file-scope `markdownSourceCopy`.
    func markdownSourceCopy(
        forRenderedRange range: NSRange, renderedPlainText: String,
        renderedFallback: @escaping (NSRange) -> String,
        reconstructedSource: @escaping (NSRange) -> String
    ) -> MarkdownCopyResult {
        MarkdownPlatformView.markdownSourceCopy(
            renderedRange: range,
            renderedPlainText: renderedPlainText,
            blockStarts: self.blockStarts,
            parsedBlocks: self.parsedBlocks,
            renderedLength: self._liveString.length,
            originalSource: self.lastParsedSource,
            renderedFallback: renderedFallback,
            reconstructedSource: reconstructedSource
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
        guard !self.isDismantled else { return }
        self.renderMode = .static
        self.driver().send(.setSource(source, self.configurationSnapshot()))
    }

    public func appendMarkdown(_ chunk: String) {
        guard !self.isDismantled else { return }
        self.renderMode = .streaming
        self.driver().send(.append(chunk))
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

    private func updateContent() {
        guard !self.isDismantled else { return }
        self.driver().send(.replaceConfiguration(self.configurationSnapshot()))
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

    /// Receives the system `highlightView` as a subview. Inserted at index 0
    /// so it sits below the main view's `draw(_:)` content in z-order.
    private let highlightContainerView = UIView()

    /// Bundles long-press selection, handle dragging, and Copy/Share menu (no keyboard).
    private var textInteraction: UITextInteraction!

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
    /// Test seam: session-level injection. Assign before the first render.
    package var sessionOverrides = RenderSessionOverrides()
    /// Test seam: forces the snapshot-replacement install closure to throw.
    package var _materializationFailureForTesting: (any Error)?
    /// Every full re-materialization of the display model, including the ones each
    /// coalesced batch of resolved resources triggers. Bounds the cost that
    /// per-arrival resource completion imposes on a long document.
    package private(set) var _materializationCount = 0 {
        didSet { self.observation.signal() }
    }

    /// Source URLs currently being fetched (prevents duplicate requests).
    package private(set) var imageRequests: [RenderImageRequest: RenderImageLoadState] = [:] {
        didSet { self.observation.signal() }
    }

    /// Reports every observable render change — a snapshot install, an error, a
    /// resource state change, a re-materialization. Resource state goes through
    /// a `didSet` rather than a hand-placed call so a new mutation site cannot
    /// forget it.
    package nonisolated let observation = RenderObservationPoint()

    /// Remote images remain placeholders until the host explicitly opts in.
    public var remoteImages: MarkdownImageConfiguration = .disabled {
        didSet {
            guard !self.isDismantled else { return }
            self.imageRequests.removeAll()
            self.driver().resourceTaskOwner.images.configure(self.remoteImages)
            self.driver().send(.replaceImageConfiguration(self.remoteImages))
        }
    }

    public var onResourceError: MarkdownResourceErrorHandler?

    /// Web-only policy and the platform opener until a host replaces them.
    /// Non-optional: a UIKit/AppKit host revokes by assigning `.platformDefault`,
    /// there being nothing to clear. Only the SwiftUI environment entry reverts on
    /// its own, and only on the edge where a configuration is taken away.
    public var linkConfiguration: MarkdownLinkConfiguration = .platformDefault {
        didSet {
            // Always forwarded: the driver decides what counts as a replacement.
            // Suppressing this on equal identities would leave a superseded
            // policy deciding activations.
            guard !self.isDismantled else { return }
            self.driver().replaceLinkConfiguration(self.linkConfiguration)
        }
    }

    /// Returns whether the offset carried an activatable link. The decision is
    /// asynchronous and may still be refused; the platform opener is never called
    /// from here.
    @discardableResult
    package func activateLink(at offset: Int) -> Bool {
        guard !self.isDismantled, let string = contentStorage.attributedString,
              offset >= 0, offset < string.length else { return false }
        let attributes = string.attributes(at: offset, effectiveRange: nil)
        let url: URL? = if let value = attributes[.link] as? URL {
            value
        } else if let value = attributes[.link] as? String {
            URL(string: value)
        } else {
            nil
        }
        guard let url else { return false }
        self.driver().activateLink(url, sourceRange: nil)
        return true
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
        scroll: UIScrollView,
        content: TableContentView,
        data: RenderTableOverlay,
        naturalWidth: CGFloat
    )] = [:]
    private var _pendingTableOverlaySyncStart: Int?
    /// Set by UITextInteraction so it can be notified of selection changes.
    weak var _inputDelegate: (any UITextInputDelegate)?

    // MARK: Content

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
        if abs(w - self.requestedWidth) > 0.5 {
            self.requestedWidth = w
            self.sessionDriver?.send(.replaceWidth(w))
        }
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        self._lastHeight = ceil(self.layoutManager.usageBoundsForTextContainer.height)
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
        // Preserve host-relayout discipline: asynchronous resource snapshots
        // can shrink
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
            setNeedsLayout()
        }
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
        let activated = self.activateLink(at: pos.offset)
        // Tap on non-link text clears any active selection.
        if !activated, !self.layoutManager.textSelections.isEmpty {
            self._inputDelegate?.selectionWillChange(self)
            self.layoutManager.textSelections = []
            self._inputDelegate?.selectionDidChange(self)
            setNeedsDisplay()
        }
    }

    // MARK: Image loading

    private func triggerImageLoads(in range: NSRange, string: NSAttributedString? = nil) {
        guard self.remoteImages.loader != nil else { return }
        guard let str = string ?? contentStorage.attributedString, let token = self.currentCommitToken else { return }
        let safeRange = range.clamped(to: str.length)
        guard safeRange.length > 0 else { return }
        let registry = self.sessionRegistry
        let owner = self.driver().resourceTaskOwner
        str.enumerateAttribute(.markdownImageSource, in: safeRange) { value, _, _ in
            guard let source = value as? String else { return }
            let request = RenderImageRequest(token: token, source: source)
            guard self.imageRequests[request] == nil else { return }
            guard let url = URL(string: source) else {
                self.imageRequests[request] = .failed
                return
            }
            self.imageRequests[request] = .loading
            owner.images.load(source: url, isCurrent: {
                registry.withAuthorizedSink(for: token) { _ in }
            }, completed: { [weak owner] in
                registry.withAuthorizedSink(for: token) { sink in
                    (sink as? MarkdownLabelView)?.imageRequests.removeValue(forKey: request)
                }
                owner?.deferAction(key: "resources") {
                    registry.withAuthorizedSink(for: token) { sink in
                        (sink as? MarkdownLabelView)?.refreshResolvedResources()
                    }
                }
            }, failed: { category, deferral in
                registry.withAuthorizedSink(for: token) { sink in
                    guard let view = sink as? MarkdownLabelView else { return }
                    view.imageRequests[request] = deferral == nil ? .failed : .deferred
                    if let category {
                        view.onResourceError?(MarkdownResourceFailure(category: category, origin: SanitizedMarkdownOrigin(url: url)))
                    }
                }
            })
        }
    }

    // MARK: Rendered resources

    private func refreshResolvedResources() {
        guard let snapshot = self.currentSnapshot, let token = self.currentCommitToken else { return }
        self.installSnapshot(model: snapshot.displayModel, configuration: self.configurationSnapshot(), token: token)
    }

    /// The new owners are admitted, the snapshot is materialized and the sink is
    /// installed inside one synchronous MainActor turn. The outgoing snapshot's
    /// own leases are never touched here: `replaceSnapshot` clears TextKit and
    /// installs the replacement first, so the old backing stays charged until the
    /// old snapshot itself is released.
    package func installSnapshot(model: RenderDisplayModel, configuration: RenderConfigurationSnapshot, token: RenderCommitToken) {
        guard !self.isDismantled else { return }
        self._materializationCount += 1
        let snapshotID = UUID()
        let images = self.driver().resourceTaskOwner.images
        let resources = self.resolvedResources(for: model, configuration: configuration)
        let transaction = images.ledger.prepareSnapshotReplacement(
            session: self.sessionID, oldSnapshotID: self.currentSnapshot?.id, newSnapshotID: snapshotID,
            owners: resources.owners
        )
        do {
            try transaction.commit { handOver, _ in
                if let failure = self._materializationFailureForTesting { throw failure }
                let snapshot = RenderMaterializer(configuration: configuration)
                    .materialize(model, resources: resources, snapshotID: snapshotID)
                handOver(snapshot.resourceOwners)
                self.replaceSnapshot(snapshot, token: token)
            }
        } catch {
            self.lastRenderError = .preparationFailed
            return
        }
        // Only after the new snapshot is installed: a rolled-back attempt must
        // leave the outgoing snapshot's images resolvable.
        var shown: Set<URL> = []
        for resource in model.resourceValues {
            if case .image(_, let source, _) = resource, let url = URL(string: source) { shown.insert(url) }
        }
        images.retainOnly(shown)
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
#endif
