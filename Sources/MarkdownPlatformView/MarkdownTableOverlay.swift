import Foundation
import MarkdownCore
import MarkdownRenderKit

#if canImport(UIKit)
import UIKit

extension MarkdownLabelView {
    private func _tableNaturalWidth(at blockIndex: Int) -> CGFloat {
        self.decorations.tableNaturalWidth(at: blockIndex)
    }

    /// Creates, repositions, or removes UIScrollView overlays for tables that overflow the view width.
    func _syncTableOverlays(from startIndex: Int) {
        let startIndex = max(0, min(startIndex, blocks.count))
        // Remove overlays whose index no longer corresponds to a table block.
        let stale = self._tableOverlays.keys.filter { i -> Bool in
            guard i >= startIndex else {
                return false
            }
            guard i < self.blocks.count, case .table = self.blocks[i] else {
                return true
            }
            return false
        }
        for i in stale {
            self._tableOverlays[i]?.scroll.removeFromSuperview()
            self._tableOverlays.removeValue(forKey: i)
        }

        let viewWidth = bounds.width
        guard startIndex < self.blocks.count else {
            return
        }

        // The reserved height in the main stack is already correct by
        // construction: `AttributedStringRenderer.overflowTablePlaceholder` and
        // the overlay's `TableContentView` both size off the *same*
        // `TableMeasurement.height` call, so there is no write-back and no
        // convergence pass — this loop only positions/sizes the overlay against
        // the (already-correct) reserved geometry from `blockFrameUnion`.
        for i in startIndex ..< self.blocks.count {
            let block = self.blocks[i]
            guard case .table = block else {
                if let o = _tableOverlays[i] {
                    o.scroll.removeFromSuperview()
                    self._tableOverlays.removeValue(forKey: i)
                }
                continue
            }
            let naturalWidth = self._tableNaturalWidth(at: i)
            guard naturalWidth > viewWidth + 0.5 else {
                // Table fits — remove any stale overlay.
                if let o = _tableOverlays[i] {
                    o.scroll.removeFromSuperview()
                    self._tableOverlays.removeValue(forKey: i)
                }
                continue
            }
            guard
                let blockFrame = decorations.blockFrameUnion(at: i),
                !blockFrame.isNull, blockFrame.height > 0 else {
                continue
            }

            if let existing = _tableOverlays[i], existing.block == block {
                // Identical content — only reposition. Disable CA implicit animation to prevent jitter.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                existing.scroll.frame = CGRect(
                    x: 0,
                    y: blockFrame.minY - 8,
                    width: viewWidth,
                    height: existing.scroll.frame.height
                )
                CATransaction.commit()
                continue
            }

            // Same column structure (naturalWidth unchanged) — update content in place.
            // This is the common streaming case: cells grow but column count stays fixed.
            // Reusing the existing UIScrollView preserves contentOffset so the user's
            // horizontal scroll position is not reset on every streaming token.
            if let existing = _tableOverlays[i], abs(existing.naturalWidth - naturalWidth) < 0.5 {
                let renderer = AttributedStringRenderer(
                    style: renderStyle, availableWidth: naturalWidth, placeholderMode: self.renderMode
                )
                let tableStr = renderer.renderBlock(block)
                existing.content.update(tableString: tableStr)
                let newH = existing.content.frame.height
                existing.scroll.contentSize = CGSize(width: naturalWidth, height: newH)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                existing.scroll.frame = CGRect(
                    x: 0,
                    y: blockFrame.minY - 8,
                    width: viewWidth,
                    height: newH
                )
                CATransaction.commit()
                self._tableOverlays[i] = (
                    scroll: existing.scroll,
                    content: existing.content,
                    block: block,
                    naturalWidth: naturalWidth
                )
                continue
            }

            // Column structure changed — (re)create the scroll view.
            self._tableOverlays[i]?.scroll.removeFromSuperview()
            let renderer = AttributedStringRenderer(
                style: renderStyle, availableWidth: naturalWidth, placeholderMode: self.renderMode
            )
            let tableStr = renderer.renderBlock(block)
            let contentView = TableContentView(
                tableString: tableStr,
                style: renderStyle,
                naturalWidth: naturalWidth
            )
            let scrollH = contentView.frame.height
            let scrollView = UIScrollView(frame: CGRect(
                x: 0,
                y: blockFrame.minY - 8,
                width: viewWidth,
                height: scrollH
            ))
            scrollView.contentSize = CGSize(width: naturalWidth, height: scrollH)
            scrollView.showsHorizontalScrollIndicator = true
            scrollView.showsVerticalScrollIndicator = false
            scrollView.alwaysBounceVertical = false
            scrollView.addSubview(contentView)
            // Suppress the implicit fade-in / position animation that UIKit applies
            // when a view is added to the hierarchy during an active touch session.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            addSubview(scrollView)
            CATransaction.commit()
            self._tableOverlays[i] = (
                scroll: scrollView,
                content: contentView,
                block: block,
                naturalWidth: naturalWidth
            )
        }
    }
}

