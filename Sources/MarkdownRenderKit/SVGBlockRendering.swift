import Foundation

/// Wrapper-owned output identity and an asynchronous SVG producer.
public struct SVGRendererConfiguration: Sendable {
    package let renderer: any SVGBlockRendering
    public let configurationID: MarkdownConfigurationID
    /// Custom wrappers are unique unless an explicit semantic ID promises equivalent
    /// output. Built-in producers automatically use their normalized configuration ID.
    /// Keep custom wrappers stable across view updates to preserve completed cache hits.
    public init(renderer: any SVGBlockRendering, configurationID: MarkdownConfigurationID? = nil) {
        self.renderer = renderer
        self.configurationID = configurationID ?? (renderer as? any BuiltInRenderedResourceProducer)?.builtInConfigurationID ?? .uniqueInstance()
    }
}

extension NSAttributedString.Key {
    public static let markdownSVGBlockSource = NSAttributedString.Key("OhMyMarkdown.svgBlockSource")
}

/// Immutable encoded SVG rasterization output, materialized only on MainActor.
public struct RenderedSVG: Sendable {
    public let image: RenderedImage
    public init(image: RenderedImage) {
        self.image = image
    }
}

/// Deterministic failures alone are eligible for the bounded negative cache.
public enum SVGBlockOutcome: Sendable {
    case rendered(RenderedSVG)
    /// Invalid source or unsupported deterministic geometry.
    case failed
    /// Retryable renderer or codec failure.
    case transientFailure
    /// Cooperatively cancelled work.
    case cancelled
}

public struct SVGBlockCacheKey: Hashable, Sendable {
    public let svg: String
    public let availableWidth: CGFloat
    public let rasterScale: CGFloat
    public let configurationID: MarkdownConfigurationID
    public init(svg: String, availableWidth: CGFloat, rasterScale: CGFloat, configurationID: MarkdownConfigurationID) {
        self.svg = svg
        self.availableWidth = availableWidth
        self.rasterScale = rasterScale
        self.configurationID = configurationID
    }
}

/// An asynchronous SVG producer returning only immutable Sendable results.
public protocol SVGBlockRendering: AnyObject, Sendable {
    /// Renders the source at the given layout width and raster pixel density.
    func render(svg: String, availableWidth: CGFloat, scale: CGFloat) async -> SVGBlockOutcome
}
