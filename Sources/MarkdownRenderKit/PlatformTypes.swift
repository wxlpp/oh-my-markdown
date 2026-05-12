#if canImport(UIKit)
import UIKit

public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage

extension UIFont {
    /// Returns a copy of the receiver with italic trait applied.
    func italic() -> UIFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.traitItalic) ?? fontDescriptor
        return UIFont(descriptor: descriptor, size: 0)
    }

    /// Returns a copy of the receiver with bold trait applied.
    func bold() -> UIFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) ?? fontDescriptor
        return UIFont(descriptor: descriptor, size: 0)
    }
}

#elseif canImport(AppKit)
import AppKit

public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage

extension NSFont {
    func italic() -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }

    func bold() -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
    }
}
#endif
