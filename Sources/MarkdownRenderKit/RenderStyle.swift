import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - RenderStyle

/// Visual style applied when rendering Markdown to ``NSAttributedString``.
///
/// Construct a custom value or use ``RenderStyle/default`` to get a system-
/// adaptive style that follows Dynamic Type and the current color scheme.
public struct RenderStyle {
    // MARK: - Default

    /// Follows the reader's text-size setting: every default font is registered
    /// as scalable. A host opts a role out by assigning a font at a different
    /// size, or at the same size followed by `pinFont(for:)`.
    public static var `default`: RenderStyle {
        var style = Self.fixedDefault
        style.scaleFontWithContentSize(for: .body)
        style.scaleFontWithContentSize(for: .code)
        for level in 1 ... 6 {
            style.scaleFontWithContentSize(for: .heading(level: level))
        }
        return style
    }

    /// The same sizes with no scaling registered — the shape a host gets when it
    /// pins every font itself.
    public static var fixedDefault: RenderStyle {
        #if canImport(UIKit)
        RenderStyle(
            bodyFont: .systemFont(ofSize: 16, weight: .regular),
            codeFont: .monospacedSystemFont(ofSize: 14, weight: .regular),
            h1Font: .systemFont(ofSize: 32, weight: .semibold),
            h2Font: .systemFont(ofSize: 24, weight: .semibold),
            h3Font: .systemFont(ofSize: 20, weight: .semibold),
            h4Font: .systemFont(ofSize: 16, weight: .semibold),
            h5Font: .systemFont(ofSize: 14, weight: .semibold),
            h6Font: .systemFont(ofSize: 13, weight: .semibold),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            codeTextColor: .label,
            codeBackgroundColor: UIColor { t in
                t.userInterfaceStyle == .dark
                    ? UIColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1)
                    : UIColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1)
            },
            inlineCodeTextColor: UIColor { t in
                t.userInterfaceStyle == .dark
                    ? UIColor(red: 0.97, green: 0.46, blue: 0.59, alpha: 1)
                    : UIColor(red: 0.84, green: 0.20, blue: 0.45, alpha: 1)
            },
            inlineCodeBgColor: UIColor { t in
                t.userInterfaceStyle == .dark
                    ? UIColor(red: 0.12, green: 0.15, blue: 0.19, alpha: 1)
                    : UIColor(red: 0.94, green: 0.95, blue: 0.96, alpha: 1)
            },
            linkColor: .link,
            quoteColor: .secondaryLabel,
            quoteBarColor: UIColor { t in
                t.userInterfaceStyle == .dark
                    ? UIColor(red: 0.25, green: 0.50, blue: 0.90, alpha: 1)
                    : UIColor(red: 0.21, green: 0.45, blue: 0.85, alpha: 1)
            },
            headingBorderColor: UIColor { t in
                t.userInterfaceStyle == .dark
                    ? UIColor(white: 1, alpha: 0.12)
                    : UIColor(white: 0, alpha: 0.10)
            },
            paragraphSpacing: 12,
            quoteIndent: 16
        )
        #elseif canImport(AppKit)
        RenderStyle(
            bodyFont: .systemFont(ofSize: 15, weight: .regular),
            codeFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
            h1Font: .systemFont(ofSize: 30, weight: .semibold),
            h2Font: .systemFont(ofSize: 22, weight: .semibold),
            h3Font: .systemFont(ofSize: 18, weight: .semibold),
            h4Font: .systemFont(ofSize: 15, weight: .semibold),
            h5Font: .systemFont(ofSize: 13, weight: .semibold),
            h6Font: .systemFont(ofSize: 12, weight: .semibold),
            textColor: .labelColor,
            secondaryTextColor: .secondaryLabelColor,
            codeTextColor: .labelColor,
            codeBackgroundColor: NSColor(name: nil) { a in
                a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.15, alpha: 1)
                    : NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.97, alpha: 1)
            },
            inlineCodeTextColor: NSColor(name: nil) { a in
                a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(calibratedRed: 0.97, green: 0.46, blue: 0.59, alpha: 1)
                    : NSColor(calibratedRed: 0.84, green: 0.20, blue: 0.45, alpha: 1)
            },
            inlineCodeBgColor: NSColor(name: nil) { a in
                a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.19, alpha: 1)
                    : NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.96, alpha: 1)
            },
            linkColor: .linkColor,
            quoteColor: .secondaryLabelColor,
            quoteBarColor: NSColor(name: nil) { a in
                a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(calibratedRed: 0.25, green: 0.50, blue: 0.90, alpha: 1)
                    : NSColor(calibratedRed: 0.21, green: 0.45, blue: 0.85, alpha: 1)
            },
            headingBorderColor: NSColor(name: nil) { a in
                a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(white: 1, alpha: 0.12)
                    : NSColor(white: 0, alpha: 0.10)
            },
            paragraphSpacing: 12,
            quoteIndent: 16
        )
        #endif
    }

    // MARK: Fonts

    /// Point size each role was registered at, for the roles that follow the
    /// reader's text-size setting. `RenderStyle`'s own defaults populate it.
    ///
    /// A host opts out by assigning a font, and that is *detected* rather than
    /// flagged: the entry applies only while the stored font is still the size it
    /// was registered at. A `didSet` observer would be the obvious alternative,
    /// but a check that reads the actual value cannot go stale.
    public private(set) var scaledBaseSizes: [MarkdownTextRole: Double] = [:]

    public var bodyFont: PlatformFont
    public var codeFont: PlatformFont
    public var h1Font: PlatformFont
    public var h2Font: PlatformFont
    public var h3Font: PlatformFont
    public var h4Font: PlatformFont
    public var h5Font: PlatformFont
    public var h6Font: PlatformFont

    // MARK: Colors

    public var textColor: PlatformColor
    public var secondaryTextColor: PlatformColor
    public var codeTextColor: PlatformColor
    public var codeBackgroundColor: PlatformColor
    public var inlineCodeTextColor: PlatformColor
    public var inlineCodeBgColor: PlatformColor
    public var linkColor: PlatformColor
    public var quoteColor: PlatformColor
    public var quoteBarColor: PlatformColor
    public var headingBorderColor: PlatformColor

    // MARK: Spacing

    /// Space added after each top-level block (points).
    public var paragraphSpacing: CGFloat
    /// Additional head indent applied inside blockquotes (points).
    public var quoteIndent: CGFloat

    // MARK: Math

    /// Multiplier applied to the body point size to derive the math glyph size.
    /// (Task 9 will own full math styling; this minimal pair is added early so the
    /// renderer's math-key computation can compile — see Task 8 ordering note.)
    public var mathScale: CGFloat = 1.0
    /// Optional color override for rendered math; falls back to `textColor` when nil.
    public var mathColorOverride: PlatformColor?
    /// Highlight color for math delimiter tokens in the editor.
    public var mathTokenColor: PlatformColor = {
        #if canImport(UIKit)
        return UIColor.systemTeal
        #elseif canImport(AppKit)
        return NSColor.systemTeal
        #endif
    }()

    /// Whether two styles would produce the same render.
    ///
    /// Colors are compared by their **resolved** value, not by object identity: a
    /// dynamic `UIColor`/`NSColor` is built from a closure, and two closures are
    /// never equal, so `RenderStyle.default` did not compare equal to itself. Every
    /// caller of this is deciding "is this a replacement?", and answering yes on
    /// every SwiftUI body evaluation replaced the configuration, bumped the
    /// generation and restarted every image load. Resolution is against the
    /// current appearance, which is the right question here — an appearance change
    /// travels its own path and produces a different snapshot identity anyway.
    @MainActor
    public func isSemanticallyEqual(to other: RenderStyle) -> Bool {
        self.bodyFont.isEqual(other.bodyFont)
            && self.codeFont.isEqual(other.codeFont)
            && self.h1Font.isEqual(other.h1Font)
            && self.h2Font.isEqual(other.h2Font)
            && self.h3Font.isEqual(other.h3Font)
            && self.h4Font.isEqual(other.h4Font)
            && self.h5Font.isEqual(other.h5Font)
            && self.h6Font.isEqual(other.h6Font)
            && self.textColor.rgbaToken == other.textColor.rgbaToken
            && self.secondaryTextColor.rgbaToken == other.secondaryTextColor.rgbaToken
            && self.codeTextColor.rgbaToken == other.codeTextColor.rgbaToken
            && self.codeBackgroundColor.rgbaToken == other.codeBackgroundColor.rgbaToken
            && self.inlineCodeTextColor.rgbaToken == other.inlineCodeTextColor.rgbaToken
            && self.inlineCodeBgColor.rgbaToken == other.inlineCodeBgColor.rgbaToken
            && self.linkColor.rgbaToken == other.linkColor.rgbaToken
            && self.quoteColor.rgbaToken == other.quoteColor.rgbaToken
            && self.quoteBarColor.rgbaToken == other.quoteBarColor.rgbaToken
            && self.headingBorderColor.rgbaToken == other.headingBorderColor.rgbaToken
            && self.paragraphSpacing == other.paragraphSpacing
            && self.quoteIndent == other.quoteIndent
            && self.scaledBaseSizes == other.scaledBaseSizes
            && self.mathScale == other.mathScale
            && self.mathColorOverride?.rgbaToken == other.mathColorOverride?.rgbaToken
            && self.mathTokenColor.rgbaToken == other.mathTokenColor.rgbaToken
    }

    /// Returns a copy with `quoteIndent` increased, used for nested blockquotes.
    /// `textColor` is set to `quoteColor` so the sub-renderer renders body text with the
    /// dimmed quote color from the start — inline code, links, etc. keep their own colors.
    func indentedForQuote() -> RenderStyle {
        var s = self
        s.quoteIndent += 16
        s.textColor = s.quoteColor
        s.quoteBarColor = s.quoteBarColor.withAlphaComponent(0.5)
        return s
    }

    /// Returns the heading font for ATX level 1–6.
    func headingFont(level: Int) -> PlatformFont {
        switch level {
        case 1: self.h1Font
        case 2: self.h2Font
        case 3: self.h3Font
        case 4: self.h4Font
        case 5: self.h5Font
        default: self.h6Font
        }
    }

    /// Copies platform style objects into immutable values on the main actor.
    /// Direct custom snapshots use unique identities unless a wrapper owns one.
    /// Fixed custom fonts opt out of automatic scaling until Task 11's helper.
    @MainActor
    public func snapshot(generation: UInt64) -> RenderConfigurationSnapshot {
        self.snapshot(generation: generation, usesPreferredMetrics: false)
    }

    /// Resolves at the reader's text size. Roles the host pinned to an exact
    /// font are unaffected; the rest, and the chrome around them, follow.
    @MainActor
    public func snapshot(
        generation: UInt64, contentSizeCategory: MarkdownContentSizeCategory
    ) -> RenderConfigurationSnapshot {
        self.snapshot(
            generation: generation, usesPreferredMetrics: false, contentSizeCategory: contentSizeCategory
        )
    }

    /// Opts one role into following the reader's setting, keeping the face and
    /// weight already set for it.
    public mutating func scaleFontWithContentSize(for role: MarkdownTextRole) {
        self.scaledBaseSizes[role] = Double(self.font(for: role).pointSize)
    }

    /// Pins one role at the size it currently holds.
    ///
    /// Assigning a font is normally enough, because a role stops following the
    /// reader once its stored size differs from the size it was registered at.
    /// A font assigned at exactly the registered size is indistinguishable from
    /// the registered one, so pinning is how a host says it meant that size.
    public mutating func pinFont(for role: MarkdownTextRole) {
        self.scaledBaseSizes[role] = nil
    }

    /// Assigns a font that follows the reader's setting, keeping the face,
    /// weight and traits it was built with.
    public mutating func setFont(_ font: MarkdownScaledFont, for role: MarkdownTextRole) {
        self.setFont(font.base, for: role)
        self.scaleFontWithContentSize(for: role)
    }

    mutating func setFont(_ font: PlatformFont, for role: MarkdownTextRole) {
        switch role {
        case .code: self.codeFont = font
        case .heading(let level):
            switch min(max(level, 1), 6) {
            case 1: self.h1Font = font
            case 2: self.h2Font = font
            case 3: self.h3Font = font
            case 4: self.h4Font = font
            case 5: self.h5Font = font
            default: self.h6Font = font
            }
        default: self.bodyFont = font
        }
    }

    func font(for role: MarkdownTextRole) -> PlatformFont {
        switch role {
        case .code: self.codeFont
        case .heading(let level): self.headingFont(level: level)
        default: self.bodyFont
        }
    }

    @MainActor
    package func snapshot(
        generation: UInt64, configurationID: MarkdownConfigurationID? = nil, usesPreferredMetrics: Bool,
        contentSizeCategory: MarkdownContentSizeCategory = .large
    ) -> RenderConfigurationSnapshot {
        func font(_ role: MarkdownTextRole, _ fixed: PlatformFont) -> PlatformFont {
            // Still the size it was registered at means the host has not pinned
            // it since; anything else is a font the host chose deliberately.
            guard let base = self.scaledBaseSizes[role], Double(fixed.pointSize) == base else { return fixed }
            return MarkdownScaledFont(base: fixed, relativeTo: role)
                .resolve(contentSizeCategory: contentSizeCategory)
        }
        let body = font(.body, self.bodyFont)
        /// A heading follows its own text style's curve, and those damp where
        /// `.body` does not: on iOS at the maximum category the default h2 lands
        /// at 1.07x body rather than the 1.50x it was declared at, and h4 falls
        /// below body. Hierarchy is what a heading is for, so a scaled heading
        /// keeps at least the square root of its declared ratio — the full ratio
        /// at the default size, damped but never collapsed at the largest.
        func hierarchical(_ role: MarkdownTextRole, _ resolved: PlatformFont) -> PlatformFont {
            guard let declared = self.scaledBaseSizes[role], Double(self.font(for: role).pointSize) == declared,
                  let declaredBody = self.scaledBaseSizes[.body], Double(self.bodyFont.pointSize) == declaredBody,
                  declaredBody > 0
            else { return resolved }
            let ratio = declared / declaredBody
            let floor = Double(body.pointSize) * min(ratio, ratio.squareRoot())
            guard Double(resolved.pointSize) < floor else { return resolved }
            return resized(resolved, to: CGFloat(floor))
        }
        func heading(_ level: Int, _ fixed: PlatformFont) -> PlatformFont {
            hierarchical(.heading(level: level), font(.heading(level: level), fixed))
        }
        let fonts: [MarkdownTextRole: PlatformFont] = [
            .body: body, .code: font(.code, self.codeFont),
            .heading(level: 1): heading(1, self.h1Font),
            .heading(level: 2): heading(2, self.h2Font),
            .heading(level: 3): heading(3, self.h3Font),
            .heading(level: 4): heading(4, self.h4Font),
            .heading(level: 5): heading(5, self.h5Font),
            .heading(level: 6): heading(6, self.h6Font),
            .listMarker: body, .table: body, .caption: body,
        ]
        let descriptors = fonts.mapValues {
            // Platform font descriptors support secure coding. A failure is a
            // violated platform invariant, not permission to silently lose style.
            try! NSKeyedArchiver.archivedData(withRootObject: $0.fontDescriptor, requiringSecureCoding: true)
        }
        let typography = TypographyTokens(pointSizes: fonts.mapValues { Double($0.pointSize) }, usesPreferredMetrics: usesPreferredMetrics, fontNames: fonts.mapValues(\.fontName), fontDescriptors: descriptors)
        var additional: [String: ColorToken] = [
            "codeBackground": codeBackgroundColor.rgbaToken,
            "inlineCode": self.inlineCodeTextColor.rgbaToken,
            "inlineCodeBackground": self.inlineCodeBgColor.rgbaToken,
            "quote": self.quoteColor.rgbaToken,
            "quoteBar": self.quoteBarColor.rgbaToken,
            "headingBorder": self.headingBorderColor.rgbaToken,
            "mathToken": self.mathTokenColor.rgbaToken,
        ]
        additional["mathOverride"] = self.mathColorOverride?.rgbaToken
        let colors = ColorTokens(body: textColor.rgbaToken, secondary: self.secondaryTextColor.rgbaToken, code: self.codeTextColor.rgbaToken, link: self.linkColor.rgbaToken, additional: additional)
        // Chrome follows the same category as the text, at a gentler rate: a
        // maximum-category document scaled linearly is mostly margin.
        let chrome = contentSizeCategory.chromeScale
        let spacing = SpacingTokens(
            paragraph: Double(self.paragraphSpacing) * chrome, block: Double(self.paragraphSpacing) * chrome,
            codeInsets: 16 * chrome, quoteIndent: Double(self.quoteIndent) * chrome,
            listIndent: 24 * chrome, chromeScale: chrome
        )
        /// The built-in identity includes every normalized token. Length-prefixed
        /// strings avoid ambiguity; sorted roles/keys avoid dictionary order.
        func field(_ value: String) -> String {
            "\(value.utf8.count):\(value)"
        }
        func color(_ value: ColorToken) -> String {
            [value.red, value.green, value.blue, value.alpha].map { String($0 == 0 ? 0 : $0) }.joined(separator: ",")
        }
        var identity = "preferred:\(usesPreferredMetrics)" + field(contentSizeCategory.rawValue)
        // Two categories can round a role to the same point size, so the
        // category itself is a field rather than an implication of the sizes.
        for role in fonts.keys.sorted(by: { $0.identity < $1.identity }) {
            identity += field(role.identity) + field(typography.fontNames[role]!) + field(String(typography.pointSizes[role]!))
            // Custom descriptor bytes remain preserved above; built-in system
            // descriptors are fully determined by the normalized font name/size.
        }
        for value in [colors.body, colors.secondary, colors.code, colors.link] {
            identity += field(color(value))
        }
        for key in additional.keys.sorted() {
            identity += field(key) + field(color(additional[key]!))
        }
        for value in [spacing.paragraph, spacing.block, spacing.codeInsets, spacing.quoteIndent, spacing.listIndent, spacing.chromeScale, Double(self.mathScale)] {
            identity += field(String(value == 0 ? 0 : value))
        }
        let id = configurationID ?? (usesPreferredMetrics ? .semantic(namespace: "MarkdownKit.default:" + identity, version: 1) : .uniqueInstance())
        return RenderConfigurationSnapshot(id: id, typography: typography, colors: colors, spacing: spacing, generation: generation, mathScale: Double(self.mathScale))
    }
}

@MainActor
extension PlatformColor {
    var rgbaToken: ColorToken {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #if canImport(UIKit)
        let resolved = resolvedColor(with: UITraitCollection.current)
        if !resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 0
            if resolved.getWhite(&white, alpha: &alpha) { red = white; green = white; blue = white }
        }
        #elseif canImport(AppKit)
        if let rgb = usingColorSpace(.sRGB) { rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha) }
        #endif
        return ColorToken(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
    }
}
