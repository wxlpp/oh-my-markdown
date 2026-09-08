import Foundation
import MarkdownRenderKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One stop for a screen reader: a heading, a run of prose, a link, an image, a
/// formula, a list item, or a table cell.
///
/// Kept as a plain object rather than a platform element subclass so both
/// platforms share one identity and one frame calculation; the platform wrappers
/// below adapt it. Reused across snapshots while its `id` survives, because a
/// replaced object is a focus jump for whoever was reading it.
@MainActor
package final class MarkdownAccessibilityElement {
    package let id: AccessibilityNodeID
    package private(set) var label: String
    package private(set) var frame: CGRect
    package private(set) var role: AccessibilityRole
    package private(set) var detail: AccessibilityDetail?
    package private(set) var activation: AccessibilityActivation?
    package weak var owner: MarkdownLabelView?

    package init(node: AccessibilityNode, frame: CGRect, owner: MarkdownLabelView?) {
        self.id = node.id
        self.label = node.label ?? ""
        self.frame = frame
        self.role = node.role
        self.detail = node.detail
        self.activation = node.activation
        self.owner = owner
    }

    package func update(node: AccessibilityNode, frame: CGRect) {
        self.label = node.label ?? ""
        self.frame = frame
        self.role = node.role
        self.detail = node.detail
        self.activation = node.activation
    }

    /// Returns whether anything was activated, so a caller can tell "not a link"
    /// from "opened".
    @discardableResult package func activate() -> Bool {
        guard case .link(let url, _)? = self.activation, let owner else { return false }
        owner.activateAccessibilityLink(url)
        return true
    }
}

// MARK: - Building the element list

extension MarkdownLabelView {
    /// Rebuilt whenever a snapshot lands. Elements whose identity survives are
    /// reused in place: replacing the object a reader is focused on moves focus.
    package func rebuildAccessibilityElements() {
        guard let snapshot = self.currentSnapshot else {
            self.accessibilityElementStore = [:]
            self.orderedAccessibilityElements = []
            self.publishAccessibilityElements()
            return
        }
        let frames = self.accessibilityLeafFrames()
        var reused: [AccessibilityNodeID: MarkdownAccessibilityElement] = [:]
        var ordered: [MarkdownAccessibilityElement] = []

        func visit(_ node: AccessibilityNode, block: Int) {
            guard node.children.isEmpty else {
                for child in node.children {
                    visit(child, block: block)
                }
                return
            }
            // A leaf with no laid-out extent cannot be pointed at, so it is not
            // exposed rather than exposed at a wrong or empty rect.
            guard let frame = frames[AccessibilityLeafKey(block: block, ordinal: node.id.ordinal)] else { return }
            if let existing = self.accessibilityElementStore[node.id] {
                existing.update(node: node, frame: frame)
                reused[node.id] = existing
                ordered.append(existing)
            } else {
                let element = MarkdownAccessibilityElement(node: node, frame: frame, owner: self)
                reused[node.id] = element
                ordered.append(element)
            }
        }

        for (block, roots) in snapshot.displayModel.accessibilityRootsByBlock.enumerated() {
            for root in roots {
                visit(root, block: block)
            }
        }
        self.accessibilityElementStore = reused
        self.orderedAccessibilityElements = ordered
        self.publishAccessibilityElements()
    }

    /// On-screen extent of every leaf, from TextKit's own segments. The
    /// materializer tags the characters each leaf renders, so this is layout,
    /// not a reconstruction of it.
    private func accessibilityLeafFrames() -> [AccessibilityLeafKey: CGRect] {
        guard let text = self.renderedAttributedStringForCopy, text.length > 0 else { return [:] }
        var ranges: [AccessibilityLeafKey: NSRange] = [:]
        text.enumerateAttribute(
            .markdownAccessibilityLeaf, in: NSRange(location: 0, length: text.length), options: []
        ) { value, range, _ in
            guard let key = value as? AccessibilityLeafKey else { return }
            ranges[key] = ranges[key].map { NSUnionRange($0, range) } ?? range
        }
        var result: [AccessibilityLeafKey: CGRect] = [:]
        for (key, range) in ranges {
            if let frame = self.accessibilityFrame(forRenderedRange: range) { result[key] = frame }
        }
        // A table too wide for the view keeps only a placeholder character in the
        // main document; its cells live in the overlay's own text stack, so their
        // frames come from there and are converted into this view's space.
        for overlay in self._tableOverlays.values {
            let converted = overlay.content.accessibilityLeafFrames().mapValues {
                overlay.content.convert($0, to: self)
            }
            result.merge(converted) { _, new in new }
        }
        return result
    }
}
