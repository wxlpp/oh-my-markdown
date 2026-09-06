import CoreGraphics
import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// The only new boundary that creates platform rendering objects.
@MainActor
package struct RenderMaterializer {
  private let configuration: RenderConfigurationSnapshot

  package init(configuration: RenderConfigurationSnapshot) { self.configuration = configuration }

  package func materialize(_ model: RenderDisplayModel, resources: ResolvedResourceSnapshot)
    -> RenderSnapshot
  {
    let result = NSMutableAttributedString(string: "")
    var owners: [any ResourceResidencyOwner] = []
    for run in model.runs {
      let font = font(for: run.role)
      let token = run.role == .code ? configuration.colors.code : configuration.colors.body
      let paragraph = NSMutableParagraphStyle()
      paragraph.paragraphSpacing = configuration.spacing.paragraph
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: color(token), .paragraphStyle: paragraph,
      ]
      if let id = run.resourceID, let resource = resources.values[id] {
        let image: PlatformImage
        let baseline: Double
        let owner: any ResourceResidencyOwner
        switch resource {
        case .image(let value, let retained), .svg(let value, let retained):
          image = value
          baseline = 0
          owner = retained
        case .math(let value, let offset, let retained):
          image = value
          baseline = offset
          owner = retained
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
          x: 0, y: baseline, width: image.size.width, height: image.size.height)
        let text = NSMutableAttributedString(attachment: attachment)
        text.addAttributes(attributes, range: NSRange(location: 0, length: text.length))
        result.append(text)
        owners.append(owner)
      } else {
        result.append(NSAttributedString(string: run.text, attributes: attributes))
      }
    }
    return RenderSnapshot(attributedString: result, displayModel: model, resourceOwners: owners)
  }

  /// Converts audited immutable image backing to a platform image only here.
  package func platformImage(
    from backing: ImmutableCGImageBacking, frame: Int = 0, scale: Double = 1
  ) -> PlatformImage? {
    guard backing.frames.indices.contains(frame), scale.isFinite, scale > 0 else { return nil }
    let image = backing.frames[frame]
    #if canImport(UIKit)
      return UIImage(cgImage: image, scale: scale, orientation: .up)
    #else
      return NSImage(
        cgImage: image,
        size: NSSize(width: Double(image.width) / scale, height: Double(image.height) / scale))
    #endif
  }

  private func font(for role: MarkdownTextRole) -> PlatformFont {
    let size =
      configuration.typography.pointSizes[role] ?? configuration.typography.pointSizes[.body] ?? 16
    if let data = configuration.typography.fontDescriptors[role] {
      #if canImport(UIKit)
        if let descriptor = try? NSKeyedUnarchiver.unarchivedObject(
          ofClass: UIFontDescriptor.self, from: data)
        {
          return UIFont(descriptor: descriptor, size: size)
        }
      #else
        if let descriptor = try? NSKeyedUnarchiver.unarchivedObject(
          ofClass: NSFontDescriptor.self, from: data),
          let font = NSFont(descriptor: descriptor, size: size)
        {
          return font
        }
      #endif
    }
    if let name = configuration.typography.fontNames[role],
      let font = PlatformFont(name: name, size: size)
    {
      return font
    }
    return role == .code
      ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
  }

  private func color(_ token: ColorToken) -> PlatformColor {
    PlatformColor(red: token.red, green: token.green, blue: token.blue, alpha: token.alpha)
  }
}
