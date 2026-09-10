import Foundation
import MarkdownRenderKit

/// 不可变文档中的渲染 UTF-16 选区。quote 是该范围的精确渲染字符串，
/// 附件保留 U+FFFC；它与用于粘贴的语义文本不同。
public struct MarkdownSelectionSnapshot: Sendable, Equatable, Codable {
    public let documentID: String
    public let revision: String
    public let renderedRange: NSRange
    public let quote: String
    public let renderedContentID: String

    public init(documentID: String, revision: String, renderedRange: NSRange, quote: String, renderedContentID: String = "") {
        self.documentID = documentID
        self.revision = revision
        self.renderedRange = renderedRange
        self.quote = quote
        self.renderedContentID = renderedContentID
    }

    package func matches(documentID: String, revision: String, text: NSAttributedString, renderedContentID: String) -> Bool {
        self.status(documentID: documentID, revision: revision, text: text, renderedContentID: renderedContentID) == .located
    }

    package func status(documentID: String, revision: String, text: NSAttributedString, renderedContentID: String) -> MarkdownAnnotationStatus {
        let range = self.renderedRange
        guard self.documentID == documentID, self.revision == revision else { return .documentMismatch }
        guard !self.renderedContentID.isEmpty, self.renderedContentID == renderedContentID else { return .renderedContentChanged }
        guard range.location >= 0, range.length > 0, range.location <= text.length,
              range.length <= text.length - range.location,
              Range(range, in: text.string) != nil else { return .invalidRange }
        return (text.string as NSString).substring(with: range) == self.quote ? .located : .quoteMismatch
    }
}

public struct MarkdownAnnotation: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let selection: MarkdownSelectionSnapshot
    public init(id: String, selection: MarkdownSelectionSnapshot) {
        self.id = id
        self.selection = selection
    }
}

/// 每个视图自己的批注配置。更新此值仅重绘，不重新解析正文。
@MainActor
public struct MarkdownReviewConfiguration {
    public let documentID: String
    public let revision: String
    public var annotations: [MarkdownAnnotation]
    public var commentActionTitle: String
    public var isCommentingEnabled: Bool
    public var copyActionTitle: String?
    public var copyMarkdownSourceActionTitle: String?
    public var onComment: @MainActor (MarkdownSelectionSnapshot) -> Void
    public var onAnnotationTap: @MainActor (String) -> Void

    public init(documentID: String, revision: String, annotations: [MarkdownAnnotation] = [], commentActionTitle: String = "Comment", isCommentingEnabled: Bool = true, copyActionTitle: String? = nil, copyMarkdownSourceActionTitle: String? = nil, onComment: @escaping @MainActor (MarkdownSelectionSnapshot) -> Void, onAnnotationTap: @escaping @MainActor (String) -> Void = { _ in }) {
        self.documentID = documentID
        self.revision = revision
        self.annotations = annotations
        self.commentActionTitle = commentActionTitle
        self.isCommentingEnabled = isCommentingEnabled
        self.copyActionTitle = copyActionTitle
        self.copyMarkdownSourceActionTitle = copyMarkdownSourceActionTitle
        self.onComment = onComment
        self.onAnnotationTap = onAnnotationTap
    }
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
extension MarkdownLabelView {
    public var selectionSnapshot: MarkdownSelectionSnapshot? {
        guard let range = self.currentRenderedSelectionRange() else { return nil }
        return self.reviewSelection(in: range)
    }

    package func reviewSelection(in range: NSRange) -> MarkdownSelectionSnapshot? {
        guard self.reviewSnapshotReady, let configuration = self.reviewConfiguration,
              let text = self.renderedAttributedStringForCopy,
              range.location >= 0, range.length > 0, range.location <= text.length,
              range.length <= text.length - range.location,
              Range(range, in: text.string) != nil else { return nil }
        return MarkdownSelectionSnapshot(documentID: configuration.documentID, revision: configuration.revision, renderedRange: range, quote: (text.string as NSString).substring(with: range), renderedContentID: self.currentSnapshot?.renderedContentID ?? "")
    }

    package var validReviewAnnotations: [MarkdownAnnotation] {
        guard self.reviewSnapshotReady, let configuration = self.reviewConfiguration,
              let text = self.renderedAttributedStringForCopy else { return [] }
        return configuration.annotations.filter { $0.selection.matches(documentID: configuration.documentID, revision: configuration.revision, text: text, renderedContentID: self.currentSnapshot?.renderedContentID ?? "") }
    }

    public func annotationStatus(id: String) -> MarkdownAnnotationStatus? {
        guard let configuration = self.reviewConfiguration,
              let annotation = configuration.annotations.first(where: { $0.id == id }) else { return nil }
        guard self.reviewSnapshotReady, let text = self.renderedAttributedStringForCopy else { return .rendering }
        return annotation.selection.status(documentID: configuration.documentID, revision: configuration.revision, text: text, renderedContentID: self.currentSnapshot?.renderedContentID ?? "")
    }

    /// 返回视图本地坐标中的批注范围；无有效批注时返回 nil。
    public func annotationRect(id: String) -> CGRect? {
        guard let annotation = self.validReviewAnnotations.first(where: { $0.id == id }) else { return nil }
        let rect = self.reviewRects(for: annotation.selection.renderedRange).reduce(CGRect.null) { $0.union($1) }
        return rect.isNull ? nil : rect
    }

    func reviewRects(for range: NSRange) -> [CGRect] {
        let textRange: NSTextRange?
        #if canImport(UIKit)
        textRange = self.makeTextRange(from: range.location, to: NSMaxRange(range))
        #else
        let start = self.layoutManager.textContentManager?.documentRange.location
        if let start, let manager = self.layoutManager.textContentManager,
           let lower = manager.location(start, offsetBy: range.location),
           let upper = manager.location(start, offsetBy: NSMaxRange(range)) {
            textRange = NSTextRange(location: lower, end: upper)
        } else { textRange = nil }
        #endif
        guard let textRange else { return [] }
        self.layoutManager.ensureLayout(for: textRange)
        var rects: [CGRect] = []
        self.layoutManager.enumerateTextSegments(in: textRange, type: .highlight, options: []) { _, frame, _, _ in
            rects.append(frame)
            return true
        }
        return rects
    }

    @discardableResult
    func activateReviewAnnotation(at point: CGPoint) -> Bool {
        // 重叠批注按输入顺序命中，调用方可将当前线程放在前面。
        guard let annotation = self.validReviewAnnotations.first(where: { annotation in
            self.reviewRects(for: annotation.selection.renderedRange).contains { $0.contains(point) }
        }) else { return false }
        self.reviewConfiguration?.onAnnotationTap(annotation.id)
        return true
    }

    func performReviewComment(_ snapshot: MarkdownSelectionSnapshot, snapshotID: UUID?) {
        guard self.reviewSnapshotReady, self.currentSnapshot?.id == snapshotID,
              let configuration = self.reviewConfiguration, configuration.isCommentingEnabled,
              let text = self.renderedAttributedStringForCopy,
              snapshot.matches(documentID: configuration.documentID, revision: configuration.revision, text: text, renderedContentID: self.currentSnapshot?.renderedContentID ?? "") else { return }
        configuration.onComment(snapshot)
    }
}

public enum MarkdownAnnotationStatus: String, Sendable, Equatable {
    case located, rendering, documentMismatch, renderedContentChanged, invalidRange, quoteMismatch
}
