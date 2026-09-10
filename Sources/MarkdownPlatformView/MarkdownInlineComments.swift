import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

struct InlineCommentSlot {
    let id: String
    let paragraph: NSRange
    let offset: CGFloat
    let height: CGFloat
}

@MainActor
extension MarkdownLabelView {
    /// Reserve paragraph space without inserting characters. Selection/copy ranges and
    /// renderedContentID continue to refer to the immutable original document.
    func restoreInlineCommentSpacing() {
        guard let storage = self.contentStorage.textStorage else { return }
        self.contentStorage.performEditingTransaction {
            for (range, style) in self.inlineCommentOriginalStyles where NSMaxRange(range) <= storage.length {
                storage.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }
        self.inlineCommentOriginalStyles = [:]
        self.inlineCommentSlots = []
    }

    func applyInlineCommentSpacing() {
        self.restoreInlineCommentSpacing()
        guard let storage = self.contentStorage.textStorage, let configuration = self.reviewConfiguration else { return }
        let string = storage.string as NSString
        var heights: [NSRange: CGFloat] = [:]
        for annotation in self.validReviewAnnotations {
            guard let height = configuration.inlineCommentHeights[annotation.id], height.isFinite, height > 0 else { continue }
            let paragraph = string.paragraphRange(for: NSRange(location: NSMaxRange(annotation.selection.renderedRange) - 1, length: 1))
            let offset = heights[paragraph, default: 0]
            self.inlineCommentSlots.append(.init(id: annotation.id, paragraph: paragraph, offset: offset, height: height))
            heights[paragraph] = offset + height + 12
        }
        self.contentStorage.performEditingTransaction {
            for (range, height) in heights {
                let original = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle) ?? .default
                self.inlineCommentOriginalStyles[range] = original
                let style = original.mutableCopy() as! NSMutableParagraphStyle
                style.paragraphSpacing += height + 12
                storage.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }
    }

    func inlineCommentFrames() -> [String: CGRect] {
        guard let storage = self.contentStorage.textStorage else { return [:] }
        let string = storage.string as NSString
        var frames: [String: CGRect] = [:]
        for slot in self.inlineCommentSlots {
            guard slot.paragraph.location >= 0, slot.paragraph.location <= string.length, slot.paragraph.length > 0, slot.paragraph.length <= string.length - slot.paragraph.location else { continue }
            var end = NSMaxRange(slot.paragraph)
            while end > slot.paragraph.location && [10, 13].contains(string.character(at: end - 1)) {
                end -= 1
            }
            guard end > slot.paragraph.location else { continue }
            let lastCharacter = string.rangeOfComposedCharacterSequence(at: end - 1)
            guard let bottom = self.reviewRects(for: lastCharacter).map(\.maxY).max() else { continue }
            frames[slot.id] = CGRect(x: 0, y: bottom + 12 + slot.offset, width: self.layoutManager.textContainer?.size.width ?? self.bounds.width, height: slot.height)
        }
        return frames
    }

    func publishInlineCommentLayout() {
        self.reviewConfiguration?.onInlineCommentLayout(self.inlineCommentFrames())
    }
}
