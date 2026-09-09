import CoreGraphics
import Foundation
import ImageIO
import MarkdownRenderKit

package struct DecodedImage {
    package let backingID: UUID
    package let backing: ImmutableCGImageBacking
    /// Extent that actually produced this backing. The decoder halves it on a
    /// reconciliation rejection, so the caller must read it here rather than
    /// assume the extent it asked for.
    package let decodedPixelSize: Int
    package init(backingID: UUID = UUID(), backing: ImmutableCGImageBacking, decodedPixelSize: Int) {
        self.backingID = backingID
        self.backing = backing
        self.decodedPixelSize = decodedPixelSize
    }
}

/// Decoder outcomes the caller must classify differently. `unsupported` is a
/// deterministic property of the bytes and may enter the negative cache;
/// `budgetDeferred` depends on transient residency and must never be cached.
package enum ImageDecodeFailure: Error, Equatable {
    case unsupported, budgetDeferred
}

package enum ImageDecoder {
    package static let maxOutputSide = 4096
    package static let perImageByteLimit = 64 << 20

    /// Accounted cost of one retained frame: 64-byte aligned BGRA rows.
    package static func pixelCost(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (row, overflow) = width.multipliedReportingOverflow(by: 4)
        let (padded, paddingOverflow) = row.addingReportingOverflow(63)
        guard !overflow, !paddingOverflow else { return nil }
        let (bytes, totalOverflow) = (padded / 64 * 64).multipliedReportingOverflow(by: height)
        return totalOverflow ? nil : bytes
    }

    /// Upper bound of the thumbnail extent for a source frame. ImageIO fits the
    /// longest side; rounding up keeps the pre-decode reservation conservative so
    /// reconciliation can only shrink.
    package static func thumbnailExtent(width: Int, height: Int, maxPixelSize: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0, maxPixelSize > 0 else { return nil }
        let side = min(maxPixelSize, self.maxOutputSide)
        let longest = max(width, height)
        guard longest > side else { return (width, height) }
        let scale = Double(side) / Double(longest)
        let scaled = { (value: Int) in max(1, Int((Double(value) * scale).rounded(.up))) }
        return (scaled(width), scaled(height))
    }

    /// Conservative decoded-pixel reservation for the frames this decoder retains.
    /// Only frame 0 is retained today; the sum keeps the formula correct if that grows.
    ///
    /// Row alignment is not symmetric under a width/height swap, and an EXIF
    /// orientation makes ImageIO return the transposed extent, so this reserves the
    /// larger of the two orientations. Reconciliation can then only shrink,
    /// whichever way the frame comes back.
    package static func reservationBytes(for metadata: MarkdownImageMetadata, maxPixelSize: Int) -> Int? {
        guard let extent = thumbnailExtent(width: metadata.pixelWidth, height: metadata.pixelHeight, maxPixelSize: maxPixelSize),
              let upright = pixelCost(width: extent.width, height: extent.height),
              let transposed = pixelCost(width: extent.height, height: extent.width)
        else { return nil }
        let bytes = max(upright, transposed)
        return bytes <= self.perImageByteLimit ? bytes : nil
    }

    /// Downsamples straight out of ImageIO. The full-resolution image is never
    /// materialized, and the encoded reservation is released on every exit path.
    ///
    /// `reconcile` receives the actual accounted bytes before the result is
    /// returned. Rejecting once halves the requested extent and decodes again;
    /// a second rejection fails as `budgetDeferred`. The retry happens here
    /// because the encoded body is released the moment this call returns.
    @concurrent package static func decode(
        _ reserved: ReservedEncodedImage, maxPixelSize: Int,
        permit: ImageResourcePermit? = nil,
        reconcile: (@MainActor @Sendable (Int) -> Bool)? = nil
    ) async throws -> DecodedImage {
        do {
            let decoded = try await self.downsample(reserved, maxPixelSize: maxPixelSize, reconcile: reconcile)
            await reserved.reservation.consumedByDecoder()
            await permit?.release()
            return decoded
        } catch {
            await reserved.reservation.rejectAndRelease()
            await permit?.release()
            throw error
        }
    }

    private static func downsample(
        _ reserved: ReservedEncodedImage, maxPixelSize: Int, reconcile: (@MainActor @Sendable (Int) -> Bool)?
    ) async throws -> DecodedImage {
        let encoded = try await reserved.reservation.imageForDecoder()
        var side = min(max(1, maxPixelSize), self.maxOutputSide)
        var attempts = 0
        while true {
            try Task.checkCancellation()
            let backing = try self.thumbnail(encoded, side: side)
            guard let reconcile else { return DecodedImage(backing: backing, decodedPixelSize: side) }
            if await reconcile(backing.accountedPixelBytes) {
                return DecodedImage(backing: backing, decodedPixelSize: side)
            }
            attempts += 1
            guard attempts == 1, side > 1 else { throw ImageDecodeFailure.budgetDeferred }
            side = max(1, side / 2)
        }
    }

    private static func thumbnail(_ encoded: MarkdownEncodedImage, side: Int) throws -> ImmutableCGImageBacking {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false]
        guard let source = CGImageSourceCreateWithData(encoded.data as CFData, options as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) > 0
        else { throw ImageDecodeFailure.unsupported }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        else { throw ImageDecodeFailure.unsupported }
        guard frame.width <= self.maxOutputSide, frame.height <= self.maxOutputSide,
              let cost = pixelCost(width: frame.width, height: frame.height), cost <= self.perImageByteLimit
        else { throw ImageDecodeFailure.budgetDeferred }
        guard let backing = try? ImmutableCGImageBacking(frames: [frame]) else { throw ImageDecodeFailure.unsupported }
        return backing
    }
}
