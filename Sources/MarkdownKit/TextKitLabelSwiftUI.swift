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
    
    // MARK: - Equatable Support
    
    fileprivate struct Configuration: Equatable {
        let text: String?
        let attributedText: NSAttributedString?
        let font: UIFont
        let textColor: UIColor
        let textAlignment: NSTextAlignment
        let numberOfLines: Int
        let lineBreakMode: NSLineBreakMode
        let preferredMaxLayoutWidth: CGFloat
        
        static func == (lhs: Configuration, rhs: Configuration) -> Bool {
            lhs.text == rhs.text &&
            lhs.attributedText == rhs.attributedText &&
            lhs.font == rhs.font &&
            lhs.textColor == rhs.textColor &&
            lhs.textAlignment == rhs.textAlignment &&
            lhs.numberOfLines == rhs.numberOfLines &&
            lhs.lineBreakMode == rhs.lineBreakMode &&
            lhs.preferredMaxLayoutWidth == rhs.preferredMaxLayoutWidth
        }
    }
    
    private var configuration: Configuration {
        Configuration(
            text: text,
            attributedText: attributedText,
            font: font,
            textColor: textColor,
            textAlignment: textAlignment,
            numberOfLines: numberOfLines,
            lineBreakMode: lineBreakMode,
            preferredMaxLayoutWidth: preferredMaxLayoutWidth
        )
    }

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
        configureLayoutPriorities(label)
        configure(label)
        return label
    }

    public func updateUIView(_ uiView: TextKitLabel, context: Context) {
        // Only update if configuration changed
        guard context.coordinator.lastConfiguration != configuration else { return }
        context.coordinator.lastConfiguration = configuration
        configure(uiView)
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    // MARK: - Coordinator
    
    public final class Coordinator {
        fileprivate var lastConfiguration: Configuration?
    }
    
    private func configureLayoutPriorities(_ label: TextKitLabel) {
        // Prefer the label's intrinsic content size so SwiftUI doesn't stretch it.
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    
    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: TextKitLabel,
        context: Context
    ) -> CGSize? {
        // Determine fitting width based on proposal or preferredMaxLayoutWidth
        let fittingWidth: CGFloat
        if let proposedWidth = proposal.width, proposedWidth > 0 {
            fittingWidth = proposedWidth
        } else if preferredMaxLayoutWidth > 0 {
            fittingWidth = preferredMaxLayoutWidth
        } else {
            fittingWidth = .greatestFiniteMagnitude
        }
        
        let fittingHeight = proposal.height ?? .greatestFiniteMagnitude
        let fittingSize = CGSize(width: fittingWidth, height: fittingHeight)

        // Ask the underlying view for the size that fits this constraint
        return uiView.sizeThatFits(fittingSize)
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
        let sampleText = """
        Here is a long text example demonstrating TextKit-based label.
        支持多行显示，自动换行与截断。
        This line is intentionally long to demonstrate wrapping and sizing behavior.
        """
        TextKitLabelView(text: sampleText)
            .background {
            Color.red
        }
    }
    .frame(maxWidth: .infinity)
    .background {
        Color.blue
    }
}
