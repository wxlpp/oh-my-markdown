import MarkdownCore
import MarkdownPlatformView
import MarkdownRenderKit
import SwiftUI

// MARK: - MarkdownText

/// A SwiftUI view that renders a Markdown string with text selection support.
///
/// ```swift
/// // Static content
/// MarkdownText("**Hello** _world_")
///
/// // Chat streaming — update source from a Task
/// @State var source = ""
/// MarkdownText(source)
///     .task {
///         for await chunk in stream { source += chunk }
///     }
/// ```
///
/// Apply `.markdownStyle(_:)` to customise fonts and colors.
public struct MarkdownText: View {
    public init(_ source: String) {
        self.source = source
    }

    public var body: some View {
        _MarkdownTextRepresentable(
            source: self.source,
            style: self.style,
            mathRenderer: self.mathRenderer,
            svgBlockRenderer: self.svgBlockRenderer
        )
    }

    @Environment(\.markdownStyle) private var style
    @Environment(\.markdownMathRenderer) private var mathRenderer
    @Environment(\.markdownSVGBlockRenderer) private var svgBlockRenderer

    private let source: String
}

// MARK: - UIViewRepresentable

#if canImport(UIKit)

private struct _MarkdownTextRepresentable: UIViewRepresentable {
    static func dismantleUIView(_ uiView: MarkdownLabelView, coordinator: Coordinator) {
        uiView.dismantleRenderSession()
    }

    final class Coordinator {
        var lastSource = ""
        var lastStyle: RenderStyle?
        var lastMathRenderer: MathRendererConfiguration?
        var lastSVGBlockRenderer: SVGRendererConfiguration?
    }

    let source: String
    let style: RenderStyle
    let mathRenderer: MathRendererConfiguration?
    let svgBlockRenderer: SVGRendererConfiguration?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MarkdownLabelView {
        let view = MarkdownLabelView()
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
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
        let old = context.coordinator.lastSource
        guard old != self.source else {
            return
        }
        context.coordinator.lastSource = self.source
        if !old.isEmpty && self.source.hasPrefix(old) {
            uiView.appendMarkdown(String(self.source.dropFirst(old.count)))
        } else {
            uiView.setMarkdown(self.source)
        }
    }

    /// Use sizeThatFits so the view expands vertically to fit its content.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MarkdownLabelView,
        context: Context
    )
        -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

#elseif canImport(AppKit)

private struct _MarkdownTextRepresentable: NSViewRepresentable {
    static func dismantleNSView(_ nsView: MarkdownLabelView, coordinator: Coordinator) {
        nsView.dismantleRenderSession()
    }

    final class Coordinator {
        var lastSource = ""
        var lastStyle: RenderStyle?
        var lastMathRenderer: MathRendererConfiguration?
        var lastSVGBlockRenderer: SVGRendererConfiguration?
    }

    let source: String
    let style: RenderStyle
    let mathRenderer: MathRendererConfiguration?
    let svgBlockRenderer: SVGRendererConfiguration?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MarkdownLabelView {
        MarkdownLabelView()
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
        let old = context.coordinator.lastSource
        guard old != self.source else {
            return
        }
        context.coordinator.lastSource = self.source
        if !old.isEmpty && self.source.hasPrefix(old) {
            nsView.appendMarkdown(String(self.source.dropFirst(old.count)))
        } else {
            nsView.setMarkdown(self.source)
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
}

#endif

extension EnvironmentValues {
    /// The ``RenderStyle`` applied to ``MarkdownText`` views in this environment.
    @Entry public var markdownStyle: RenderStyle = .default
}

extension View {
    /// Applies a custom ``RenderStyle`` to all ``MarkdownText`` views in this subtree.
    public func markdownStyle(_ style: RenderStyle) -> some View {
        environment(\.markdownStyle, style)
    }
}
