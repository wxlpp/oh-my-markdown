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
    /// Render configuration generation the activation was captured at, carried
    /// for the policy's own use. It is **not** what gates activation: the
    /// generation also moves on width and style changes, so a private
    /// link-configuration revision is revalidated instead. Do not assume a
    /// generation change voids a tap.
    public let configurationGeneration: UInt64
    public init(url: URL, sourceRange: MarkdownSourceRange? = nil, configurationGeneration: UInt64) {
        self.url = url
        self.sourceRange = sourceRange
        self.configurationGeneration = configurationGeneration
    }
}

public enum MarkdownLinkDisposition: Sendable, Equatable {
    case allow(URL)
    case reject
}

/// Pure and `Sendable`: it decides, it never opens anything and never touches
/// platform state. Activation belongs to the `@MainActor` handler.
///
/// The decision runs on the cooperative pool, which is as wide as the core count
/// and is shared with the rest of the app. Do not block in it and do not perform
/// I/O: a policy that waits on a lock, a file, or the network holds a pool thread
/// for that whole time, and a handful of taps can stall unrelated async work.
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
    /// Shared by default so a SwiftUI body evaluation does not mint a new handler
    /// identity on every frame.
    public static let shared = PlatformMarkdownLinkHandler()
    private let allowedSchemes: Set<String>
    /// A policy that permits `mailto:` or `tel:` also has to say so here; the
    /// default refuses to hand the system anything but the web schemes.
    public init(allowedSchemes: Set<String> = ["http", "https"]) {
        self.allowedSchemes = Set(allowedSchemes.map { $0.lowercased() })
    }

    public func open(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), self.allowedSchemes.contains(scheme) else {
            assertionFailure("policy allowed \(scheme(of: url)) but this handler only opens \(self.allowedSchemes.sorted())")
            return
        }
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

    /// Identities derived from what a SwiftUI body can actually keep stable: the
    /// policy's concrete type and the handler's object identity. A body rebuilt
    /// every frame therefore installs the same configuration rather than a
    /// replacement.
    ///
    /// Two instances of one stateful policy type are identical here on purpose:
    /// the identity decides only whether an install is a replacement worth a
    /// generation bump, never whether the policy reaches the driver. The address
    /// is safe as a handler key because the configuration holding that handler is
    /// alive at every comparison, so the address cannot have been recycled.
    public static func derived(
        policy: any MarkdownLinkPolicy, handler: any MarkdownLinkHandler
    ) -> Self {
        Self(
            policy: policy, handler: handler,
            policyID: policy is WebOnlyMarkdownLinkPolicy
                ? WebOnlyMarkdownLinkPolicy.identity
                : .semantic(namespace: "link-policy-type:\(String(reflecting: type(of: policy)))", version: 1),
            handlerID: .semantic(
                namespace: "link-handler-object:\(UInt(bitPattern: ObjectIdentifier(handler)))", version: 1
            )
        )
    }

    /// What a view and its driver both start from. A single value, not a factory
    /// call each: `webOnly` mints a fresh handler identity per call, which would
    /// leave the two disagreeing about the installed handler until the first
    /// explicit install.
    public static let platformDefault = Self(
        policy: WebOnlyMarkdownLinkPolicy.default, handler: PlatformMarkdownLinkHandler.shared,
        policyID: WebOnlyMarkdownLinkPolicy.identity,
        handlerID: .semantic(namespace: "link-handler-platform-default", version: 1)
    )

    /// The built-in policy keeps its deterministic identity; the handler stays
    /// uniquely identified unless the caller opts into semantic sharing.
    public static func webOnly(
        handler: any MarkdownLinkHandler = PlatformMarkdownLinkHandler.shared,
        handlerID: MarkdownConfigurationID = .uniqueInstance()
    ) -> Self {
        Self(
            policy: WebOnlyMarkdownLinkPolicy.default, handler: handler,
            policyID: WebOnlyMarkdownLinkPolicy.identity, handlerID: handlerID
        )
    }
}

private func scheme(of url: URL) -> String {
    url.scheme?.lowercased() ?? "no scheme"
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
