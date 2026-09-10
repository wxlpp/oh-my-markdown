import MarkdownPlatformView
import SwiftUI

extension EnvironmentValues {
    @Entry public var markdownImageConfiguration: MarkdownImageConfiguration = .disabled
    @Entry public var markdownResourceErrorHandler: MarkdownResourceErrorHandler? = nil
    /// The type is `@MainActor`, so it cannot carry a main-actor default into this
    /// context; `nil` therefore means "unset", and a view that has had a
    /// configuration installed reverts to the web-only default when it is cleared.
    @Entry public var markdownLinkConfiguration: MarkdownLinkConfiguration? = nil
}

extension View {
    /// Chooses where images come from. Disabled by default, so a document that
    /// arrived over the network cannot make the library fetch anything.
    ///
    /// `.bundle()` serves resources that ship inside the app and reaches no
    /// network at all; `.defaultHTTPS` opts into remote loading.
    public func markdownImages(_ configuration: MarkdownImageConfiguration) -> some View {
        environment(\.markdownImageConfiguration, configuration)
    }

    /// Receives typed failures containing only a sanitized URL origin.
    public func onMarkdownResourceError(_ handler: @escaping MarkdownResourceErrorHandler) -> some View {
        environment(\.markdownResourceErrorHandler, handler)
    }

    /// Decides which links may activate and who opens them. The default is
    /// HTTP/HTTPS through the platform opener; a custom scheme needs **both** a
    /// policy that permits it and a handler that knows how to open it.
    /// Identities are derived from the policy's type and the handler's object
    /// identity, so rebuilding the body does not read as a replacement. The
    /// policy itself is forwarded on every update regardless, so a policy whose
    /// decisions depend on its stored properties takes effect as soon as the
    /// body carrying the new value is evaluated.
    public func markdownLinkPolicy(
        _ policy: any MarkdownLinkPolicy, handler: any MarkdownLinkHandler = PlatformMarkdownLinkHandler.shared
    ) -> some View {
        environment(\.markdownLinkConfiguration, MarkdownLinkConfiguration.derived(policy: policy, handler: handler))
    }

    /// Installs a link configuration whose identities the caller controls.
    public func markdownLinkConfiguration(_ configuration: MarkdownLinkConfiguration) -> some View {
        environment(\.markdownLinkConfiguration, configuration)
    }
}
