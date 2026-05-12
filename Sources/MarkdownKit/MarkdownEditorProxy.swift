import Foundation
import MarkdownPlatformView
import SwiftUI

// MARK: - MarkdownEditorProxy

/// Application-facing handle for an embedded `MarkdownEditor`. Obtain it via
/// `MarkdownEditorReader { proxy in ... }` and use it to drive selection,
/// scroll position, and caret introspection from outside the editor.
///
/// The proxy holds a weak reference to the underlying platform text view; it
/// is safe to keep beyond the editor's lifetime (calls become no-ops once the
/// view goes away).
@MainActor
public final class MarkdownEditorProxy {
    public init() {}

    private weak var view: MarkdownEditorTextView?

    /// Scroll until `range` is visible. `animated` is honoured where the
    /// underlying platform supports it (UIKit only).
    public func scrollToRange(_ range: NSRange, animated: Bool = true) {
        self.view?.scrollToRange(range, animated: animated)
    }

    /// Move the selection / caret to `range` without scrolling.
    public func setSelection(_ range: NSRange) {
        self.view?.setSelection(range)
    }

    /// Caret rect for the current selection start, in the editor's
    /// coordinate space. `nil` if the editor is not yet laid out.
    public var caretRect: CGRect? {
        self.view?.currentCaretRect
    }

    /// Approximate character range currently visible in the viewport.
    public var visibleRange: NSRange? {
        self.view?.visibleNSRange
    }

    private func attach(_ view: MarkdownEditorTextView) {
        self.view = view
    }
}

// MARK: - MarkdownEditorReader

/// SwiftUI container that exposes a `MarkdownEditorProxy` to its content.
///
/// ```swift
/// MarkdownEditorReader { proxy in
///     MarkdownEditor(text: $body)
///         .onAppear { editorProxy = proxy }
/// }
/// ```
///
/// The proxy is injected into the environment so any descendant `MarkdownEditor`
/// picks it up automatically — there is no need to thread it through manually.
@MainActor
public struct MarkdownEditorReader<Content: View>: View {
    @State private var proxy = MarkdownEditorProxy()

    private let content: (MarkdownEditorProxy) -> Content

    public init(@ViewBuilder content: @escaping (MarkdownEditorProxy) -> Content) {
        self.content = content
    }

    public var body: some View {
        self.content(self.proxy)
            .environment(\.markdownEditorProxy, self.proxy)
    }
}

// MARK: - Environment plumbing

extension EnvironmentValues {
    @Entry var markdownEditorProxy: MarkdownEditorProxy? = nil

    @Entry var markdownEditorInsertTextHandler: ((NSRange, String) -> MarkdownEditorInputAction)? = nil
}

extension View {
    /// Install a text-change interceptor on any descendant `MarkdownEditor`.
    ///
    /// The closure runs before the editor applies any user-driven edit that
    /// flows through `shouldChangeTextIn` — typing, paste, deletion (empty
    /// `replacement`), drag-drop. Filter inside the closure if you only care
    /// about a subset (e.g. slash-command insertions).
    ///
    /// Return `.allow` to proceed, `.reject` to drop the change, or
    /// `.replace(_:)` to substitute different text. The hook is skipped while
    /// an IME composition is in flight.
    public func onInsertText(
        _ handler: @escaping (NSRange, String) -> MarkdownEditorInputAction
    ) -> some View {
        environment(\.markdownEditorInsertTextHandler, handler)
    }
}

// MARK: - Internal attach helper

extension MarkdownEditorProxy {
    /// Called by the representable when the underlying text view is created or
    /// updated. Not part of the public API.
    static func _attach(_ proxy: MarkdownEditorProxy?, to view: MarkdownEditorTextView) {
        proxy?.attach(view)
    }
}