#elseif canImport(AppKit)
import AppKit

extension MarkdownLabelView {
    private func _tableNaturalWidth(at blockIndex: Int) -> CGFloat {
        self.decorations.tableNaturalWidth(at: blockIndex)
    }

    func _syncTableOverlays(from startIndex: Int) {
        let startIndex = max(0, min(startIndex, blocks.count))
        let stale = self._tableOverlays.keys.filter { i -> Bool in
            guard i >= startIndex else {
                return false
            }
            guard i < self.blocks.count, case .table = self.blocks[i] else {
                return true
            }
            return false
        }
        for i in stale {
            self._tableOverlays[i]?.scroll.removeFromSuperview()
            self._tableOverlays.removeValue(forKey: i)
        }

        let viewWidth = bounds.width
        guard startIndex < self.blocks.count else {
            return
        }

        // The reserved height in the main stack is already correct by
        // construction: `AttributedStringRenderer.overflowTablePlaceholder` and
        // the overlay's `TableContentView` both size off the *same*
        // `TableMeasurement.height` call, so there is no write-back and no
        // convergence pass — this loop only positions/sizes the overlay against
        // the (already-correct) reserved geometry from `blockFrameUnion`.
        for i in startIndex ..< self.blocks.count {
            let block = self.blocks[i]
            guard case .table = block else {
                if let o = _tableOverlays[i] {
                    o.scroll.removeFromSuperview()
                    self._tableOverlays.removeValue(forKey: i)
                }
                continue
            }
            let naturalWidth = self._tableNaturalWidth(at: i)
            guard naturalWidth > viewWidth + 0.5 else {
                if let o = _tableOverlays[i] {
                    o.scroll.removeFromSuperview()
                    self._tableOverlays.removeValue(forKey: i)
                }
                continue
            }
            guard
                let blockFrame = decorations.blockFrameUnion(at: i),
                !blockFrame.isNull, blockFrame.height > 0 else {
                continue
            }

            if let existing = _tableOverlays[i], existing.block == block {
                // Identical content — only reposition without implicit animation.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                existing.scroll.frame = NSRect(
                    x: 0,
                    y: blockFrame.minY - 8,
                    width: viewWidth,
                    height: existing.scroll.frame.height
                )
                CATransaction.commit()
                continue
            }

            // Same column structure — update content in place to preserve scroll offset.
            if let existing = _tableOverlays[i], abs(existing.naturalWidth - naturalWidth) < 0.5 {
                let renderer = AttributedStringRenderer(
                    style: renderStyle, availableWidth: naturalWidth, placeholderMode: self.renderMode
                )
                let tableStr = renderer.renderBlock(block)
                existing.content.update(tableString: tableStr)
                let newH = existing.content.frame.height
                existing.scroll.documentView?.setFrameSize(NSSize(width: naturalWidth, height: newH))
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                existing.scroll.frame = NSRect(
                    x: 0,
                    y: blockFrame.minY - 8,
                    width: viewWidth,
                    height: newH
                )
                CATransaction.commit()
                self._tableOverlays[i] = (
                    scroll: existing.scroll,
                    content: existing.content,
                    block: block,
                    naturalWidth: naturalWidth
                )
                continue
            }

            // Column structure changed — (re)create the scroll view.
            self._tableOverlays[i]?.scroll.removeFromSuperview()
            let renderer = AttributedStringRenderer(
                style: renderStyle, availableWidth: naturalWidth, placeholderMode: self.renderMode
            )
            let tableStr = renderer.renderBlock(block)
            let contentView = TableContentView(
                tableString: tableStr,
                style: renderStyle,
                naturalWidth: naturalWidth
            )
            let scrollH = contentView.frame.height
            let scrollView = NSScrollView(frame: NSRect(
                x: 0,
                y: blockFrame.minY - 8,
                width: viewWidth,
                height: scrollH
            ))
            scrollView.hasHorizontalScroller = true
            scrollView.hasVerticalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            scrollView.drawsBackground = false
            scrollView.horizontalScrollElasticity = .automatic
            scrollView.verticalScrollElasticity = .none
            scrollView.documentView = contentView
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            addSubview(scrollView)
            CATransaction.commit()
            self._tableOverlays[i] = (
                scroll: scrollView,
                content: contentView,
                block: block,
                naturalWidth: naturalWidth
            )
        }
    }
}
#endif
