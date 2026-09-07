import Foundation
import MarkdownCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Custom attribute keys

extension NSAttributedString.Key {
    /// Image source URL string; marks inline placeholder text pending async load.
    public static let markdownImageSource = NSAttributedString.Key("MarkdownKit.imageSource")
    /// Table row section: 0 = header, 1+ = body row index (used by decoration drawing).
    public static let markdownTableSection = NSAttributedString.Key("MarkdownKit.tableSection")
    /// Number of columns in the table (used to compute tab stops and draw column separators).
    public static let markdownTableColumns = NSAttributedString.Key("MarkdownKit.tableColumns")
    /// Natural (uncompressed) table width when the table overflows the available width.
    /// Presence of this attribute signals the view to show a horizontal-scroll overlay.
    public static let markdownTableNaturalWidth = NSAttributedString.Key("MarkdownKit.tableNaturalWidth")
    /// Natural widths for each rendered table column, used by platform views to draw separators.
    public static let markdownTableColumnWidths = NSAttributedString.Key("MarkdownKit.tableColumnWidths")
    /// Marks the single transparent placeholder line that reserves vertical
    /// space for an overflowing (horizontally-scrolling) table. The real table is
    /// drawn by the platform scroll overlay; the reserved height is computed *at
    /// render time* by `TableMeasurement.height` (the same algorithm the overlay's
    /// `TableContentView` uses), so the main-stack reservation and the overlay
    /// height are constructively equal — no platform write-back needed.
    public static let markdownOverflowTablePlaceholder
        = NSAttributedString.Key("MarkdownKit.overflowTablePlaceholder")
}

// MARK: - TableMeasurement

/// Single source of truth for an overflowing table's rendered height.
///
/// Both the main-stack reservation (`RenderMaterializer`)
/// and the platform scroll overlay (`TableContentView`) call this *exact* function
/// with the *exact* same inputs (the full non-overflow table attributed string and
/// the table's natural width), so the height they use is constructively equal — it
/// is the same arithmetic on the same TextKit 2 layout, not two algorithms that
/// happen to agree within a tolerance.
@MainActor
public enum TableMeasurement {
    /// The single height arithmetic core: `ceil(usageBoundsForTextContainer
    /// .height) + 16` (the +16 chrome inset). Both entry points
    /// (`height(of:naturalWidth:)` building its own stack, and
    /// `height(usingLaidOut:)` reusing an already-laid-out manager) funnel
    /// through *this* function, so for the same table content they produce a
    /// byte-for-byte identical height — the wide-table root-cause invariant
    /// (constructive equality, one arithmetic, never two algorithms).
    @inline(__always)
    private static func heightCore(usingLaidOut layoutManager: NSTextLayoutManager) -> CGFloat {
        ceil(layoutManager.usageBoundsForTextContainer.height) + 16
    }

    /// Reuse a TextKit 2 layout manager the caller has **already laid out**
    /// (e.g. `TableContentView`'s own stack after its `ensureLayout`) and
    /// return the table height via the shared `heightCore`. The caller is
    /// responsible for configuring the stack identically to
    /// `height(of:naturalWidth:)` (`lineFragmentPadding = 0`, container width
    /// = natural width, full `ensureLayout`) so the inputs to `heightCore` are
    /// the same — avoiding a second TextKit 2 stack + second full layout per
    /// init / streaming table update while keeping the height constructively
    /// equal to the main-stack reservation.
    public static func height(usingLaidOut layoutManager: NSTextLayoutManager) -> CGFloat {
        self.heightCore(usingLaidOut: layoutManager)
    }

    /// Lays `tableString` out in an independent TextKit 2 stack constrained to
    /// `naturalWidth`, then returns the height via the shared `heightCore`
    /// (`lineFragmentPadding = 0`, container width = natural width, full
    /// `ensureLayout`, +16 chrome inset). Used by the main-stack reservation
    /// (`overflowTablePlaceholder`) which has no pre-existing layout manager.
    /// Pure, MainActor-free, platform-neutral.
    public static func height(of tableString: NSAttributedString, naturalWidth: CGFloat) -> CGFloat {
        guard tableString.length > 0, naturalWidth > 0 else {
            return 0
        }
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        textContainer.lineFragmentPadding = 0
        layoutManager.textContainer = textContainer
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.attributedString = tableString
        textContainer.size = CGSize(width: naturalWidth, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return self.heightCore(usingLaidOut: layoutManager)
    }
}
