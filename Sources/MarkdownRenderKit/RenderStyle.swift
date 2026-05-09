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
public struct RenderStyle: @unchecked Sendable {
    // MARK: - Default

    public static var `default`: RenderStyle {
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

    public func isSemanticallyEqual(to other: RenderStyle) -> Bool {
        self.bodyFont.isEqual(other.bodyFont)
            && self.codeFont.isEqual(other.codeFont)
            && self.h1Font.isEqual(other.h1Font)
            && self.h2Font.isEqual(other.h2Font)
            && self.h3Font.isEqual(other.h3Font)
            && self.h4Font.isEqual(other.h4Font)
            && self.h5Font.isEqual(other.h5Font)
            && self.h6Font.isEqual(other.h6Font)
            && self.textColor.isEqual(other.textColor)
            && self.secondaryTextColor.isEqual(other.secondaryTextColor)
            && self.codeTextColor.isEqual(other.codeTextColor)
            && self.codeBackgroundColor.isEqual(other.codeBackgroundColor)
            && self.inlineCodeTextColor.isEqual(other.inlineCodeTextColor)
            && self.inlineCodeBgColor.isEqual(other.inlineCodeBgColor)
            && self.linkColor.isEqual(other.linkColor)
            && self.quoteColor.isEqual(other.quoteColor)
            && self.quoteBarColor.isEqual(other.quoteBarColor)
            && self.headingBorderColor.isEqual(other.headingBorderColor)
            && self.paragraphSpacing == other.paragraphSpacing
            && self.quoteIndent == other.quoteIndent
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
}
