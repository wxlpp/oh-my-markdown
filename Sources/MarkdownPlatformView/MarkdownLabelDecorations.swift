import Foundation
import MarkdownCore
import MarkdownRenderKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - MarkdownLabelDecorations

/// Per-pass snapshot used to draw block-level decorations (code background, blockquote bar,
/// heading underline, thematic break, table chrome) behind the rendered text.
///
/// The struct is constructed at draw time from view state — it owns no mutable state, so
/// both the iOS and macOS view classes share a single implementation here instead of
/// maintaining two byte-identical copies.
struct MarkdownLabelDecorations {
    let style: RenderStyle
    let bounds: CGRect
    let layoutManager: NSTextLayoutManager
    let contentStorage: NSTextContentStorage
    let liveString: NSAttributedString
    let blockStarts: [Int]

    var documentLength: Int {
        self.contentStorage.offset(
            from: self.contentStorage.documentRange.location,
            to: self.contentStorage.documentRange.endLocation
        )
    }

    func locationAt(_ offset: Int) -> (any NSTextLocation)? {
        self.contentStorage.location(self.contentStorage.documentRange.location, offsetBy: offset)
    }

    func makeTextRange(from: Int, to: Int) -> NSTextRange? {
        guard let s = locationAt(from), let e = locationAt(to) else {
            return nil
        }
        return NSTextRange(location: s, end: e)
    }

    func blockFrameUnion(at index: Int) -> CGRect? {
        guard index < self.blockStarts.count else {
            return nil
        }
        let start = self.blockStarts[index]
        let end = index + 1 < self.blockStarts.count ? self.blockStarts[index + 1] - 1 : self.documentLength
        guard start < end, let tr = makeTextRange(from: start, to: end) else {
            return nil
        }
        var result = CGRect.null
        self.layoutManager.enumerateTextSegments(in: tr, type: .standard, options: []) { _, f, _, _ in
            result = result.isNull ? f : result.union(f)
            return true
        }
        return result.isNull ? nil : result
    }

    /// Natural table width stored in the attributed string for the block at `index`, or 0 if no overflow.
    func tableNaturalWidth(at blockIndex: Int) -> CGFloat {
        guard blockIndex < self.blockStarts.count else {
            return 0
        }
        let start = self.blockStarts[blockIndex]
        guard start < self.liveString.length else {
            return 0
        }
        return self.liveString.attribute(.markdownTableNaturalWidth, at: start, effectiveRange: nil)
            as? CGFloat ?? 0
    }

    func tableColumnWidths(
        in str: NSAttributedString,
        at location: Int,
        columns: Int,
        totalWidth: CGFloat
    )
        -> [CGFloat] {
        if
            location < str.length,
            let widths = str.attribute(.markdownTableColumnWidths, at: location, effectiveRange: nil) as? [CGFloat],
            widths.count == columns {
            return widths
        }
        return Array(repeating: (totalWidth - 28) / CGFloat(max(columns, 1)), count: columns)
    }

    /// Walks `blocks` and draws the appropriate decoration for each one.
    func drawAll(blocks: [BlockNode], in ctx: CGContext) {
        for (index, block) in blocks.enumerated() {
            guard let frame = blockFrameUnion(at: index) else {
                continue
            }
            switch block {
            case .codeBlock:
                self.drawCodeBlockBackground(frame, in: ctx)
            case .blockquote:
                self.drawBlockquoteDecoration(frame, in: ctx)
            case .heading(let lvl, _) where lvl <= 2:
                self.drawHeadingBorder(frame, in: ctx)
            case .thematicBreak:
                self.drawThematicBreak(frame, in: ctx)
            case .table:
                if self.tableNaturalWidth(at: index) <= self.bounds.width + 0.5 {
                    self.drawTableDecoration(frame, blockIndex: index, in: ctx)
                }
            default:
                break
            }
        }
    }

