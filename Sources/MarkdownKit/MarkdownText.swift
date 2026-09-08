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
        // The platform view is an accessibility *container*: it publishes one
        // element per semantic leaf. Without this, SwiftUI collapses a
        // representable's children into a single node and VoiceOver reads the
        // whole document in one breath, which is what a reader actually got.
        _MarkdownTextRepresentable(
            source: self.source,
            style: self.style,
            mathRenderer: self.mathRenderer,
            svgBlockRenderer: self.svgBlockRenderer,
            remoteImages: self.remoteImages,
            linkConfiguration: self.linkConfiguration,
            selectionProxy: self.selectionProxy,
            resourceErrorHandler: self.resourceErrorHandler
        )
        .accessibilityElement(children: .contain)
    }

    @Environment(\.markdownStyle) private var style
    @Environment(\.markdownMathRenderer) private var mathRenderer
    @Environment(\.markdownSVGBlockRenderer) private var svgBlockRenderer
    @Environment(\.markdownRemoteImageConfiguration) private var remoteImages
    @Environment(\.markdownResourceErrorHandler) private var resourceErrorHandler
    @Environment(\.markdownLinkConfiguration) private var linkConfiguration
    @Environment(\.markdownSelectionProxy) private var selectionProxy

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
        var lastImageConfigurationID: MarkdownConfigurationID?
        var hasInstalledLinkConfiguration = false
    }

    let source: String
    let style: RenderStyle
    let mathRenderer: MathRendererConfiguration?
    let svgBlockRenderer: SVGRendererConfiguration?
    let remoteImages: MarkdownRemoteImageConfiguration
    let linkConfiguration: MarkdownLinkConfiguration?
    let selectionProxy: MarkdownSelectionProxy?
    let resourceErrorHandler: MarkdownResourceErrorHandler?

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
        uiView.onResourceError = self.resourceErrorHandler
        // Always forwarded, like the view's own didSet: identity is derived from
        // the policy's type, so a host that tightens a stateful policy produces an
        // equal identity. Suppressing here would leave the old policy deciding.
        // Clearing it reverts, once, on the edge: a host that revokes the
        // configuration must not keep the permissive one it installed earlier.
        MarkdownSelectionProxy._attach(self.selectionProxy, to: uiView)
        if let link = self.linkConfiguration {
            uiView.linkConfiguration = link
            context.coordinator.hasInstalledLinkConfiguration = true
        } else if context.coordinator.hasInstalledLinkConfiguration {
            uiView.linkConfiguration = .platformDefault
            context.coordinator.hasInstalledLinkConfiguration = false
        }
        // Compared by `configurationID`, not by instance: `.defaultHTTPS` and
        // `.https(…)` build a fresh value on every access, so an instance-keyed
        // check would reinstall on every body evaluation — and reinstalling
        // restarts the loads, which turns one failing image into an unbounded
        // retry loop for any host that records failures into `@State`.
        // Equal semantic ids promise interchangeable output, so not reinstalling
        // is the contract rather than an optimisation; a `.uniqueInstance()` id
        // differs every time and still reinstalls, which is what it means.
        if context.coordinator.lastImageConfigurationID != self.remoteImages.configurationID {
            uiView.remoteImages = self.remoteImages
            context.coordinator.lastImageConfigurationID = self.remoteImages.configurationID
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
        var lastImageConfigurationID: MarkdownConfigurationID?
        var hasInstalledLinkConfiguration = false
    }

    let source: String
    let style: RenderStyle
    let mathRenderer: MathRendererConfiguration?
    let svgBlockRenderer: SVGRendererConfiguration?
    let remoteImages: MarkdownRemoteImageConfiguration
    let linkConfiguration: MarkdownLinkConfiguration?
    let selectionProxy: MarkdownSelectionProxy?
    let resourceErrorHandler: MarkdownResourceErrorHandler?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MarkdownLabelView {
        MarkdownLabelView()
    }

    func updateNSView(_ nsView: MarkdownLabelView, context: Context) {
        nsView.onResourceError = self.resourceErrorHandler
        // Always forwarded, like the view's own didSet: identity is derived from
        // the policy's type, so a host that tightens a stateful policy produces an
        // equal identity. Suppressing here would leave the old policy deciding.
        // Clearing it reverts, once, on the edge: a host that revokes the
        // configuration must not keep the permissive one it installed earlier.
        MarkdownSelectionProxy._attach(self.selectionProxy, to: nsView)
        if let link = self.linkConfiguration {
            nsView.linkConfiguration = link
            context.coordinator.hasInstalledLinkConfiguration = true
        } else if context.coordinator.hasInstalledLinkConfiguration {
            nsView.linkConfiguration = .platformDefault
            context.coordinator.hasInstalledLinkConfiguration = false
        }
        // Compared by `configurationID`, not by instance: `.defaultHTTPS` and
        // `.https(…)` build a fresh value on every access, so an instance-keyed
        // check would reinstall on every body evaluation — and reinstalling
        // restarts the loads, which turns one failing image into an unbounded
        // retry loop for any host that records failures into `@State`.
        // Equal semantic ids promise interchangeable output, so not reinstalling
        // is the contract rather than an optimisation; a `.uniqueInstance()` id
        // differs every time and still reinstalls, which is what it means.
        if context.coordinator.lastImageConfigurationID != self.remoteImages.configurationID {
            nsView.remoteImages = self.remoteImages
            context.coordinator.lastImageConfigurationID = self.remoteImages.configurationID
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
