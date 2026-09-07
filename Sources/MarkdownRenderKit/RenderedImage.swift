import CoreGraphics
import Foundation
import ImageIO

/// Only package-provided producers may opt into automatic semantic sharing.
package protocol BuiltInRenderedResourceProducer: Sendable {
    var builtInConfigurationID: MarkdownConfigurationID { get }
}

/// Immutable encoded pixels and their layout dimensions in points.
/// Custom producers may return PNG/JPEG bytes; decoding and platform image
/// creation happen only when the current session materializes a result.
public struct RenderedImage: Sendable {
    /// Original encoded pixels. The value owns its bytes and never re-encodes on cache hits.
    public let encodedData: Data
    /// Requested layout size; finite, positive values are required for materialization.
    public let pointSize: CGSize

    /// Creates an immutable transport value without decoding on the producer actor.
    /// Invalid bytes or dimensions are rejected before residency is acquired.
    public init(encodedData: Data, pointSize: CGSize) {
        self.encodedData = encodedData
        self.pointSize = pointSize
    }

    package init(cgImage: CGImage, pointSize: CGSize) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw Failure.encodingFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        self.encodedData = data as Data
        self.pointSize = pointSize
    }

    /// Failures distinguish deterministic input rejection from retryable codec failures.
    public enum Failure: Error, Sendable {
        case invalidDimensions
        case invalidEncodedData
        case encodingFailed
        case decodingFailed

        package var isDeterministic: Bool {
            switch self {
            case .invalidDimensions, .invalidEncodedData: true
            case .encodingFailed, .decodingFailed: false
            }
        }
    }

    @MainActor
    package func materialize() throws(Failure) -> PlatformImage {
        guard self.pointSize.width.isFinite, self.pointSize.height.isFinite,
              self.pointSize.width > 0, self.pointSize.height > 0 else { throw .invalidDimensions }
        guard let source = CGImageSourceCreateWithData(self.encodedData as CFData, nil),
              CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0 else { throw .invalidEncodedData }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw .decodingFailed }
        #if canImport(UIKit)
        return PlatformImage(cgImage: image, scale: CGFloat(image.width) / self.pointSize.width, orientation: .up)
        #else
        return PlatformImage(cgImage: image, size: self.pointSize)
        #endif
    }
}