    func drawCodeBlockBackground(_ frame: CGRect, in ctx: CGContext) {
        let padded = CGRect(
            x: 0,
            y: frame.minY - 8,
            width: self.bounds.width,
            height: frame.height + 16
        )
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: padded, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(self.style.codeBackgroundColor.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    func drawBlockquoteDecoration(_ frame: CGRect, in ctx: CGContext) {
        let padded = CGRect(
            x: 0,
            y: frame.minY - 4,
            width: self.bounds.width,
            height: frame.height + 8
        )
        ctx.saveGState()
        ctx.setFillColor(self.style.quoteBarColor.withAlphaComponent(0.06).cgColor)
        ctx.fill(padded)
        ctx.setFillColor(self.style.quoteBarColor.cgColor)
        ctx.fill(CGRect(x: padded.minX, y: padded.minY, width: 4, height: padded.height))
        ctx.restoreGState()
    }

    func drawHeadingBorder(_ frame: CGRect, in ctx: CGContext) {
        let y = frame.maxY + 6
        ctx.saveGState()
        ctx.setFillColor(self.style.headingBorderColor.cgColor)
        ctx.fill(CGRect(x: 0, y: y, width: self.bounds.width, height: 1))
        ctx.restoreGState()
    }

    func drawThematicBreak(_ frame: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(self.style.headingBorderColor.cgColor)
        ctx.fill(CGRect(x: 0, y: frame.midY, width: self.bounds.width, height: 1))
        ctx.restoreGState()
    }

    func drawTableDecoration(_ frame: CGRect, blockIndex: Int, in ctx: CGContext) {
        let blockStart = self.blockStarts[blockIndex]
        let blockEnd = blockIndex + 1 < self.blockStarts.count
            ? self.blockStarts[blockIndex + 1] - 1
            : self.documentLength
        guard
            let str = contentStorage.attributedString,
            let startLoc = locationAt(blockStart) else {
            return
        }

        let cols = blockStart < str.length
            ? (str.attribute(.markdownTableColumns, at: blockStart, effectiveRange: nil) as? Int ?? 0)
            : 0

        let outer = CGRect(x: 0, y: frame.minY - 8, width: self.bounds.width, height: frame.height + 16)
        let outerPath = CGPath(roundedRect: outer, cornerWidth: 6, cornerHeight: 6, transform: nil)

        ctx.saveGState()

        ctx.addPath(outerPath)
        ctx.setFillColor(self.style.codeBackgroundColor.withAlphaComponent(0.5).cgColor)
        ctx.fillPath()

        ctx.saveGState()
        ctx.addPath(outerPath)
        ctx.clip()

        var rowBounds: [(section: Int, minY: CGFloat, maxY: CGFloat)] = []
        var curSection = -1
        var curMinY: CGFloat = frame.minY
        var curMaxY: CGFloat = frame.minY
        self.layoutManager.enumerateTextLayoutFragments(
            from: startLoc,
            options: [.ensuresLayout]
        ) { frag in
            let fragOff = self.contentStorage.offset(
                from: self.contentStorage.documentRange.location,
                to: frag.rangeInElement.location
            )
            guard fragOff < blockEnd, fragOff < str.length else {
                return false
            }
            let section = str.attribute(
                .markdownTableSection,
                at: fragOff,
                effectiveRange: nil
            ) as? Int ?? 0
            let ff = frag.layoutFragmentFrame
            if section != curSection {
                if curSection >= 0 {
                    rowBounds.append((curSection, curMinY, curMaxY))
                }
                curSection = section
                curMinY = ff.minY
                curMaxY = ff.maxY
            } else {
                curMaxY = max(curMaxY, ff.maxY)
            }
            return true
        }
        if curSection >= 0 {
            rowBounds.append((curSection, curMinY, curMaxY))
        }

        if let header = rowBounds.first(where: { $0.section == 0 }) {
            ctx.setFillColor(self.style.codeBackgroundColor.cgColor)
            ctx.fill(CGRect(
                x: 0,
                y: header.minY - 4,
                width: self.bounds.width,
                height: header.maxY - header.minY + 8
            ))
        }

        if cols > 1 {
            let colWidths = self.tableColumnWidths(
                in: str,
                at: blockStart,
                columns: cols,
                totalWidth: self.bounds.width
            )
            var x: CGFloat = 14
            ctx.setFillColor(self.style.headingBorderColor.withAlphaComponent(0.35).cgColor)
            for width in colWidths.dropLast() {
                x += width
                ctx.fill(CGRect(x: x - 0.25, y: outer.minY, width: 0.5, height: outer.height))
            }
        }

        for i in 1 ..< rowBounds.count {
            let y = (rowBounds[i - 1].maxY + rowBounds[i].minY) / 2
            let lineH: CGFloat = i == 1 ? 1.0 : 0.5
            let alpha: CGFloat = 0.4
            ctx.setFillColor(self.style.headingBorderColor.withAlphaComponent(alpha).cgColor)
            ctx.fill(CGRect(x: 0, y: y - lineH / 2, width: self.bounds.width, height: lineH))
        }

        ctx.restoreGState() // remove clip

        ctx.addPath(outerPath)
        ctx.setStrokeColor(self.style.headingBorderColor.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        ctx.restoreGState()
    }
}
