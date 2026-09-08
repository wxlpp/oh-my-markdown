#if canImport(UIKit)
import MarkdownRenderKit
import UIKit

/// UIKit wrapper around one semantic leaf. `UIAccessibilityElement` wants a
/// container and a frame in screen space; everything else comes from the leaf.
final class MarkdownAccessibilityUIElement: UIAccessibilityElement {
    var element: MarkdownAccessibilityElement

    init(element: MarkdownAccessibilityElement, container: UIView) {
        self.element = element
        super.init(accessibilityContainer: container)
    }

    override var accessibilityLabel: String? {
        get { self.element.label }
        set {}
    }

    override var accessibilityFrameInContainerSpace: CGRect {
        get { self.element.frame }
        set {}
    }

    override var accessibilityValue: String? {
        get { self.element.spokenValue }
        set {}
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get {
            switch self.element.role {
            case .heading: [.header, .staticText]
            case .link: [.link]
            case .image: [.image]
            default: [.staticText]
            }
        }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        self.element.activate()
    }
}

extension MarkdownLabelView {
    /// The label is a container, never a leaf: exposing it as an element too
    /// would read the whole document before its parts.
    func publishAccessibilityElements() {
        self.isAccessibilityElement = false
        // The wrapper is the object the accessibility client holds, so replacing
        // it is the focus change the identity reuse exists to avoid — reusing
        // only the inner element would leave that unmet.
        self.accessibilityElements = self.orderedAccessibilityElements.map { element in
            let wrapper = self.accessibilityWrapperStore[element.id]
                ?? MarkdownAccessibilityUIElement(element: element, container: self)
            wrapper.element = element
            self.accessibilityWrapperStore[element.id] = wrapper
            return wrapper
        }
        self.accessibilityWrapperStore = self.accessibilityWrapperStore.filter { id, _ in
            self.accessibilityElementStore[id] != nil
        }
    }
}
#endif
