import Foundation

@MainActor
public final class RenderSnapshot {
    public let attributedString: NSAttributedString
    public let displayModel: RenderDisplayModel
    package let resourceOwners: [any ResourceResidencyOwner]
    package let blockStarts: [Int]

    package init(
        attributedString: NSAttributedString, displayModel: RenderDisplayModel,
        resourceOwners: [any ResourceResidencyOwner], blockStarts: [Int] = []
    ) {
        self.attributedString = NSAttributedString(attributedString: attributedString)
        self.displayModel = displayModel
        self.resourceOwners = resourceOwners
        self.blockStarts = blockStarts
    }
}
