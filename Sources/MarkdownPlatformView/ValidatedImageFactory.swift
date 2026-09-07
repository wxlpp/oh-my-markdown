import Foundation
import ImageIO

package struct MarkdownEncodedImage {
    package let data: Data
    package let metadata: MarkdownImageMetadata
    fileprivate init(validatedData: Data, metadata: MarkdownImageMetadata) {
        self.data = validatedData
        self.metadata = metadata
    }
}

package enum ValidatedImageFactory {
    package static let encodedByteLimit = 20 * 1024 * 1024
    package static let MIMEToType: [String: String] = [
        "image/png": "public.png", "image/jpeg": "public.jpeg", "image/gif": "com.compuserve.gif",
        "image/webp": "org.webmproject.webp", "image/heic": "public.heic", "image/heif": "public.heif",
    ]

    package static func normalizedMIME(_ value: String?) -> String? {
        guard let mime = value?.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              MIMEToType[mime] != nil else { return nil }
        return mime
    }

    /// Runs the untrusted loader and metadata phase outside the main actor while
    /// retaining structured cancellation from the session-owned resource task.
    @concurrent package static func load(_ loader: any MarkdownImageLoading, request: MarkdownImageRequest) async throws -> MarkdownEncodedImage {
        try Task.checkCancellation()
        let payload = try await loader.load(request)
        try Task.checkCancellation()
        let result = try validate(payload)
        try Task.checkCancellation()
        return result
    }

    package static func validate(_ payload: MarkdownImagePayload) throws -> MarkdownEncodedImage {
        try Task.checkCancellation()
        guard payload.data.count <= self.encodedByteLimit else { throw MarkdownResourceError.encodedLimit }
        guard let mime = normalizedMIME(payload.declaredMIMEType), let decoderType = MIMEToType[mime] else {
            throw MarkdownResourceError.typeMismatch
        }
        // This source is used only for metadata. Never create a full image here.
        let options = [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false] as CFDictionary
        let source = CGImageSourceCreateIncremental(options)
        CGImageSourceUpdateData(source, payload.data as CFData, true)
        guard let type = CGImageSourceGetType(source), type as String == decoderType,
              CGImageSourceGetStatus(source) == .statusComplete else { throw MarkdownResourceError.typeMismatch }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw MarkdownResourceError.typeMismatch }
        guard count <= 32 else { throw MarkdownResourceError.metadataLimit }
        var cumulative: UInt64 = 0
        var firstWidth = 0
        var firstHeight = 0
        for index in 0 ..< count {
            try Task.checkCancellation()
            guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw MarkdownResourceError.typeMismatch }
            let w = try dimension(width)
            let h = try dimension(height)
            let (pixels, overflow) = UInt64(w).multipliedReportingOverflow(by: UInt64(h))
            let (sum, sumOverflow) = cumulative.addingReportingOverflow(pixels)
            guard !overflow, !sumOverflow, sum <= 40_000_000 else { throw MarkdownResourceError.metadataLimit }
            cumulative = sum
            if index == 0 { firstWidth = w; firstHeight = h }
        }
        try Task.checkCancellation()
        return MarkdownEncodedImage(validatedData: payload.data, metadata: MarkdownImageMetadata(
            mimeType: mime, pixelWidth: firstWidth, pixelHeight: firstHeight, frameCount: count, cumulativePixels: cumulative
        ))
    }

    private static func dimension(_ value: NSNumber) throws -> Int {
        let number = value.doubleValue
        guard number.isFinite, number > 0, number <= 8192, number.rounded(.towardZero) == number else {
            throw MarkdownResourceError.metadataLimit
        }
        return Int(number)
    }
}
