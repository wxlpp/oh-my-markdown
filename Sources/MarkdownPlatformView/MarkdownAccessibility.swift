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

    /// What a reader hears after the label. Carrying the detail no further than
    /// the model would leave "correct table relationships" true only on paper.
    package var spokenValue: String? {
        switch self.detail {
        case .cell(let row, let column, let header):
            let position = String(format: AccessibilityTreeBuilder.cellPositionFormat, row + 1, column + 1)
            return header.map { $0.isEmpty ? position : "\($0), \(position)" } ?? position
        case .listItem(let position, let count, let checkbox):
            let state = checkbox.map { $0 ? AccessibilityTreeBuilder.checkedLabel : AccessibilityTreeBuilder.uncheckedLabel }
            let position = String(format: AccessibilityTreeBuilder.listPositionFormat, position, count)
            return state.map { "\($0), \(position)" } ?? position
        case .code(let language):
            return language
        case nil:
            return nil
        }
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
    /// Re-entrant by construction: the rebuild lays out the table overlay, which
    /// can move that overlay's scroll position, which calls back in here. Without
    /// a bound the Example app hung for 285 s on rotation.
    ///
    /// The re-entrant call is the pass that would correct the frames the outer
    /// pass computed *before* the overlay moved, so it is not discarded — it runs
    /// once more. A re-entry arriving during *that* pass is discarded, which
    /// bounds staleness to the next snapshot or layout. The loop is written here
    /// rather than by re-entering `defer`, which would re-arm itself and leave
    /// the pass count decided by whether layout happens to converge.
    package func rebuildAccessibilityElements() {
        guard !self.isRebuildingAccessibilityElements else {
            self.needsAccessibilityRebuild = true
            return
        }
        self.isRebuildingAccessibilityElements = true
        defer { self.isRebuildingAccessibilityElements = false }
        self.needsAccessibilityRebuild = false
        self.performAccessibilityRebuild()
        guard self.needsAccessibilityRebuild else { return }
        self.needsAccessibilityRebuild = false
        self.performAccessibilityRebuild()
    }

    private func performAccessibilityRebuild() {
        guard let snapshot = self.currentSnapshot else {
            self.accessibilityElementStore = [:]
            self.orderedAccessibilityElements = []
            self.publishAccessibilityElements()
            return
        }
        let frames = self.accessibilityLeafFrames()
        var reused: [AccessibilityNodeID: MarkdownAccessibilityElement] = [:]
        var ordered: [MarkdownAccessibilityElement] = []

        /// A container is not published as its own stop — that would make a reader
        /// hear the item and then each of its parts. Its role and detail are
        /// merged onto the first leaf inside it instead, which is the leaf
        /// carrying the item's own text, so a nested list item still says
        /// "1 of 2" rather than arriving as anonymous prose.
        /// Returns whether `inherited`'s detail reached a published element.
        @discardableResult
        func visit(_ original: AccessibilityNode, block: Int, inherited: AccessibilityNode? = nil) -> Bool {
            guard original.children.isEmpty else {
                // The nearest enclosing item wins: taking the ancestor's made an
                // inner list's only item announce the *outer* list's position.
                var pending = (original.role == .listItem ? original : nil) ?? inherited
                for child in original.children {
                    // Consumed only when the merge actually spoke: a first child
                    // that already carries its own detail — a code block, a table
                    // cell — or one dropped for want of a frame would otherwise
                    // swallow the item's position with nothing to show for it.
                    if visit(child, block: block, inherited: pending) { pending = nil }
                }
                return false
            }
            let node = inherited.map { container in
                AccessibilityNode(
                    id: original.id, role: original.role == .text ? container.role : original.role,
                    label: original.label, sourceRange: original.sourceRange,
                    activation: original.activation, detail: original.detail ?? container.detail
                )
            } ?? original
            // A leaf with no laid-out extent cannot be pointed at, so it is not
            // exposed rather than exposed at a wrong or empty rect.
            guard let frame = frames[AccessibilityLeafKey(block: block, ordinal: node.id.ordinal)] else {
                return false
            }
            if let existing = self.accessibilityElementStore[node.id] {
                existing.update(node: node, frame: frame)
                reused[node.id] = existing
                ordered.append(existing)
            } else {
                let element = MarkdownAccessibilityElement(node: node, frame: frame, owner: self)
                reused[node.id] = element
                ordered.append(element)
            }
            // Spoke only if the inheritance is what supplied the detail.
            return inherited != nil && original.detail == nil
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
        var result = self.accessibilityFrames(forRenderedRanges: ranges.map { ($0.key, $0.value) })
        // A table too wide for the view keeps only a placeholder character in the
        // main document; its cells live in the overlay's own text stack, so their
        // frames come from there and are converted into this view's space.
        for overlay in self._tableOverlays.values {
            let visible = overlay.scroll.convert(overlay.scroll.bounds, to: self)
            let converted = overlay.content.accessibilityLeafFrames()
                .mapValues { overlay.content.convert($0, to: self).intersection(visible) }
                .filter { !$0.value.isNull && !$0.value.isEmpty }
            result.merge(converted) { _, new in new }
        }
        return result
    }
}
