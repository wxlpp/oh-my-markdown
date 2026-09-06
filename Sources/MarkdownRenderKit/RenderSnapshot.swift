import Foundation

/// Full measured contents of an overflow table, owned alongside its main-flow reservation.
/// Retains cell resource owners even while a platform overlay outlives a snapshot swap.
@MainActor
package final class RenderTableOverlay {
    package let attributedString: NSAttributedString
    package let naturalWidth: CGFloat
    package let height: CGFloat
    package let style: RenderStyle
    private let resourceOwners: [any ResourceResidencyOwner]

    package init(attributedString: NSAttributedString, naturalWidth: CGFloat, height: CGFloat, style: RenderStyle, resourceOwners: [any ResourceResidencyOwner]) {
        self.attributedString = NSAttributedString(attributedString: attributedString)
        self.naturalWidth = naturalWidth
        self.height = height
        self.style = style
        self.resourceOwners = resourceOwners
    }
}

@MainActor
public final class RenderSnapshot {
    public let attributedString: NSAttributedString
    public let displayModel: RenderDisplayModel
    package let resourceOwners: [any ResourceResidencyOwner]
    package let blockStarts: [Int]
    package let tableOverlays: [Int: RenderTableOverlay]

    package init(
        attributedString: NSAttributedString, displayModel: RenderDisplayModel,
        resourceOwners: [any ResourceResidencyOwner], blockStarts: [Int] = [], tableOverlays: [Int: RenderTableOverlay] = [:]
    ) {
        self.attributedString = NSAttributedString(attributedString: attributedString)
        self.displayModel = displayModel
        self.resourceOwners = resourceOwners
        self.blockStarts = blockStarts
        self.tableOverlays = tableOverlays
    }
}
