@_exported import MarkdownCore
@_exported import MarkdownPlatformView
@_exported import MarkdownRenderKit
import SwiftUI

// MARK: - MarkdownEditor

public struct MarkdownEditor: View {
    public init(text: Binding<String>, options: MarkdownEditorOptions = .default) {
        self._text = text
        self.optionsOverride = options == .default ? nil : options
    }

    public var body: some View {
        _MarkdownEditorRepresentable(
            text: self.$text,
            style: self.style,
            options: self.optionsOverride ?? self.environmentOptions,
            selectionHandler: self.selectionHandler,
            insertTextHandler: self.insertTextHandler,
            proxy: self.proxy
        )
    }

    @Binding private var text: String
    @Environment(\.markdownStyle) private var style
    @Environment(\.markdownEditorOptions) private var environmentOptions
    @Environment(\.markdownEditorSelectionHandler) private var selectionHandler
    @Environment(\.markdownEditorInsertTextHandler) private var insertTextHandler
    @Environment(\.markdownEditorProxy) private var proxy

    private var optionsOverride: MarkdownEditorOptions?
}

extension EnvironmentValues {
    @Entry fileprivate var markdownEditorOptions: MarkdownEditorOptions = .default

    @Entry fileprivate var markdownEditorSelectionHandler: ((MarkdownEditorSelection) -> Void)? = nil
}

extension View {
    public func markdownEditorOptions(_ options: MarkdownEditorOptions) -> some View {
        environment(\.markdownEditorOptions, options)
    }

    public func onSelectionChange(_ handler: @escaping (MarkdownEditorSelection) -> Void) -> some View {
        environment(\.markdownEditorSelectionHandler, handler)
    }
}

#if canImport(UIKit)
private struct _MarkdownEditorRepresentable: UIViewRepresentable {
    final class Coordinator {
        var lastText = ""
        var lastStyle: RenderStyle?
        var lastOptions: MarkdownEditorOptions = .default
    }

    @Binding var text: String

    let style: RenderStyle
    let options: MarkdownEditorOptions
    let selectionHandler: ((MarkdownEditorSelection) -> Void)?
    let insertTextHandler: ((NSRange, String) -> MarkdownEditorInputAction)?
    let proxy: MarkdownEditorProxy?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MarkdownEditorTextView {
        let view = MarkdownEditorTextView()
        view.onTextChange = { newText in
            context.coordinator.lastText = newText
            self.text = newText
        }
        view.onSelectionChange = { selection in
            self.selectionHandler?(selection)
        }
        view.onInsertText = self.insertTextHandler
        MarkdownEditorProxy._attach(self.proxy, to: view)
        return view
    }

    func updateUIView(_ uiView: MarkdownEditorTextView, context: Context) {
        if context.coordinator.lastStyle?.isSemanticallyEqual(to: self.style) != true {
            uiView.renderStyle = self.style
            context.coordinator.lastStyle = self.style
        }
        if context.coordinator.lastOptions != self.options {
            uiView.editorOptions = self.options
            context.coordinator.lastOptions = self.options
        }
        if context.coordinator.lastText != self.text {
            context.coordinator.lastText = self.text
            uiView.setMarkdown(self.text)
        }
        uiView.onSelectionChange = { selection in
            self.selectionHandler?(selection)
        }
        uiView.onTextChange = { newText in
            context.coordinator.lastText = newText
            self.text = newText
        }
        uiView.onInsertText = self.insertTextHandler
        MarkdownEditorProxy._attach(self.proxy, to: uiView)
    }
}

#elseif canImport(AppKit)
private struct _MarkdownEditorRepresentable: NSViewRepresentable {
    final class Coordinator {
        var lastText = ""
        var lastStyle: RenderStyle?
        var lastOptions: MarkdownEditorOptions = .default
    }

    @Binding var text: String

    let style: RenderStyle
    let options: MarkdownEditorOptions
    let selectionHandler: ((MarkdownEditorSelection) -> Void)?
    let insertTextHandler: ((NSRange, String) -> MarkdownEditorInputAction)?
    let proxy: MarkdownEditorProxy?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MarkdownEditorTextView {
        let view = MarkdownEditorTextView()
        view.onTextChange = { newText in
            context.coordinator.lastText = newText
            self.text = newText
        }
        view.onSelectionChange = { selection in
            self.selectionHandler?(selection)
        }
        view.onInsertText = self.insertTextHandler
        MarkdownEditorProxy._attach(self.proxy, to: view)
        return view
    }

    func updateNSView(_ nsView: MarkdownEditorTextView, context: Context) {
        if context.coordinator.lastStyle?.isSemanticallyEqual(to: self.style) != true {
            nsView.renderStyle = self.style
            context.coordinator.lastStyle = self.style
        }
        if context.coordinator.lastOptions != self.options {
            nsView.editorOptions = self.options
            context.coordinator.lastOptions = self.options
        }
        if context.coordinator.lastText != self.text {
            context.coordinator.lastText = self.text
            nsView.setMarkdown(self.text)
        }
        nsView.onSelectionChange = { selection in
            self.selectionHandler?(selection)
        }
        nsView.onTextChange = { newText in
            context.coordinator.lastText = newText
            self.text = newText
        }
        nsView.onInsertText = self.insertTextHandler
        MarkdownEditorProxy._attach(self.proxy, to: nsView)
    }
}
#endif
