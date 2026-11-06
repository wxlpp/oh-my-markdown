import MarkdownRenderKit
import SwiftUI

extension EnvironmentValues {
    /// Optional caller-owned cache of completed, resource-free display models.
    @Entry public var markdownRenderCache: MarkdownRenderCache? = nil
}

extension View {
    /// Reuses compatible rendered content when SwiftUI recreates a Markdown view.
    /// Keep the cache alive at the list or screen owner, rather than in each row.
    public func markdownRenderCache(_ cache: MarkdownRenderCache?) -> some View {
        environment(\.markdownRenderCache, cache)
    }
}
