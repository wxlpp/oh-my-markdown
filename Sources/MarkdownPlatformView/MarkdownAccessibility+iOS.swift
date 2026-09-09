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
    ///
    /// The container is declared through the old `UIAccessibilityContainer`
    /// methods as well as `accessibilityElements`. This view conforms to
    /// `UITextInput`, and UIKit's text-input accessibility support answers the
    /// client with a single text element for such a view; the explicit methods
    /// are what the client asks first.
    override public func accessibilityElementCount() -> Int {
        self.orderedAccessibilityElements.count
    }

    override public func accessibilityElement(at index: Int) -> Any? {
        let elements = self.accessibilityElements ?? []
        return elements.indices.contains(index) ? elements[index] : nil
    }

    override public func index(ofAccessibilityElement element: Any) -> Int {
        let elements = self.accessibilityElements ?? []
        guard let object = element as AnyObject? else { return NSNotFound }
        return elements.firstIndex { ($0 as AnyObject) === object } ?? NSNotFound
    }

    /// A container, never a leaf — and this has to be an override rather than an
    /// assignment. The view conforms to `UITextInput`, and UIKit answers `true`
    /// here for a text-input view whatever the stored property was set to: in the
    /// Example the view published 134 elements and still reported itself as one
    /// text element, so the client never asked for a single one of them and a
    /// reader heard the whole document in one breath.
    override public var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    func publishAccessibilityElements() {
        self.accessibilityContainerType = .semanticGroup
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
