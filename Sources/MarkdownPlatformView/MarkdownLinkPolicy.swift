import Foundation
import MarkdownCore
import MarkdownRenderKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Immutable snapshot a policy decides on. Carries no platform state, so the
/// decision can run off the main actor.
public struct MarkdownLinkRequest: Sendable, Equatable {
    public let url: URL
    /// Always `nil` today: link runs carry no source offsets until Task 9
    /// materializes them. Kept because the decision contract is public API and a
    /// policy that discriminates by position needs it; do not read it as dead.
    public let sourceRange: MarkdownSourceRange?
    /// Configuration generation the activation was captured at. Revalidated
    /// against the live generation before the handler runs.
    public let sessionGeneration: UInt64
    public init(url: URL, sourceRange: MarkdownSourceRange?, sessionGeneration: UInt64) {
        self.url = url
        self.sourceRange = sourceRange
        self.sessionGeneration = sessionGeneration
    }
}

public enum MarkdownLinkDisposition: Sendable, Equatable {
    case allow(URL)
    case reject
}

/// Pure and `Sendable`: it decides, it never opens anything and never touches
/// platform state. Activation belongs to the `@MainActor` handler.
public protocol MarkdownLinkPolicy: Sendable {
    func disposition(for request: MarkdownLinkRequest) -> MarkdownLinkDisposition
}

@MainActor
public protocol MarkdownLinkHandler: AnyObject {
    func open(_ url: URL)
}

/// HTTP and HTTPS only. Any other scheme needs both an explicit policy that
/// permits it and a handler that knows how to open it.
public struct WebOnlyMarkdownLinkPolicy: MarkdownLinkPolicy {
    public static let `default` = Self()
    public static let identity = MarkdownConfigurationID.semantic(namespace: "markdown-links-web-only", version: 1)
    public init() {}
    public func disposition(for request: MarkdownLinkRequest) -> MarkdownLinkDisposition {
        guard let scheme = request.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .reject
        }
        return .allow(request.url)
    }
}

extension MarkdownLinkPolicy where Self == WebOnlyMarkdownLinkPolicy {
    public static var webOnly: Self {
        .default
    }
}

/// The only place in the library that calls a platform opener.
@MainActor
public final class PlatformMarkdownLinkHandler: MarkdownLinkHandler {
    public init() {}
    public func open(_ url: URL) {
        // Defence in depth: the policy already rejected other schemes, and this
        // refuses to hand one to the system even if a custom policy allowed it.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

/// Owns both identities. Two wrappers over the same policy and handler instances
/// are distinct by default, so conformers that expose identical internal labels
/// cannot collide; pass an explicit ID to opt into sharing.
@MainActor
public struct MarkdownLinkConfiguration {
    package let policy: any MarkdownLinkPolicy
    package let handler: any MarkdownLinkHandler
    public let policyID: MarkdownConfigurationID
    public let handlerID: MarkdownConfigurationID
    package let replacementID = UUID()

    public init(
        policy: any MarkdownLinkPolicy,
        handler: any MarkdownLinkHandler,
        policyID: MarkdownConfigurationID = .uniqueInstance(),
        handlerID: MarkdownConfigurationID = .uniqueInstance()
    ) {
        self.policy = policy
        self.handler = handler
        self.policyID = policyID
        self.handlerID = handlerID
    }

    /// The built-in policy keeps its deterministic identity; the handler stays
    /// uniquely identified unless the caller opts into semantic sharing.
    public static func webOnly(
        handler: any MarkdownLinkHandler = PlatformMarkdownLinkHandler(),
        handlerID: MarkdownConfigurationID = .uniqueInstance()
    ) -> Self {
        Self(
            policy: WebOnlyMarkdownLinkPolicy.default, handler: handler,
            policyID: WebOnlyMarkdownLinkPolicy.identity, handlerID: handlerID
        )
    }
}

package enum MarkdownLinkEvaluation {
    /// Runs the pure decision off the main actor. That suspension is what makes
    /// the caller's post-decision revalidation load-bearing rather than a
    /// comparison of a value against itself.
    @concurrent package static func disposition(
        of policy: any MarkdownLinkPolicy, for request: MarkdownLinkRequest
    ) async -> MarkdownLinkDisposition {
        policy.disposition(for: request)
    }
}
