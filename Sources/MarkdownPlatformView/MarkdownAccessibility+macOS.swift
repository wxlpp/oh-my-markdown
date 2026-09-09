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
    func update(with element: MarkdownAccessibilityElement) {
        self.destination = if case .link(let url, _)? = element.activation { url } else { nil }
        self.owner = element.owner
        self.setAccessibilityLabel(element.label)
        self.setAccessibilityValue(element.spokenValue)
        self.setAccessibilityRole(Self.role(for: element.role))
        self.setAccessibilityEnabled(true)
        // The heading role alone is what macOS VoiceOver's heading navigation
        // looks for; `NSAccessibilityElement` exposes no level setter, so the
        // level is spoken through the value instead.
        if case .heading(let level) = element.role, element.spokenValue == nil {
            self.setAccessibilityValue("\(level)")
        }
        if case .cell(let row, let column, _)? = element.detail {
            self.setAccessibilityRowIndexRange(NSRange(location: row, length: 1))
            self.setAccessibilityColumnIndexRange(NSRange(location: column, length: 1))
        }
    }

    @MainActor
    private static func role(for role: AccessibilityRole) -> NSAccessibility.Role {
        switch role {
        case .link: .link
        case .image: .image
        case .cell, .columnHeader, .rowHeader: .cell
        case .heading: NSAccessibility.Role(rawValue: "AXHeading")
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
            let wrapper = self.accessibilityWrapperStore[element.id] ?? MarkdownAccessibilityNSElement()
            self.accessibilityWrapperStore[element.id] = wrapper
            wrapper.update(with: element)
            wrapper.setAccessibilityParent(self)
            // Parent space is bottom-up even though this view is flipped, so a
            // top-down TextKit rect published as-is lands mirrored about the
            // view's midpoint — the first line reported at the bottom.
            wrapper.setAccessibilityFrameInParentSpace(CGRect(
                x: element.frame.minX, y: self.bounds.height - element.frame.maxY,
                width: element.frame.width, height: element.frame.height
            ))
            return wrapper
        }
        self.accessibilityWrapperStore = self.accessibilityWrapperStore.filter { id, _ in
            self.accessibilityElementStore[id] != nil
        }
        self.setAccessibilityChildren(children)
        self.setAccessibilityRole(.group)
    }
}
#endif
