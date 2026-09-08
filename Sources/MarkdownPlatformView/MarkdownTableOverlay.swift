import Foundation
import MarkdownRenderKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension MarkdownLabelView {
    /// Installs only materialized snapshot data; no Markdown traversal occurs here.
    func _syncTableOverlays(from startIndex: Int) {
        let tables = self.currentSnapshot?.tableOverlays ?? [:]
        let viewWidth = bounds.width
        for index in self._tableOverlays.keys.filter({ $0 >= startIndex }) {
            if tables[index] == nil || tables[index]!.naturalWidth <= viewWidth + 0.5 {
                self._tableOverlays[index]?.scroll.removeFromSuperview()
                self._tableOverlays.removeValue(forKey: index)
            }
        }
        for index in tables.keys.sorted() where index >= startIndex {
            guard let data = tables[index], data.naturalWidth > viewWidth + 0.5,
                  let blockFrame = self.decorations.blockFrameUnion(at: index),
                  !blockFrame.isNull, blockFrame.height > 0 else { continue }
            if let existing = self._tableOverlays[index],
               abs(existing.naturalWidth - data.naturalWidth) < 0.5,
               existing.data.style.isSemanticallyEqual(to: data.style) {
                if existing.data !== data { existing.content.update(tableString: data.attributedString) }
                #if canImport(UIKit)
                existing.scroll.contentSize = CGSize(width: data.naturalWidth, height: data.height)
                #else
                existing.scroll.documentView?.setFrameSize(NSSize(width: data.naturalWidth, height: data.height))
                #endif
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                existing.scroll.frame = CGRect(x: 0, y: blockFrame.minY - 8, width: viewWidth, height: data.height)
                CATransaction.commit()
                self._tableOverlays[index] = (scroll: existing.scroll, content: existing.content, data: data, naturalWidth: data.naturalWidth)
                continue
            }
            self._tableOverlays[index]?.scroll.removeFromSuperview()
            let content = TableContentView(tableString: data.attributedString, style: data.style, naturalWidth: data.naturalWidth)
            let frame = CGRect(x: 0, y: blockFrame.minY - 8, width: viewWidth, height: data.height)
            #if canImport(UIKit)
            let scroll = UIScrollView(frame: frame)
            scroll.contentSize = CGSize(width: data.naturalWidth, height: data.height)
            scroll.showsHorizontalScrollIndicator = true
            scroll.showsVerticalScrollIndicator = false
            scroll.alwaysBounceVertical = false
            scroll.addSubview(content)
            #else
            let scroll = NSScrollView(frame: frame)
            scroll.hasHorizontalScroller = true
            scroll.hasVerticalScroller = false
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.drawsBackground = false
            scroll.horizontalScrollElasticity = .automatic
            scroll.verticalScrollElasticity = .none
            scroll.documentView = content
            #endif
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            addSubview(scroll)
            CATransaction.commit()
            self._tableOverlays[index] = (scroll: scroll, content: content, data: data, naturalWidth: data.naturalWidth)
        }
        // An overflowing table's cells are laid out here, not in the main
        // document, so their elements can only take a frame once this has run.
        self.rebuildAccessibilityElements()
    }
}
