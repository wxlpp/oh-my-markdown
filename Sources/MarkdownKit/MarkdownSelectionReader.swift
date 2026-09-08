import SwiftUI

/// SwiftUI container that exposes a `MarkdownSelectionProxy` to its content,
/// mirroring `MarkdownEditorReader`.
///
/// ```swift
/// MarkdownSelectionReader { selection in
///     MarkdownText(source)
///         .contextMenu {
///             Button("Copy Markdown Source") { selection.copyMarkdownSourceToPasteboard() }
///         }
/// }
/// ```
///
/// The proxy goes into the environment, so any descendant `MarkdownText` or
/// `MarkdownStreamingText` picks it up without being threaded through manually.
@MainActor
public struct MarkdownSelectionReader<Content: View>: View {
    @State private var proxy = MarkdownSelectionProxy()

    private let content: (MarkdownSelectionProxy) -> Content

    public init(@ViewBuilder content: @escaping (MarkdownSelectionProxy) -> Content) {
        self.content = content
    }

    public var body: some View {
        self.content(self.proxy)
            .environment(\.markdownSelectionProxy, self.proxy)
    }
}
