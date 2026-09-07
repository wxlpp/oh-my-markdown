import MarkdownPlatformView
import MarkdownRenderKit
import SwiftUI

// MARK: - MarkdownStreamingSource

@MainActor
public final class MarkdownStreamingSource {
    fileprivate enum Event {
        case set(String)
        case append(String)
    }

    public init(_ source: String = "") {
        self.source = source
    }

    public var isEmpty: Bool {
        self.source.isEmpty
    }

    public func setMarkdown(_ source: String) {
        self.source = source
        self.send(.set(source))
    }

    public func append(_ chunk: String) {
        guard !chunk.isEmpty else {
            return
        }
        self.source += chunk
        self.send(.append(chunk))
    }

    public func clear() {
        self.setMarkdown("")
    }

    @discardableResult
    fileprivate func addListener(_ listener: @escaping (Event) -> Void) -> UUID {
        let id = UUID()
        self.listeners[id] = listener
        listener(.set(self.source))
        return id
    }

    fileprivate func removeListener(_ id: UUID?) {
        guard let id else {
            return
        }
        self.listeners.removeValue(forKey: id)
    }

    private var source = ""
    private var listeners: [UUID: (Event) -> Void] = [:]

    private func send(_ event: Event) {
        for listener in self.listeners.values {
            listener(event)
        }
    }
}

// MARK: - MarkdownStreamingText

public struct MarkdownStreamingText: View {
    public init(_ source: MarkdownStreamingSource) {
        self.source = source
    }

    public var body: some View {
        _MarkdownStreamingTextRepresentable(
            source: self.source,
            style: self.style,
            mathRenderer: self.mathRenderer,
            svgBlockRenderer: self.svgBlockRenderer,
            remoteImages: self.remoteImages,
            linkConfiguration: self.linkConfiguration,
            resourceErrorHandler: self.resourceErrorHandler
        )
    }

    @Environment(\.markdownStyle) private var style
    @Environment(\.markdownMathRenderer) private var mathRenderer
    @Environment(\.markdownSVGBlockRenderer) private var svgBlockRenderer
    @Environment(\.markdownRemoteImageConfiguration) private var remoteImages
    @Environment(\.markdownLinkConfiguration) private var linkConfiguration
    @Environment(\.markdownResourceErrorHandler) private var resourceErrorHandler

    private let source: MarkdownStreamingSource
}

#if canImport(UIKit)
private struct _MarkdownStreamingTextRepresentable: UIViewRepresentable {
    final class Coordinator {
        var listenerID: UUID?
        var currentSource: MarkdownStreamingSource?
        var lastStyle: RenderStyle?
        var lastMathRenderer: MathRendererConfiguration?
        var lastSVGBlockRenderer: SVGRendererConfiguration?
        var lastImageReplacementID: UUID?
        var lastLinkIdentity: LinkIdentity?
    }

    let source: MarkdownStreamingSource
    let style: RenderStyle
    let mathRenderer: MathRendererConfiguration?
    let svgBlockRenderer: SVGRendererConfiguration?
    let remoteImages: MarkdownRemoteImageConfiguration
    let linkConfiguration: MarkdownLinkConfiguration?
    let resourceErrorHandler: MarkdownResourceErrorHandler?

