import CoreGraphics
import Foundation

@MainActor
package struct ResolvedResourceSnapshot {
    package let values: [ResourceID: ResolvedPlatformResource]
    /// Every owner this resolution acquired, in a stable order, so a snapshot
    /// transaction can roll back exactly what it admitted.
    package var owners: [any ResourceResidencyOwner] {
        self.values.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { self.values[$0]?.owner }
    }

    package init(values: [ResourceID: ResolvedPlatformResource]) {
        self.values = values
    }
}

@MainActor
package protocol ResourceResidencyOwner: AnyObject {
    /// Idempotent. Explicit release is the normal path; every implementation also
    /// releases from `deinit` so a dropped owner cannot strand residency cost.
    func release()
}

@MainActor
package protocol RenderedResourceOwning: ResourceResidencyOwner {
    var image: PlatformImage { get }
    var baselineOffset: Double { get }
    func acquirePublication() -> any RenderedResourceOwning
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
            let (rawRowBytes, rowOverflow) = frame.width.multipliedReportingOverflow(by: 4)
            let (padded, paddingOverflow) = rawRowBytes.addingReportingOverflow(63)
            guard !rowOverflow, !paddingOverflow else { throw ValidationError.sizeOverflow }
            let rowBytes = padded / 64 * 64
            let (count, countOverflow) = rowBytes.multipliedReportingOverflow(by: frame.height)
            let (nextTotal, totalOverflow) = total.addingReportingOverflow(count)
            guard !rowOverflow, !countOverflow, !totalOverflow else { throw ValidationError.sizeOverflow }
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(
                .byteOrder32Little
            )
            guard
                let context = CGContext(
                    data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8,
                    bytesPerRow: rowBytes, space: space, bitmapInfo: info.rawValue
                )
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
                      shouldInterpolate: frame.shouldInterpolate, intent: frame.renderingIntent
                  )
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
    case math(owner: any RenderedResourceOwning)
    case svg(owner: any RenderedResourceOwning)

    package var owner: any ResourceResidencyOwner {
        switch self {
        case .image(_, let owner): owner
        case .math(let owner), .svg(let owner): owner
        }
    }
}
