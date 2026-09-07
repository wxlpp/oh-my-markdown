import MarkdownPlatformView
import SwiftUI

extension EnvironmentValues {
    @Entry public var markdownRemoteImageConfiguration: MarkdownRemoteImageConfiguration = .disabled
    @Entry public var markdownResourceErrorHandler: MarkdownResourceErrorHandler? = nil
    /// `nil` leaves each view on its own web-only default; the type is
    /// `@MainActor`, so it cannot carry a main-actor default into this context.
    @Entry public var markdownLinkConfiguration: MarkdownLinkConfiguration? = nil
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

    /// Decides which links may activate and who opens them. The default is
    /// HTTP/HTTPS through the platform opener; a custom scheme needs **both** a
    /// policy that permits it and a handler that knows how to open it.
    /// Identities are derived from the policy's type and the handler's object
    /// identity, so rebuilding the body does not read as a replacement. A
    /// value-type policy whose behaviour depends on its stored properties needs
    /// `markdownLinkConfiguration(_:)` with an explicit ID instead.
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

/// Two identities compared as one value, so the update guard cannot drift by
/// checking only half of what identifies a link configuration.
struct Pair<First: Equatable, Second: Equatable>: Equatable {
    let first: First
    let second: Second
    init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }
}