    static func dismantleUIView(_ uiView: MarkdownLabelView, coordinator: Coordinator) {
        uiView.dismantleRenderSession()
        coordinator.currentSource?.removeListener(coordinator.listenerID)
        coordinator.listenerID = nil
        coordinator.currentSource = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MarkdownLabelView {
        let view = MarkdownLabelView()
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        self.attachListener(to: view, context: context)
        return view
    }

    func updateUIView(_ uiView: MarkdownLabelView, context: Context) {
        uiView.onResourceError = self.resourceErrorHandler
        let linkIdentity = self.linkConfiguration.map { LinkIdentity(policyID: $0.policyID, handlerID: $0.handlerID) }
        if let link = self.linkConfiguration, context.coordinator.lastLinkIdentity != linkIdentity {
            uiView.linkConfiguration = link
            context.coordinator.lastLinkIdentity = linkIdentity
        }
        if context.coordinator.lastImageReplacementID != self.remoteImages.replacementID {
            uiView.remoteImages = self.remoteImages
            context.coordinator.lastImageReplacementID = self.remoteImages.replacementID
        }
        if context.coordinator.lastStyle?.isSemanticallyEqual(to: self.style) != true {
            uiView.renderStyle = self.style
            context.coordinator.lastStyle = self.style
        }
        if !isSameMathRenderer(context.coordinator.lastMathRenderer, self.mathRenderer) {
            uiView.mathRenderer = self.mathRenderer
            context.coordinator.lastMathRenderer = self.mathRenderer
        }
        if !isSameSVGBlockRenderer(context.coordinator.lastSVGBlockRenderer, self.svgBlockRenderer) {
            uiView.svgBlockRenderer = self.svgBlockRenderer
            context.coordinator.lastSVGBlockRenderer = self.svgBlockRenderer
        }
        if context.coordinator.currentSource !== self.source {
            self.attachListener(to: uiView, context: context)
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MarkdownLabelView,
        context: Context
    )
        -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private func attachListener(to view: MarkdownLabelView, context: Context) {
        context.coordinator.currentSource?.removeListener(context.coordinator.listenerID)
        context.coordinator.currentSource = self.source
        context.coordinator.listenerID = self.source.addListener { [weak view] event in
            guard let view else {
                return
            }
            switch event {
            case .set(let markdown):
                view.setMarkdown(markdown)
            case .append(let chunk):
                view.appendMarkdown(chunk)
            }
        }
    }
}

#elseif canImport(AppKit)
private struct _MarkdownStreamingTextRepresentable: NSViewRepresentable {
    final class Coordinator {
        var listenerID: UUID?
        var currentSource: MarkdownStreamingSource?
        var lastStyle: RenderStyle?
        var lastMathRenderer: MathRendererConfiguration?
        var lastSVGBlockRenderer: SVGRendererConfiguration?
        var lastImageReplacementID: UUID?
        var lastLinkIdentity: LinkIdentity?
    }

    let source: MarkdownStreamingSource
    let style: RenderStyle
    let mathRenderer: MathRendererConfiguration?
    let svgBlockRenderer: SVGRendererConfiguration?
    let remoteImages: MarkdownRemoteImageConfiguration
    let linkConfiguration: MarkdownLinkConfiguration?
    let resourceErrorHandler: MarkdownResourceErrorHandler?

    static func dismantleNSView(_ nsView: MarkdownLabelView, coordinator: Coordinator) {
        nsView.dismantleRenderSession()
        coordinator.currentSource?.removeListener(coordinator.listenerID)
        coordinator.listenerID = nil
        coordinator.currentSource = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MarkdownLabelView {
        let view = MarkdownLabelView()
        self.attachListener(to: view, context: context)
        return view
    }

    func updateNSView(_ nsView: MarkdownLabelView, context: Context) {
        nsView.onResourceError = self.resourceErrorHandler
        let linkIdentity = self.linkConfiguration.map { LinkIdentity(policyID: $0.policyID, handlerID: $0.handlerID) }
        if let link = self.linkConfiguration, context.coordinator.lastLinkIdentity != linkIdentity {
            nsView.linkConfiguration = link
            context.coordinator.lastLinkIdentity = linkIdentity
        }
        if context.coordinator.lastImageReplacementID != self.remoteImages.replacementID {
            nsView.remoteImages = self.remoteImages
            context.coordinator.lastImageReplacementID = self.remoteImages.replacementID
        }
        if context.coordinator.lastStyle?.isSemanticallyEqual(to: self.style) != true {
            nsView.renderStyle = self.style
            context.coordinator.lastStyle = self.style
        }
        if !isSameMathRenderer(context.coordinator.lastMathRenderer, self.mathRenderer) {
            nsView.mathRenderer = self.mathRenderer
            context.coordinator.lastMathRenderer = self.mathRenderer
        }
        if !isSameSVGBlockRenderer(context.coordinator.lastSVGBlockRenderer, self.svgBlockRenderer) {
            nsView.svgBlockRenderer = self.svgBlockRenderer
            context.coordinator.lastSVGBlockRenderer = self.svgBlockRenderer
        }
        if context.coordinator.currentSource !== self.source {
            self.attachListener(to: nsView, context: context)
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: MarkdownLabelView,
        context: Context
    )
        -> CGSize? {
        let width = proposal.width ?? nsView.fittingSize.width
        let targetWidth = max(width, 1)
        let previousWidth = nsView.frame.width
        if abs(previousWidth - targetWidth) > 0.5 {
            nsView.frame.size.width = targetWidth
        }
        let fitted = nsView.intrinsicContentSize
        return CGSize(width: targetWidth, height: fitted.height)
    }

    private func attachListener(to view: MarkdownLabelView, context: Context) {
        context.coordinator.currentSource?.removeListener(context.coordinator.listenerID)
        context.coordinator.currentSource = self.source
        context.coordinator.listenerID = self.source.addListener { [weak view] event in
            guard let view else {
                return
            }
            switch event {
            case .set(let markdown):
                view.setMarkdown(markdown)
            case .append(let chunk):
                view.appendMarkdown(chunk)
            }
        }
    }
}
#endif
