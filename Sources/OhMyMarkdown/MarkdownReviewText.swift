import MarkdownPlatformView
import SwiftUI

/// 带原生选区评论菜单的不可变 Markdown 文档。切换文档/版本时重建独立视图，
/// 旧动作不能将范围应用到新版本。样式与 MarkdownText 使用相同环境配置。
public struct MarkdownReviewText: View {
    private let source: String
    private let configuration: MarkdownReviewConfiguration

    public init(_ source: String, documentID: String, revision: String, annotations: [MarkdownAnnotation] = [], commentActionTitle: String = "Comment", isCommentingEnabled: Bool = true, copyActionTitle: String? = nil, copyMarkdownSourceActionTitle: String? = nil, onComment: @escaping @MainActor (MarkdownSelectionSnapshot) -> Void, onAnnotationTap: @escaping @MainActor (String) -> Void = { _ in }) {
        self.source = source
        self.configuration = MarkdownReviewConfiguration(documentID: documentID, revision: revision, annotations: annotations, commentActionTitle: commentActionTitle, isCommentingEnabled: isCommentingEnabled, copyActionTitle: copyActionTitle, copyMarkdownSourceActionTitle: copyMarkdownSourceActionTitle, onComment: onComment, onAnnotationTap: onAnnotationTap)
    }

    public var body: some View {
        MarkdownText(self.source)
            .environment(\.markdownReviewConfiguration, self.configuration)
            .id(DocumentIdentity(documentID: self.configuration.documentID, revision: self.configuration.revision))
    }

    private struct DocumentIdentity: Hashable {
        let documentID: String
        let revision: String
    }
}

extension EnvironmentValues {
    @Entry var markdownReviewConfiguration: MarkdownReviewConfiguration? = nil
}
