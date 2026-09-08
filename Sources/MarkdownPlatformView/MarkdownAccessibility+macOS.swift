#if canImport(AppKit) && !canImport(UIKit)
import AppKit
import MarkdownRenderKit

/// AppKit wrapper around one semantic leaf.
///
/// Label, role and frame are set eagerly rather than read back through
/// overrides: AppKit's accessibility accessors carry no isolation annotation, so
/// reading main-actor state from them would need an unchecked escape for every
/// property. Only the press action needs one, and it is confined to a single
/// line — AppKit performs it on the main thread.
final class MarkdownAccessibilityNSElement: NSAccessibilityElement {
    /// The URL this leaf opens, if any. A Sendable value rather than the leaf
    /// itself, so the press handler needs no reference to main-actor state.
    private nonisolated(unsafe) var destination: URL?
    private nonisolated(unsafe) weak var owner: MarkdownLabelView?

    @MainActor
    init(element: MarkdownAccessibilityElement) {
        super.init()
        if case .link(let url, _)? = element.activation { self.destination = url }
        self.owner = element.owner
        self.setAccessibilityLabel(element.label)
        self.setAccessibilityRole(Self.role(for: element.role))
        self.setAccessibilityEnabled(true)
    }

    @MainActor
    private static func role(for role: AccessibilityRole) -> NSAccessibility.Role {
        switch role {
        case .link: .link
        case .image: .image
        case .cell, .columnHeader, .rowHeader: .cell
        default: .staticText
        }
    }

    override nonisolated func accessibilityPerformPress() -> Bool {
        guard let destination, let owner else { return false }
        MainActor.assumeIsolated { owner.activateAccessibilityLink(destination) }
        return true
    }
}

extension MarkdownLabelView {
    /// The label is a container of leaves. Its own role is a group so a reader
    /// moves through the parts rather than hearing the document as one string.
    func publishAccessibilityElements() {
        let children: [Any] = self.orderedAccessibilityElements.map { element in
            let wrapper = MarkdownAccessibilityNSElement(element: element)
            wrapper.setAccessibilityParent(self)
            wrapper.setAccessibilityFrameInParentSpace(element.frame)
            return wrapper
        }
        self.setAccessibilityChildren(children)
        self.setAccessibilityRole(.group)
    }
}
#endif
