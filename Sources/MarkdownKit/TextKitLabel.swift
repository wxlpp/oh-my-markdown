import UIKit

/// A lightweight UILabel-like view backed by TextKit 2 layout.
/// Uses NSTextContentStorage/NSTextLayoutManager/NSTextContainer.
/// Provides common UILabel APIs: `text`, `attributedText`, `font`, `textColor`, `textAlignment`,
/// `numberOfLines`, `lineBreakMode`, `intrinsicContentSize` and `sizeThatFits(_:)`.
public final class TextKitLabel: UIView {
    // MARK: - Public API

    public var text: String? {
        didSet { updateTextStorage() }
    }

    public var attributedText: NSAttributedString? {
        didSet { updateTextStorage() }
    }

    public var font: UIFont = .systemFont(ofSize: 17) {
        didSet { updateTextStorage() }
    }

    public var textColor: UIColor = .label {
        didSet { updateTextStorage() }
    }

    public var textAlignment: NSTextAlignment = .natural {
        didSet { updateTextStorage() }
    }

    public var numberOfLines: Int = 0 {
        didSet { setNeedsLayout(); invalidateIntrinsicContentSize() }
    }

    public var lineBreakMode: NSLineBreakMode = .byWordWrapping {
        didSet { updateTextStorage() }
    }

    /// Like `UILabel`'s `preferredMaxLayoutWidth`.
    public var preferredMaxLayoutWidth: CGFloat = 0 {
        didSet { invalidateIntrinsicContentSize() }
    }

    // MARK: - Private TextKit 2 objects

    private let textContentStorage = NSTextContentStorage()
    private let textLayoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(size: .zero)
    
    // Update batching to avoid redundant invalidations
    private var isUpdatePending = false

    // Internal cached attributed string used to apply default attributes
    private var effectiveAttributedString: NSAttributedString? {
        if let attributed = attributedText { return attributed }
        guard let string = text else { return nil }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment
        paragraph.lineBreakMode = lineBreakMode
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]
        return NSAttributedString(string: string, attributes: attrs)
    }

    // MARK: - Init

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isOpaque = false
        backgroundColor = .clear

        // Setup TextKit 2 hierarchy
        textContentStorage.addTextLayoutManager(textLayoutManager)
        textLayoutManager.textContainer = textContainer

        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        // For multi-line labels we prefer word-wrapping for layout so only the
        // final visible line is subject to truncation semantics. Keep single
        // line behaviour matching `lineBreakMode`.
        textContainer.lineBreakMode = (numberOfLines == 1 ? lineBreakMode : .byWordWrapping)

        updateTextStorage()
    }

    // MARK: - Layout & drawing

    public override func layoutSubviews() {
        super.layoutSubviews()
        // update text container size to match view bounds
        textContainer.size = bounds.size
        // keep line limit in sync
        textContainer.maximumNumberOfLines = numberOfLines
        setNeedsDisplay()
    }

    public override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              effectiveAttributedString != nil else { return }

        // In TextKit 2, we enumerate text segments and draw them
        textLayoutManager.enumerateTextLayoutFragments(
            from: textLayoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { layoutFragment in
            layoutFragment.draw(at: layoutFragment.layoutFragmentFrame.origin, in: context)
            return true
        }
    }

    // MARK: - Text storage updates

    private func updateTextStorage() {
        guard !isUpdatePending else { return }
        isUpdatePending = true
        
        // Defer updates to next run loop to batch multiple property changes
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isUpdatePending = false
            
            // When updating, use word-wrapping for multi-line layout to avoid
            // truncating every line. Keep single-line behavior as requested.
            self.textContainer.lineBreakMode = (self.numberOfLines == 1 ? self.lineBreakMode : .byWordWrapping)
            
            let newAttributedString = self.effectiveAttributedString ?? NSAttributedString(string: "")
            // Only update if content actually changed
            if self.textContentStorage.attributedString != newAttributedString {
                self.textContentStorage.attributedString = newAttributedString
            }
            
            self.setNeedsLayout()
            self.setNeedsDisplay()
            self.invalidateIntrinsicContentSize()
        }
    }

    // MARK: - Sizing

    public override var intrinsicContentSize: CGSize {
        // Use preferredMaxLayoutWidth if provided, otherwise fit to content width
        let width: CGFloat
        if preferredMaxLayoutWidth > 0 {
            width = preferredMaxLayoutWidth
        } else if bounds.width > 0 {
            width = bounds.width
        } else {
            // No available width from bounds or preferred; measure using a very
            // large width so the label computes its natural intrinsic width
            // instead of claiming the full screen width in SwiftUI previews.
            width = CGFloat.greatestFiniteMagnitude / 2.0
        }
        return sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        // Fast path for empty content
        guard effectiveAttributedString?.length ?? 0 > 0 else {
            return .zero
        }
        
        // Configure a measuring container sized to the provided width
        let measureWidth = max(0, size.width)
        textContainer.size = CGSize(width: measureWidth, height: .greatestFiniteMagnitude)
        textContainer.maximumNumberOfLines = numberOfLines

        // Force layout by enumerating layout fragments
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)

        // Calculate used bounds more efficiently
        var usedRect = CGRect.zero
        textLayoutManager.enumerateTextLayoutFragments(
            from: textLayoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { layoutFragment in
            usedRect = usedRect.union(layoutFragment.layoutFragmentFrame)
            return true
        }

        // If numberOfLines > 0, clamp height to the line count
        if numberOfLines > 0 {
            let maxHeight = CGFloat(numberOfLines) * font.lineHeight
            usedRect.size.height = min(usedRect.size.height, maxHeight)
        }

        // Round up to integral values
        return CGSize(width: ceil(usedRect.size.width), height: ceil(usedRect.size.height))
    }
}
