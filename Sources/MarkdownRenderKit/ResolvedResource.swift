import CoreGraphics
import Foundation

@MainActor
package struct ResolvedResourceSnapshot {
  package let values: [ResourceID: ResolvedPlatformResource]
  package init(values: [ResourceID: ResolvedPlatformResource]) { self.values = values }
}

@MainActor
package protocol ResourceResidencyOwner: AnyObject {}

/// Temporary retention bridge. Tasks 4C/7 replace glyph/image uses with leases.
@MainActor
package final class LegacyResourceOwner: ResourceResidencyOwner {
  package let retainedObject: AnyObject
  package init(retaining object: AnyObject) { self.retainedObject = object }
}

/// Audited invariant: every frame is rasterized into privately allocated storage,
/// copied into immutable CFData, and exposed only as a read-only CGImage. No
/// CGContext, mutable buffer, provider callback, or platform image escapes.
/// Copying establishes immutability even when an input has a mutable data provider.
/// CGImage/Core Graphics immutable image reads may occur concurrently.
package struct ImmutableCGImageBacking: @unchecked Sendable {
  package let frames: [CGImage]
  package let accountedPixelBytes: Int

  package enum ValidationError: Error { case invalidFrame, allocationFailed, sizeOverflow }

  package init(frames: [CGImage]) throws {
    var owned: [CGImage] = []
    var total = 0
    for frame in frames {
      guard frame.width > 0, frame.height > 0 else { throw ValidationError.invalidFrame }
      let (rowBytes, rowOverflow) = frame.width.multipliedReportingOverflow(by: 4)
      let (count, countOverflow) = rowBytes.multipliedReportingOverflow(by: frame.height)
      let (nextTotal, totalOverflow) = total.addingReportingOverflow(count)
      guard !rowOverflow, !countOverflow, !totalOverflow else { throw ValidationError.sizeOverflow }
      let space = CGColorSpace(name: CGColorSpace.sRGB)!
      let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(
        .byteOrder32Big)
      guard
        let context = CGContext(
          data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8,
          bytesPerRow: rowBytes, space: space, bitmapInfo: info.rawValue)
      else {
        throw ValidationError.allocationFailed
      }
      context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
      guard let pixels = context.data,
        let data = CFDataCreate(nil, pixels.assumingMemoryBound(to: UInt8.self), count),
        let provider = CGDataProvider(data: data),
        let image = CGImage(
          width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
          bytesPerRow: rowBytes, space: space, bitmapInfo: info, provider: provider, decode: nil,
          shouldInterpolate: frame.shouldInterpolate, intent: frame.renderingIntent)
      else {
        throw ValidationError.allocationFailed
      }
      owned.append(image)
      total = nextTotal
    }
    self.frames = owned
    self.accountedPixelBytes = total
  }
}

@MainActor
package enum ResolvedPlatformResource {
  case image(PlatformImage, owner: any ResourceResidencyOwner)
  case math(image: PlatformImage, baselineOffset: Double, owner: any ResourceResidencyOwner)
  case svg(PlatformImage, owner: any ResourceResidencyOwner)
}
