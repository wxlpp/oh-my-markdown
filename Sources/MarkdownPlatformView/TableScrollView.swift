// Sources/MarkdownPlatformView/TableScrollView.swift
//
// TableContentView — renders a single table block at its natural (uncompressed) width
// using an independent TextKit 2 stack. Placed inside a UIScrollView / NSScrollView to
// allow horizontal scrolling when the table is wider than the screen.

import Foundation
import MarkdownCore
import MarkdownRenderKit

// MARK: - TableRowBounds

private struct TableRowBounds {
    let section: Int
    let minY: CGFloat
    let maxY: CGFloat
}

#if canImport(UIKit)
import UIKit

@MainActor
final class TableContentView: UIView {
    init(tableString: NSAttributedString, style: RenderStyle, naturalWidth: CGFloat) {
        self.bgColor = style.codeBackgroundColor
        self.separatorColor = style.headingBorderColor
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear

        self.textContainer.lineFragmentPadding = 0
        self.layoutManager.textContainer = self.textContainer
        self.contentStorage.addTextLayoutManager(self.layoutManager)
        self.contentStorage.attributedString = tableString

        self.textContainer.size = CGSize(width: naturalWidth, height: .greatestFiniteMagnitude)
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        // Height is the single source of truth shared with the main-stack
        // reservation. We reuse *this view's own* already-`ensureLayout`'d
        // layout manager via `height(usingLaidOut:)` instead of building a
        // second TextKit 2 stack + second full layout per init: same stack
        // config (`lineFragmentPadding = 0`, container width = natural width,
        // full layout) → same `heightCore` arithmetic → constructively equal
        // to `overflowTablePlaceholder`'s `height(of:naturalWidth:)`.
        frame = CGRect(
            x: 0,
            y: 0,
            width: naturalWidth,
            height: TableMeasurement.height(usingLaidOut: self.layoutManager)
        )
        self.rebuildRowBounds()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(tableString:style:naturalWidth:)")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else {
            return
        }
        guard let str = contentStorage.attributedString, str.length > 0 else {
            return
        }

        let cols = str.attribute(.markdownTableColumns, at: 0, effectiveRange: nil) as? Int ?? 0
        let outerRect = bounds
        let outerPath = CGPath(roundedRect: outerRect, cornerWidth: 6, cornerHeight: 6, transform: nil)

        ctx.saveGState()

        // Background fill
        ctx.addPath(outerPath)
        ctx.setFillColor(self.bgColor.withAlphaComponent(0.5).cgColor)
        ctx.fillPath()

        // Clip inner content to the rounded rect
        ctx.saveGState()
        ctx.addPath(outerPath)
        ctx.clip()

        let startLoc = self.contentStorage.documentRange.location

        // Header row: slightly darker background
        if let header = rowBounds.first(where: { $0.section == 0 }) {
            ctx.setFillColor(self.bgColor.cgColor)
            ctx.fill(CGRect(
                x: 0,
                y: header.minY - 4,
                width: outerRect.width,
                height: header.maxY - header.minY + 8
            ))
        }

        // Vertical column separator lines
        if cols > 1 {
            let colWidths = self.tableColumnWidths(in: str, columns: cols, totalWidth: outerRect.width)
            var x = outerRect.minX + 14
            ctx.setFillColor(self.separatorColor.withAlphaComponent(0.35).cgColor)
            for width in colWidths.dropLast() {
                x += width
                ctx.fill(CGRect(x: x - 0.25, y: outerRect.minY, width: 0.5, height: outerRect.height))
            }
        }

        // Horizontal row separators: thicker after header, same color as body row separators
        for i in 1 ..< self.rowBounds.count {
            let y = (rowBounds[i - 1].maxY + self.rowBounds[i].minY) / 2
            let lineH: CGFloat = i == 1 ? 1.0 : 0.5
            let alpha: CGFloat = 0.4
            ctx.setFillColor(self.separatorColor.withAlphaComponent(alpha).cgColor)
            ctx.fill(CGRect(x: 0, y: y - lineH / 2, width: outerRect.width, height: lineH))
        }

        ctx.restoreGState() // remove clip

        // Outer border stroke
        ctx.addPath(outerPath)
        ctx.setStrokeColor(self.separatorColor.withAlphaComponent(0.2).cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokePath()

        ctx.restoreGState()

        // Draw text fragments, shifted down by textOffsetY
        self.layoutManager.enumerateTextLayoutFragments(
            from: startLoc,
            options: [.ensuresLayout, .ensuresExtraLineFragment]
        ) { frag in
            let origin = CGPoint(
                x: frag.layoutFragmentFrame.origin.x,
                y: frag.layoutFragmentFrame.origin.y + self.textOffsetY
            )
            frag.draw(at: origin, in: ctx)
            return true
        }
    }

