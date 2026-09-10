import MarkdownPlatformView
import SwiftUI

/// Reads the current selection of a `MarkdownText` / `MarkdownStreamingText`
/// without going through the pasteboard, so a host can inspect what a copy would
/// produce — and how faithful it is — before deciding to perform one.
///
/// Obtained from `MarkdownSelectionReader`, which injects it into the
/// environment for any descendant Markdown view to pick up.
@MainActor
public final class MarkdownSelectionProxy {
    public init() {}

    package weak var view: MarkdownLabelView?

    /// Exactly what the selection covers, as a reader sees it: no
    /// object-replacement characters, images as their alt text, tables as TSV.
    /// `nil` when nothing is selected.
    public var renderedSelection: MarkdownCopyResult? {
        self.view?.renderedSelectionResult()
    }

    /// The Markdown source the selection covers. Check `granularity` before
    /// pasting it somewhere that must not receive more than the user selected:
    /// inline source offsets do not exist, so a partial selection reports
    /// `.blockExpanded`.
    ///
    /// One proxy tracks one view: with several Markdown views under a single
    /// `MarkdownSelectionReader`, the last one to update wins.
    public var markdownSourceSelection: MarkdownCopyResult? {
        self.view?.markdownSourceSelectionResult()
    }

    public var selectionSnapshot: MarkdownSelectionSnapshot? {
        self.view?.selectionSnapshot
    }

    public func annotationRect(id: String) -> CGRect? {
        self.view?.annotationRect(id: id)
    }

    public func copyMarkdownSourceToPasteboard() {
        self.view?.copyMarkdownSource(nil)
    }
}

// MARK: - Environment plumbing

extension EnvironmentValues {
    @Entry var markdownSelectionProxy: MarkdownSelectionProxy? = nil
}

extension MarkdownSelectionProxy {
    /// Called by the representables when the underlying label view is created or
    /// updated. Not part of the public API.
    static func _attach(_ proxy: MarkdownSelectionProxy?, to view: MarkdownLabelView) {
        proxy?.view = view
    }
}
