import SwiftUI
import UIKit

public struct TextKitLabelView: UIViewRepresentable {
    // Public configurable properties
    public var text: String?
    public var attributedText: NSAttributedString?
    public var font: UIFont
    public var textColor: UIColor
    public var textAlignment: NSTextAlignment
    public var numberOfLines: Int
    public var lineBreakMode: NSLineBreakMode
    public var preferredMaxLayoutWidth: CGFloat

    public init(
        text: String? = nil,
        attributedText: NSAttributedString? = nil,
        font: UIFont = .systemFont(ofSize: 17),
        textColor: UIColor = .label,
        textAlignment: NSTextAlignment = .natural,
        numberOfLines: Int = 0,
        lineBreakMode: NSLineBreakMode = .byWordWrapping,
        preferredMaxLayoutWidth: CGFloat = 0
    ) {
        self.text = text
        self.attributedText = attributedText
        self.font = font
        self.textColor = textColor
        self.textAlignment = textAlignment
        self.numberOfLines = numberOfLines
        self.lineBreakMode = lineBreakMode
        self.preferredMaxLayoutWidth = preferredMaxLayoutWidth
    }

    public func makeUIView(context: Context) -> TextKitLabel {
        let label = TextKitLabel()
        configure(label)
        // Prefer the label's intrinsic content size so SwiftUI doesn't stretch it.
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    public func updateUIView(_ uiView: TextKitLabel, context: Context) {
        configure(uiView)
        uiView.setContentHuggingPriority(.required, for: .horizontal)
        uiView.setContentHuggingPriority(.required, for: .vertical)
        uiView.setContentCompressionResistancePriority(.required, for: .horizontal)
        uiView.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    
    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: TextKitLabel, context: Context) -> CGSize? {
        // Map proposed size to a concrete size for UIView sizing API.
        // Use the provided proposed width/height when available; otherwise use
        // the label's `preferredMaxLayoutWidth` for width if set, or a very large
        // value to allow the label to compute its natural size.
        let proposedSize = proposal.replacingUnspecifiedDimensions(by: .zero)
        let proposedWidth: CGFloat
        if proposedSize.width > 0 {
            proposedWidth = proposedSize.width
            
        } else if preferredMaxLayoutWidth > 0 {
            proposedWidth = preferredMaxLayoutWidth
        } else {
            proposedWidth = CGFloat.greatestFiniteMagnitude
        }
        let proposedHeight: CGFloat
        if proposedSize.height > 0 {
            proposedHeight = proposedSize.height
        } else {
            proposedHeight = CGFloat.greatestFiniteMagnitude
        }

        let fittingSize = CGSize(width: proposedWidth, height: proposedHeight)

        // Ask the underlying view for the size that fits this constraint.
        let measured = uiView.sizeThatFits(fittingSize)

        // If the proposal constrained one axis, respect that axis; otherwise return measured.
        let resultWidth = proposedSize.width.isSubnormal ? proposedSize.width : measured.width
        let resultHeight = proposedSize.height.isSubnormal ? proposedSize.height : measured.height

        return CGSize(width: resultWidth, height: resultHeight)
    }

    private func configure(_ label: TextKitLabel) {
        label.text = text
        label.attributedText = attributedText
        label.font = font
        label.textColor = textColor
        label.textAlignment = textAlignment
        label.numberOfLines = numberOfLines
        label.lineBreakMode = lineBreakMode
        label.preferredMaxLayoutWidth = preferredMaxLayoutWidth
        label.setNeedsLayout()
    }
}

public extension TextKitLabelView {
    init(_ attributed: AttributedString,
         font: UIFont = .systemFont(ofSize: 17),
         textColor: UIColor = .label,
         numberOfLines: Int = 0,
         preferredMaxLayoutWidth: CGFloat = 0) {
        self.init(
            text: nil,
            attributedText: NSAttributedString(attributed),
            font: font,
            textColor: textColor,
            textAlignment: .natural,
            numberOfLines: numberOfLines,
            lineBreakMode: .byTruncatingTail,
            preferredMaxLayoutWidth: preferredMaxLayoutWidth
        )
    }
}


#Preview(traits: .defaultLayout) {
    ScrollView {
        TextKitLabelView("Hello, world!2").background {
            Color.red
        }
    }.background {
        Color.blue
    }
}