    /// Update table content in place without recreating the view.
    /// Preserves the parent UIScrollView's contentOffset so the user's
    /// horizontal scroll position is not reset during streaming updates.
    func update(tableString: NSAttributedString) {
        self.contentStorage.attributedString = tableString
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        // Same single source of truth as init — reuse this view's own
        // already-laid-out layout manager (no second TextKit 2 stack).
        let newH = TableMeasurement.height(usingLaidOut: self.layoutManager)
        if abs(frame.height - newH) > 0.5 {
            frame.size.height = newH
        }
        self.rebuildRowBounds()
        setNeedsDisplay()
    }

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(size: .zero)
    private let bgColor: UIColor
    private let separatorColor: UIColor
    private var rowBounds: [TableRowBounds] = []
    private let textOffsetY: CGFloat = 8

    private func rebuildRowBounds() {
        guard let str = contentStorage.attributedString, str.length > 0 else {
            self.rowBounds = []
            return
        }

        var bounds: [TableRowBounds] = []
        var curSection = -1
        var curMinY: CGFloat = 0
        var curMaxY: CGFloat = 0
        let startLoc = self.contentStorage.documentRange.location
        let strLen = str.length
        self.layoutManager.enumerateTextLayoutFragments(from: startLoc, options: [.ensuresLayout]) { frag in
            let off = self.contentStorage.offset(
                from: self.contentStorage.documentRange.location,
                to: frag.rangeInElement.location
            )
            guard off < strLen else {
                return false
            }
            let sec = str.attribute(.markdownTableSection, at: off, effectiveRange: nil) as? Int ?? 0
            let ff = frag.layoutFragmentFrame
            if sec != curSection {
                if curSection >= 0 {
                    bounds.append(TableRowBounds(
                        section: curSection,
                        minY: curMinY + self.textOffsetY,
                        maxY: curMaxY + self.textOffsetY
                    ))
                }
                curSection = sec
                curMinY = ff.minY
                curMaxY = ff.maxY
            } else {
                curMaxY = max(curMaxY, ff.maxY)
            }
            return true
        }
        if curSection >= 0 {
            bounds.append(TableRowBounds(
                section: curSection,
                minY: curMinY + self.textOffsetY,
                maxY: curMaxY + self.textOffsetY
            ))
        }
        self.rowBounds = bounds
    }

    private func tableColumnWidths(in str: NSAttributedString, columns: Int, totalWidth: CGFloat) -> [CGFloat] {
        if
            let widths = str.attribute(.markdownTableColumnWidths, at: 0, effectiveRange: nil) as? [CGFloat],
            widths.count == columns {
            return widths
        }
        return Array(repeating: (totalWidth - 28) / CGFloat(max(columns, 1)), count: columns)
    }
}

#elseif canImport(AppKit)
import AppKit

@MainActor
final class TableContentView: NSView {
    init(tableString: NSAttributedString, style: RenderStyle, naturalWidth: CGFloat) {
        self.bgColor = style.codeBackgroundColor
        self.separatorColor = style.headingBorderColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        self.textContainer.lineFragmentPadding = 0
        self.layoutManager.textContainer = self.textContainer
        self.contentStorage.addTextLayoutManager(self.layoutManager)
        self.contentStorage.attributedString = tableString

        self.textContainer.size = CGSize(width: naturalWidth, height: .greatestFiniteMagnitude)
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        // Height is the single source of truth shared with the main-stack
        // reservation. We reuse *this view's own* already-`ensureLayout`'d
        // layout manager via `height(usingLaidOut:)` instead of building a
        // second TextKit 2 stack + second full layout per init: same stack
        // config (`lineFragmentPadding = 0`, container width = natural width,
        // full layout) → same `heightCore` arithmetic → constructively equal
        // to `overflowTablePlaceholder`'s `height(of:naturalWidth:)`.
        frame = CGRect(
            x: 0,
            y: 0,
            width: naturalWidth,
            height: TableMeasurement.height(usingLaidOut: self.layoutManager)
        )
        self.rebuildRowBounds()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(tableString:style:naturalWidth:)")
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            return
        }
        guard let str = contentStorage.attributedString, str.length > 0 else {
            return
        }

        let cols = str.attribute(.markdownTableColumns, at: 0, effectiveRange: nil) as? Int ?? 0
        let outerRect = bounds
        let outerPath = CGPath(roundedRect: outerRect, cornerWidth: 6, cornerHeight: 6, transform: nil)

        ctx.saveGState()

        ctx.addPath(outerPath)
        ctx.setFillColor(self.bgColor.withAlphaComponent(0.5).cgColor)
        ctx.fillPath()

