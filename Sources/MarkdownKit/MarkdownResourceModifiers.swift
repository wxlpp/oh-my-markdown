import MarkdownPlatformView
import SwiftUI

extension EnvironmentValues {
    @Entry public var markdownRemoteImageConfiguration: MarkdownRemoteImageConfiguration = .disabled
    @Entry public var markdownResourceErrorHandler: MarkdownResourceErrorHandler? = nil
}

extension View {
    /// Opts this subtree into remote image loading. Disabled by default.
    public func markdownRemoteImages(_ configuration: MarkdownRemoteImageConfiguration) -> some View {
        environment(\.markdownRemoteImageConfiguration, configuration)
    }

    /// Receives typed failures containing only a sanitized URL origin.
    public func onMarkdownResourceError(_ handler: @escaping MarkdownResourceErrorHandler) -> some View {
        environment(\.markdownResourceErrorHandler, handler)
    }
}
