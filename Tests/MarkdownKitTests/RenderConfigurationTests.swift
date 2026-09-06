import Foundation
import Testing

@testable import MarkdownRenderKit

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

@Suite @MainActor
struct RenderConfigurationTests {
  @Test func snapshotCopiesStyleValues() {
    var style = RenderStyle.default
    style.bodyFont = .systemFont(ofSize: 19)
    style.textColor = PlatformColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)
    style.paragraphSpacing = 17
    let wrapper = MarkdownRenderConfiguration(style: style)
    let snapshot = wrapper.snapshot(generation: 7)
    style.bodyFont = .systemFont(ofSize: 40)
    style.textColor = .black
    style.paragraphSpacing = 99
    #expect(snapshot.typography.pointSizes[.body] == 19)
    #expect(abs(snapshot.colors.body.red - 0.2) < 0.001)
    #expect(abs(snapshot.colors.body.alpha - 0.8) < 0.001)
    #expect(snapshot.spacing.paragraph == 17)
    #expect(snapshot.generation == 7)
    #expect(!snapshot.typography.usesPreferredMetrics)
    #expect(wrapper.snapshot(generation: 7) == snapshot)
  }

  @Test func customIdentityIsWrapperOwned() {
    let style = RenderStyle.default
    #expect(
      MarkdownRenderConfiguration(style: style).configurationID
        != MarkdownRenderConfiguration(style: style).configurationID)
    let shared = MarkdownConfigurationID.semantic(namespace: "test.style", version: 2)
    #expect(
      MarkdownRenderConfiguration(style: style, configurationID: shared).configurationID
        == MarkdownRenderConfiguration(style: style, configurationID: shared).configurationID)
    let math = IdentityMathRenderer()
    #expect(
      MathRendererConfiguration(renderer: math).configurationID
        != MathRendererConfiguration(renderer: math).configurationID)
    #expect(
      MathRendererConfiguration(renderer: math, configurationID: shared).configurationID == shared)
    let svg = IdentitySVGRenderer()
    #expect(
      SVGRendererConfiguration(renderer: svg).configurationID
        != SVGRendererConfiguration(renderer: svg).configurationID)
    #expect(
      SVGRendererConfiguration(renderer: svg, configurationID: shared).configurationID == shared)
  }

  @Test func builtInIdentityCoversNormalizedTokens() {
    let first = MarkdownRenderConfiguration.default.snapshot(generation: 1)
    let second = MarkdownRenderConfiguration.default.snapshot(generation: 9)
    #expect(first.id == second.id)
    #expect(first.typography.usesPreferredMetrics)
    var style = RenderStyle.default
    let baseline = style.snapshot(generation: 0)
    style.inlineCodeBgColor = .red
    #expect(style.snapshot(generation: 0).colors != baseline.colors)
    style.mathScale = 2
    #expect(style.snapshot(generation: 0).mathScale == 2)
    #expect(style.snapshot(generation: 0).id != baseline.id)
    #expect(baseline.typography.fontNames.count == 11)
  }

  @Test func semanticIdentityIncludesEveryLegacyStyleField() {
    let baseline = RenderStyle.default.snapshot(generation: 0, usesPreferredMetrics: true)
    let fontPaths: [WritableKeyPath<RenderStyle, PlatformFont>] = [
      \.bodyFont, \.codeFont, \.h1Font, \.h2Font, \.h3Font, \.h4Font, \.h5Font, \.h6Font,
    ]
    for path in fontPaths {
      var changed = RenderStyle.default
      changed[keyPath: path] = .systemFont(ofSize: 71)
      let snapshot = changed.snapshot(generation: 0, usesPreferredMetrics: true)
      #expect(snapshot.typography != baseline.typography)
      #expect(snapshot.id != baseline.id)
    }
    let colorPaths: [WritableKeyPath<RenderStyle, PlatformColor>] = [
      \.textColor, \.secondaryTextColor, \.codeTextColor, \.codeBackgroundColor,
      \.inlineCodeTextColor, \.inlineCodeBgColor, \.linkColor, \.quoteColor, \.quoteBarColor,
      \.headingBorderColor, \.mathTokenColor,
    ]
    for path in colorPaths {
      var changed = RenderStyle.default
      changed[keyPath: path] = PlatformColor(red: 0.123, green: 0.456, blue: 0.789, alpha: 0.321)
      let snapshot = changed.snapshot(generation: 0, usesPreferredMetrics: true)
      #expect(snapshot.colors != baseline.colors)
      #expect(snapshot.id != baseline.id)
    }
    for path in [\RenderStyle.paragraphSpacing, \.quoteIndent, \.mathScale] {
      var changed = RenderStyle.default
      changed[keyPath: path] = 71
      #expect(changed.snapshot(generation: 0, usesPreferredMetrics: true).id != baseline.id)
    }
    var changed = RenderStyle.default
    changed.mathColorOverride = .red
    #expect(changed.snapshot(generation: 0, usesPreferredMetrics: true).id != baseline.id)
  }

  @Test func builtInIdentityCannotAliasDifferentResolvedAppearances() {
    var wrapper: MarkdownRenderConfiguration!
    var light: RenderConfigurationSnapshot!
    var dark: RenderConfigurationSnapshot!
    #if canImport(UIKit)
      UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
        wrapper = .default
        light = wrapper.snapshot(generation: 0)
      }
      UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
        dark = wrapper.snapshot(generation: 1)
      }
    #else
      NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        wrapper = .default
        light = wrapper.snapshot(generation: 0)
      }
      NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        dark = wrapper.snapshot(generation: 1)
      }
    #endif
    #expect(light.colors == dark.colors || light.id != dark.id)
  }
}

private final class IdentityMathRenderer: MathRendering {
  func render(
    latex: String, display: Bool, pointSize: CGFloat, scale: CGFloat, color: PlatformColor
  ) async -> MathRenderOutcome { .failed }
}

private final class IdentitySVGRenderer: SVGBlockRendering {
  func render(svg: String, availableWidth: CGFloat, scale: CGFloat) async -> SVGBlockOutcome {
    .failed
  }
}
