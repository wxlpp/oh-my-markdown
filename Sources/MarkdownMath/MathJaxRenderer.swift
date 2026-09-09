import Foundation
import MarkdownRenderKit
import MathJaxSwift

/// Actor confinement serializes every synchronous MathJaxSwift JSContext call.
public actor MathJaxRenderer: MathRendering, BuiltInRenderedResourceProducer {
    package nonisolated let builtInConfigurationID: MarkdownConfigurationID = .semantic(
        namespace: "MathJaxSwift3.5.svg.core-base-ams-noundefined.digits-v1.local-font.ex0.5.raster4096", version: 1
    )
    private var mathjax: MathJax?
    public init() {}

    private var texInputOptions: TeXInputProcessorOptions {
        TeXInputProcessorOptions(
            loadPackages: [
                TeXInputProcessorOptions.Packages.base,
                TeXInputProcessorOptions.Packages.ams,
                TeXInputProcessorOptions.Packages.noundefined,
            ],
            digits: #"^(?:[0-9]+(?:\{,\}[0-9]{3})*(?:\.[0-9]*)?|\.[0-9]+)"#
        )
    }

    private func convert(_ latex: String, display: Bool) throws -> String {
        if self.mathjax == nil { self.mathjax = try MathJax(preferredOutputFormat: .svg) }
        return try self.mathjax!.tex2svg(
            latex,
            conversionOptions: ConversionOptions(display: display),
            inputOptions: self.texInputOptions,
            outputOptions: SVGOutputProcessorOptions()
        )
    }

    public func render(latex: String, display: Bool, pointSize: CGFloat, scale: CGFloat, colorHex: String) async -> MathRenderOutcome {
        guard !Task.isCancelled else { return .cancelled }
        let svg: String
        do { svg = try self.convert(latex, display: display) }
        catch { return Task.isCancelled ? .cancelled : .transientFailure }
        guard !Task.isCancelled else { return .cancelled }
        do {
            let result = try SVGRasterizer.rasterize(svg: svg, hex: colorHex, pointSize: pointSize, scale: scale)
            return Task.isCancelled ? .cancelled : .rendered(result)
        } catch SVGRasterizerError.parseFailed {
            return Task.isCancelled ? .cancelled : .failed
        } catch SVGRasterizerError.invalidDimensions {
            return Task.isCancelled ? .cancelled : .failed
        } catch RenderedMath.Failure.invalidGeometry {
            return Task.isCancelled ? .cancelled : .failed
        } catch { return Task.isCancelled ? .cancelled : .transientFailure }
    }
}
