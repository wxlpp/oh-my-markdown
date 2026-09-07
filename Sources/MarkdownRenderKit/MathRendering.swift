import Foundation

/// Custom wrappers are unique unless callers explicitly supply a semantic identity.
public struct MathRendererConfiguration: Sendable {
    package let renderer: any MathRendering
    /// Identity of all output-affecting producer settings.
    public let configurationID: MarkdownConfigurationID
    /// Wraps a producer. Keep a custom wrapper stable across view updates.
    /// Equal explicit semantic IDs promise equivalent output and permit completed
    /// cache sharing. Built-in producers derive their ID from normalized settings;
    /// other producers receive a fresh identity when this argument is omitted.
    public init(renderer: any MathRendering, configurationID: MarkdownConfigurationID? = nil) {
        self.renderer = renderer
        self.configurationID = configurationID ?? (renderer as? any BuiltInRenderedResourceProducer)?.builtInConfigurationID ?? .uniqueInstance()
    }
}

extension NSAttributedString.Key {
    public static let markdownMathSource = NSAttributedString.Key("MarkdownKit.mathSource")
}

/// Immutable raster result. Negative offsets place the glyph below the baseline.
public struct RenderedMath: Sendable {
    /// Encoded pixels and point geometry; no platform image crosses an actor boundary.
    public let image: RenderedImage
    /// Baseline displacement in ex units; one ex is half the requested point size.
    public let baselineOffsetEx: CGFloat
    /// Creates a transport result. The baseline offset must be finite.
    public init(image: RenderedImage, baselineOffsetEx: CGFloat) {
        self.image = image
        self.baselineOffsetEx = baselineOffsetEx
    }
}

/// Producers classify failures so only deterministic failures enter the negative cache.
public enum MathRenderOutcome: Sendable {
    case rendered(RenderedMath)
    /// Deterministic invalid input, eligible for the bounded 60-second negative cache.
    case failed
    /// Retryable renderer or codec failure; never negative-cached.
    case transientFailure
    /// Cooperatively cancelled work; never negative-cached.
    case cancelled
}

public struct MathCacheKey: Hashable, Sendable {
    public let latex: String
    public let display: Bool
    public let pointSize: CGFloat
    public let colorHex: String
    public let rasterScale: CGFloat
    public let configurationID: MarkdownConfigurationID
    public init(latex: String, display: Bool, pointSize: CGFloat, colorHex: String, rasterScale: CGFloat, configurationID: MarkdownConfigurationID) {
        self.latex = latex
        self.display = display
        self.pointSize = pointSize
        self.colorHex = colorHex
        self.rasterScale = rasterScale
        self.configurationID = configurationID
    }
}

/// An asynchronously invoked producer. Actors can confine mutable rendering engines.
/// Implementations should check cancellation around expensive synchronous work.
public protocol MathRendering: AnyObject, Sendable {
    /// Renders immutable output using the requested point size, pixel density and RGB hex color.
    func render(latex: String, display: Bool, pointSize: CGFloat, scale: CGFloat, colorHex: String) async -> MathRenderOutcome
}

public enum MathMetrics {
    public static func effectivePointSize(textPointSize: CGFloat, mathScale: CGFloat) -> CGFloat {
        textPointSize * mathScale
    }

    @MainActor public static func colorHex(_ color: PlatformColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        (color.usingColorSpace(.sRGB) ?? color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        func hex(_ value: CGFloat) -> String {
            String(format: "%02X", min(255, max(0, Int((value * 255).rounded()))))
        }
        return "#\(hex(r))\(hex(g))\(hex(b))"
    }
}
