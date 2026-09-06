import Foundation

@MainActor
public final class RenderSnapshot {
  public let attributedString: NSAttributedString
  public let displayModel: RenderDisplayModel
  package let resourceOwners: [any ResourceResidencyOwner]

  package init(
    attributedString: NSAttributedString, displayModel: RenderDisplayModel,
    resourceOwners: [any ResourceResidencyOwner]
  ) {
    self.attributedString = NSAttributedString(attributedString: attributedString)
    self.displayModel = displayModel
    self.resourceOwners = resourceOwners
  }
}
