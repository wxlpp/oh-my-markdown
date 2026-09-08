import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The reader's text-size setting, as a value the render configuration can carry.
///
/// Modelled here rather than taken from `UIContentSizeCategory` directly so the
/// preparer — which is not main-actor and not UIKit-only — can scale from it, and
/// so macOS, which has no equivalent system setting, still has something to
/// resolve against.
public enum MarkdownContentSizeCategory: String, Sendable, Equatable, CaseIterable {
    case extraSmall, small, medium, large, extraLarge, extraExtraLarge, extraExtraExtraLarge
    case accessibilityMedium, accessibilityLarge, accessibilityExtraLarge
    case accessibilityExtraExtraLarge, accessibilityExtraExtraExtraLarge

    /// What the platform's own text styles scale by at this category, so a
    /// document tracks the rest of the system rather than a curve of our own.
    /// The accessibility categories are deliberately a large step: a reader who
    /// turns them on is asking for a materially different size, not a nudge.
    public var scale: Double {
        switch self {
        case .extraSmall: 0.82
        case .small: 0.88
        case .medium: 0.94
        case .large: 1.0
        case .extraLarge: 1.12
        case .extraExtraLarge: 1.23
        case .extraExtraExtraLarge: 1.35
        case .accessibilityMedium: 1.64
        case .accessibilityLarge: 1.95
        case .accessibilityExtraLarge: 2.35
        case .accessibilityExtraExtraLarge: 2.76
        case .accessibilityExtraExtraExtraLarge: 3.12
        }
    }

    /// Chrome — spacing, insets, indents — grows more slowly than text: scaling
    /// it at the same rate leaves a maximum-category document mostly margin.
    public var chromeScale: Double {
        1 + (self.scale - 1) * 0.5
    }

    public var isAccessibilityCategory: Bool {
        self.scale >= MarkdownContentSizeCategory.accessibilityMedium.scale
    }
}

#if canImport(UIKit)
extension MarkdownContentSizeCategory {
    /// The platform category this one stands for, so scaling can be handed to
    /// `UIFontMetrics` rather than reimplemented.
    public var platformCategory: UIContentSizeCategory {
        switch self {
        case .extraSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .extraLarge: .extraLarge
        case .extraExtraLarge: .extraExtraLarge
        case .extraExtraExtraLarge: .extraExtraExtraLarge
        case .accessibilityMedium: .accessibilityMedium
        case .accessibilityLarge: .accessibilityLarge
        case .accessibilityExtraLarge: .accessibilityExtraLarge
        case .accessibilityExtraExtraLarge: .accessibilityExtraExtraLarge
        case .accessibilityExtraExtraExtraLarge: .accessibilityExtraExtraExtraLarge
        }
    }

    /// Maps the platform's category, which is what the view observes.
    public init(_ category: UIContentSizeCategory) {
        self = switch category {
        case .extraSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .extraLarge: .extraLarge
        case .extraExtraLarge: .extraExtraLarge
        case .extraExtraExtraLarge: .extraExtraExtraLarge
        case .accessibilityMedium: .accessibilityMedium
        case .accessibilityLarge: .accessibilityLarge
        case .accessibilityExtraLarge: .accessibilityExtraLarge
        case .accessibilityExtraExtraLarge: .accessibilityExtraExtraLarge
        case .accessibilityExtraExtraExtraLarge: .accessibilityExtraExtraExtraLarge
        default: .large
        }
    }
}
#endif

/// The same font at a different size. AppKit's initialiser is failable and its
/// only documented failure is a descriptor it cannot realize, which a font we
/// were just handed is not.
func resized(_ font: PlatformFont, to size: CGFloat) -> PlatformFont {
    #if canImport(UIKit)
    UIFont(descriptor: font.fontDescriptor, size: size)
    #else
    NSFont(descriptor: font.fontDescriptor, size: size) ?? font
    #endif
}

/// A custom font that follows the reader's text-size setting.
///
/// A font set directly on `RenderStyle` is a fixed size by design — a host that
/// wrote 19 pt meant 19 pt. Wrapping it here is how a host asks for the other
/// behaviour, and the wrapper keeps the face, weight and traits it was given.
/// Stores a platform font, like `RenderStyle` itself, so it carries the same
/// isolation as the style it lives in rather than a stricter one.
public struct MarkdownScaledFont {
    private let base: PlatformFont
    private let role: MarkdownTextRole

    public init(base: PlatformFont, relativeTo role: MarkdownTextRole) {
        self.base = base
        self.role = role
    }

    public func resolve(contentSizeCategory: MarkdownContentSizeCategory) -> PlatformFont {
        #if canImport(UIKit)
        // The curve is per text style, not one ramp for the whole document: body
        // goes 17→53 pt across the range while largeTitle only goes 34→60. Using
        // `scale` for every role turns an h1 into a two-word-per-line banner.
        let size = UIFontMetrics(forTextStyle: self.role.preferredTextStyle).scaledValue(
            for: self.base.pointSize,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSizeCategory.platformCategory)
        )
        return UIFont(descriptor: self.base.fontDescriptor, size: size)
        #else
        // AppKit has no metrics table to borrow, and macOS has no system text-size
        // setting driving this, so the flat body ramp is what a host opting in gets.
        let size = self.base.pointSize * contentSizeCategory.scale
        return NSFont(descriptor: self.base.fontDescriptor, size: size) ?? self.base
        #endif
    }
}

#if canImport(UIKit)
extension MarkdownTextRole {
    /// The system text style whose scaling curve this role follows. Headings map
    /// onto the title styles by level so their damping matches the platform's.
    var preferredTextStyle: UIFont.TextStyle {
        switch self {
        case .heading(let level):
            switch level {
            case ...1: .largeTitle
            case 2: .title1
            case 3: .title2
            case 4: .title3
            case 5: .headline
            default: .subheadline
            }
        case .caption: .caption1
        default: .body
        }
    }
}
#endif
