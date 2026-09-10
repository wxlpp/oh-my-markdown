import CoreGraphics
import Foundation
@testable import MarkdownRenderKit

func encodedTestImage(size: CGSize) -> RenderedImage {
    let width = max(2, Int(size.width))
    let height = max(2, Int(size.height))
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return try! RenderedImage(cgImage: context.makeImage()!, pointSize: size)
}
