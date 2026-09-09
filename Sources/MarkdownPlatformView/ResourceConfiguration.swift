import Foundation
import MarkdownRenderKit

/// Owns the cache namespace and replacement identity, independently of the loader.
public struct MarkdownImageConfiguration: Sendable {
    package let loader: (any MarkdownImageLoading)?
    public let configurationID: MarkdownConfigurationID
    public static let disabled = Self(optionalLoader: nil, configurationID: .semantic(namespace: "markdown-images-disabled", version: 1))
    public static var defaultHTTPS: Self {
        .https()
    }

    public static func https(requestTimeout: Duration = .seconds(15), resourceTimeout: Duration = .seconds(30)) -> Self {
        let loader = DefaultHTTPSImageLoader(requestTimeout: requestTimeout, resourceTimeout: resourceTimeout)
        let request = loader.requestTimeout.components
        let resource = loader.resourceTimeout.components
        return Self(loader: loader, configurationID: .semantic(
            namespace: "markdown-https-images:r=\(request.seconds).\(request.attoseconds):t=\(resource.seconds).\(resource.attoseconds):https-isolated:png-jpeg-gif-webp-heic-heif:20971520:8192:32:40000000", version: 1
        ))
    }

    /// Use a versioned semantic ID only when output semantics can be shared.
    public init(loader: any MarkdownImageLoading, configurationID: MarkdownConfigurationID = .uniqueInstance()) {
        self.loader = loader
        self.configurationID = configurationID
    }

    package init(optionalLoader: (any MarkdownImageLoading)?, configurationID: MarkdownConfigurationID) {
        self.loader = optionalLoader
        self.configurationID = configurationID
    }

    package func request(for url: URL) -> MarkdownImageRequest {
        if let builtIn = self.loader as? DefaultHTTPSImageLoader {
            return MarkdownImageRequest(url: url, requestTimeout: builtIn.requestTimeout, resourceTimeout: builtIn.resourceTimeout)
        }
        return MarkdownImageRequest(url: url)
    }
}
