import CoreGraphics
import Foundation
import MarkdownCore

/// Extracts the first double-quoted viewBox from the outermost SVG tag found
/// within 4096 UTF-8 bytes. The byte limit deliberately replaces the historical
/// 4096-Character limit, which was unbounded for combining graphemes.
public enum SVGViewBoxParser {
    public static func parseSize(from svg: String) -> CGSize? {
        var metrics = ParseWorkMetrics()
        return try! self.parseSize(from: svg, metrics: &metrics, cancellable: false)
    }

    package static func parseSize(from svg: String, metrics: inout ParseWorkMetrics) throws -> CGSize? {
        try self.parseSize(from: svg, metrics: &metrics, cancellable: true)
    }

    private static func parseSize(from svg: String, metrics: inout ParseWorkMetrics, cancellable: Bool) throws -> CGSize? {
        var work = 0
        defer { metrics.renderPreparationBytes = ParseWorkMetrics.saturatingAdd(metrics.renderPreparationBytes, work) }
        func check() throws {
            if cancellable { try Task.checkCancellation() }
        }
        try check()
        let svgName: [UInt32] = [60, 115, 118, 103]
        let attribute: [UInt32] = [118, 105, 101, 119, 66, 111, 120]
        var svgMatch = 0
        var inTag = false
        var attributeMatch = 0
        var phase = 0 // search, equals, opening quote, value, found
        var value: [UInt8] = []
        var dimension: CGSize?
        var scalar: UInt32 = 0
        var continuation = 0
        var scanned = 0
        for byte in svg.utf8.prefix(4096) {
            work += 1
            scanned += 1
            if scanned & 1023 == 0 { try check() }
            if continuation > 0 {
                scalar = (scalar << 6) | UInt32(byte & 0x3F)
                continuation -= 1
                if continuation > 0 { continue }
            } else if byte >= 0xC0 {
                continuation = byte < 0xE0 ? 1 : byte < 0xF0 ? 2 : 3
                scalar = UInt32(byte & (continuation == 1 ? 0x1F : continuation == 2 ? 0x0F : 0x07))
                continue
            } else { scalar = UInt32(byte) }
            let whitespace = Unicode.Scalar(scalar)?.properties.isWhitespace == true
            if !inTag {
                if svgMatch == svgName.count {
                    if whitespace || scalar == 62 { inTag = true; continue }
                    svgMatch = 0
                }
                svgMatch = scalar == svgName[svgMatch] ? svgMatch + 1 : scalar == 60 ? 1 : 0
                continue
            }
            if scalar == 62 { return phase == 4 ? dimension : nil }
            if phase == 4 { continue }
            if phase == 3 {
                if scalar == 34 {
                    if value.isEmpty { phase = 0; continue }
                    work += value.count // decode ASCII numeric attribute
                    let text = String(decoding: value, as: UTF8.self)
                    work += value.count // split separators
                    let tokens = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" })
                    metrics.recordPreparationMetadata(tokens.count * MemoryLayout<Substring>.stride)
                    if tokens.count == 4 {
                        var numbers: [Double] = []
                        for token in tokens {
                            try check()
                            work += token.utf8.count // bounded numeric conversion input
                            if let number = Double(token) { numbers.append(number) }
                        }
                        metrics.recordPreparationMetadata(numbers.count * MemoryLayout<Double>.stride)
                        if numbers.count == 4, numbers[2] > 0, numbers[3] > 0 {
                            dimension = CGSize(width: numbers[2], height: numbers[3])
                        }
                    }
                    phase = 4
                } else {
                    // Non-ASCII numeric content cannot be parsed by Double.
                    guard scalar < 128 else { return nil }
                    if value.count == value.capacity { work += value.count } // relocated byte payload
                    value.append(UInt8(scalar))
                    work += 1 // copied numeric payload
                }
                continue
            }
            if phase == 1 {
                if whitespace { continue }
                if scalar == 61 { phase = 2; continue }
                phase = 0
            } else if phase == 2 {
                if whitespace { continue }
                if scalar == 34 { phase = 3; value = []; continue }
                phase = 0
            }
            attributeMatch = scalar == attribute[attributeMatch] ? attributeMatch + 1 : scalar == 118 ? 1 : 0
            if attributeMatch == attribute.count { phase = 1; attributeMatch = 0 }
        }
        return nil
    }

    public static func parseAspect(from svg: String) -> CGFloat? {
        self.parseSize(from: svg).map { $0.height / $0.width }
    }
}