        ctx.saveGState()
        ctx.addPath(outerPath)
        ctx.clip()

        let startLoc = self.contentStorage.documentRange.location

        if let header = rowBounds.first(where: { $0.section == 0 }) {
            ctx.setFillColor(self.bgColor.cgColor)
            ctx.fill(CGRect(
                x: 0,
                y: header.minY - 4,
                width: outerRect.width,
                height: header.maxY - header.minY + 8
            ))
        }

        if cols > 1 {
            let colWidths = self.tableColumnWidths(in: str, columns: cols, totalWidth: outerRect.width)
            var x = outerRect.minX + 14
            ctx.setFillColor(self.separatorColor.withAlphaComponent(0.35).cgColor)
            for width in colWidths.dropLast() {
                x += width
                ctx.fill(CGRect(x: x - 0.25, y: outerRect.minY, width: 0.5, height: outerRect.height))
            }
        }

        for i in 1 ..< self.rowBounds.count {
            let y = (rowBounds[i - 1].maxY + self.rowBounds[i].minY) / 2
            let lineH: CGFloat = i == 1 ? 1.0 : 0.5
            let alpha: CGFloat = 0.4
            ctx.setFillColor(self.separatorColor.withAlphaComponent(alpha).cgColor)
            ctx.fill(CGRect(x: 0, y: y - lineH / 2, width: outerRect.width, height: lineH))
        }

        ctx.restoreGState()

        ctx.addPath(outerPath)
        ctx.setStrokeColor(self.separatorColor.withAlphaComponent(0.2).cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokePath()

        ctx.restoreGState()

        self.layoutManager.enumerateTextLayoutFragments(
            from: startLoc,
            options: [.ensuresLayout, .ensuresExtraLineFragment]
        ) { frag in
            let origin = CGPoint(
                x: frag.layoutFragmentFrame.origin.x,
                y: frag.layoutFragmentFrame.origin.y + self.textOffsetY
            )
            frag.draw(at: origin, in: ctx)
            return true
        }
    }

    /// Update table content in place without recreating the view.
    /// Preserves the parent NSScrollView's scroll position during streaming updates.
    func update(tableString: NSAttributedString) {
        self.contentStorage.attributedString = tableString
        self.layoutManager.ensureLayout(for: self.layoutManager.documentRange)
        // Same single source of truth as init — reuse this view's own
        // already-laid-out layout manager (no second TextKit 2 stack).
        let newH = TableMeasurement.height(usingLaidOut: self.layoutManager)
        if abs(frame.height - newH) > 0.5 {
            frame.size.height = newH
        }
        self.rebuildRowBounds()
        needsDisplay = true
    }

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(size: .zero)
    private let bgColor: NSColor
    private let separatorColor: NSColor
    private var rowBounds: [TableRowBounds] = []
    private let textOffsetY: CGFloat = 8

    private func rebuildRowBounds() {
        guard let str = contentStorage.attributedString, str.length > 0 else {
            self.rowBounds = []
            return
        }

        var bounds: [TableRowBounds] = []
        var curSection = -1
        var curMinY: CGFloat = 0
        var curMaxY: CGFloat = 0
        let startLoc = self.contentStorage.documentRange.location
        let strLen = str.length
        self.layoutManager.enumerateTextLayoutFragments(from: startLoc, options: [.ensuresLayout]) { frag in
            let off = self.contentStorage.offset(
                from: self.contentStorage.documentRange.location,
                to: frag.rangeInElement.location
            )
            guard off < strLen else {
                return false
            }
            let sec = str.attribute(.markdownTableSection, at: off, effectiveRange: nil) as? Int ?? 0
            let ff = frag.layoutFragmentFrame
            if sec != curSection {
                if curSection >= 0 {
                    bounds.append(TableRowBounds(
                        section: curSection,
                        minY: curMinY + self.textOffsetY,
                        maxY: curMaxY + self.textOffsetY
                    ))
                }
                curSection = sec
                curMinY = ff.minY
                curMaxY = ff.maxY
            } else {
                curMaxY = max(curMaxY, ff.maxY)
            }
            return true
        }
        if curSection >= 0 {
            bounds.append(TableRowBounds(
                section: curSection,
                minY: curMinY + self.textOffsetY,
                maxY: curMaxY + self.textOffsetY
            ))
        }
        self.rowBounds = bounds
    }

    private func tableColumnWidths(in str: NSAttributedString, columns: Int, totalWidth: CGFloat) -> [CGFloat] {
        if
            let widths = str.attribute(.markdownTableColumnWidths, at: 0, effectiveRange: nil) as? [CGFloat],
            widths.count == columns {
            return widths
        }
        return Array(repeating: (totalWidth - 28) / CGFloat(max(columns, 1)), count: columns)
    }
}
#endif
