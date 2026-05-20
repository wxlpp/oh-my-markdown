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
            svgBlockRenderer: self.svgBlockRenderer
        )
    }

    @Environment(\.markdownStyle) private var style
    @Environment(\.markdownMathRenderer) private var mathRenderer
    @Environment(\.markdownSVGBlockRenderer) private var svgBlockRenderer

    private let source: MarkdownStreamingSource
}

#if canImport(UIKit)
private struct _MarkdownStreamingTextRepresentable: UIViewRepresentable {
    final class Coordinator {
        var listenerID: UUID?
        var currentSource: MarkdownStreamingSource?
        var lastStyle: RenderStyle?
        var lastMathRenderer: (any MathRendering)?
        var lastSVGBlockRenderer: (any SVGBlockRendering)?
    }

    let source: MarkdownStreamingSource
    let style: RenderStyle
    let mathRenderer: (any MathRendering)?
    let svgBlockRenderer: (any SVGBlockRendering)?

    static func dismantleUIView(_ uiView: MarkdownLabelView, coordinator: Coordinator) {
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
        var lastMathRenderer: (any MathRendering)?
        var lastSVGBlockRenderer: (any SVGBlockRendering)?
    }

    let source: MarkdownStreamingSource
    let style: RenderStyle
    let mathRenderer: (any MathRendering)?
    let svgBlockRenderer: (any SVGBlockRendering)?

    static func dismantleNSView(_ nsView: MarkdownLabelView, coordinator: Coordinator) {
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
