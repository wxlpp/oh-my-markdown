import Foundation

/// Loads untrusted encoded bytes. Every result is validated before decoding.
public protocol MarkdownImageLoading: Sendable {
    func load(_ request: MarkdownImageRequest) async throws -> MarkdownImagePayload
}

public struct MarkdownImageRequest: Sendable {
    public let url: URL
    public let requestTimeout: Duration
    public let resourceTimeout: Duration
    public init(url: URL, requestTimeout: Duration = .seconds(15), resourceTimeout: Duration = .seconds(30)) {
        self.url = url
        self.requestTimeout = min(.seconds(120), max(.seconds(1), requestTimeout))
        self.resourceTimeout = min(.seconds(120), max(.seconds(1), resourceTimeout))
    }
}

public struct MarkdownImagePayload: Sendable {
    public let data: Data
    public let declaredMIMEType: String?
    public init(data: Data, declaredMIMEType: String?) {
        self.data = data
        self.declaredMIMEType = declaredMIMEType
    }
}

public struct MarkdownImageMetadata: Sendable, Equatable {
    public let mimeType: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frameCount: Int
    public let cumulativePixels: UInt64
    public init(mimeType: String, pixelWidth: Int, pixelHeight: Int, frameCount: Int, cumulativePixels: UInt64) {
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameCount = frameCount
        self.cumulativePixels = cumulativePixels
    }
}

public enum MarkdownResourceError: Error, Sendable, Equatable {
    case disabled, invalidScheme, redirectRejected, status(Int), typeMismatch
    case encodedLimit, metadataLimit, timedOut, cancelled, transport

    package static func classify(_ error: any Error) -> Self {
        if let typed = error as? Self { return typed }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            if error.code == .cancelled { return .cancelled }
            if error.code == .timedOut { return .timedOut }
        }
        return .transport
    }
}

/// The only URL information allowed in public resource diagnostics.
public struct SanitizedMarkdownOrigin: Sendable, Equatable {
    public let scheme: String
    public let host: String
    public let port: Int?
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        let port = components.port
        self.port = (scheme == "https" && port == 443) || (scheme == "http" && port == 80) ? nil : port
    }
}

extension SanitizedMarkdownOrigin: CustomStringConvertible {
    /// `scheme://host` with the port only when it is not the scheme's default.
    /// Safe to log or show: by construction there is no path, query or fragment
    /// here to leak.
    public var description: String {
        self.port.map { "\(self.scheme)://\(self.host):\($0)" } ?? "\(self.scheme)://\(self.host)"
    }
}

public struct MarkdownResourceFailure: Sendable, Equatable {
    public let category: MarkdownResourceError
    public let origin: SanitizedMarkdownOrigin?
    public init(category: MarkdownResourceError, origin: SanitizedMarkdownOrigin?) {
        self.category = category
        self.origin = origin
    }
}

public typealias MarkdownResourceErrorHandler = @MainActor @Sendable (MarkdownResourceFailure) -> Void

/// Isolated, HTTPS-only transport. Timeouts are clamped to 1...120 seconds.
/// Each effective timeout is the smaller of the loader's configured cap and the
/// request's cap. A request initialized with only a URL retains its 15/30-second
/// defaults; pass longer request caps explicitly when increasing loader timeouts.
/// The SwiftUI/native configuration wrapper supplies its configured caps for you.
public actor DefaultHTTPSImageLoader: MarkdownImageLoading {
    package nonisolated let requestTimeout: Duration
    package nonisolated let resourceTimeout: Duration
    private let protocolClasses: [URLProtocol.Type]
    public init(requestTimeout: Duration = .seconds(15), resourceTimeout: Duration = .seconds(30)) {
        self.requestTimeout = min(.seconds(120), max(.seconds(1), requestTimeout))
        self.resourceTimeout = min(.seconds(120), max(.seconds(1), resourceTimeout))
        self.protocolClasses = []
    }

    package init(requestTimeout: Duration = .seconds(15), resourceTimeout: Duration = .seconds(30), protocolClasses: [URLProtocol.Type]) {
        self.requestTimeout = min(.seconds(120), max(.seconds(1), requestTimeout))
        self.resourceTimeout = min(.seconds(120), max(.seconds(1), resourceTimeout))
        self.protocolClasses = protocolClasses
    }

    public func load(_ request: MarkdownImageRequest) async throws -> MarkdownImagePayload {
        try await URLSessionImageTransport.load(MarkdownImageRequest(
            url: request.url, requestTimeout: min(request.requestTimeout, self.requestTimeout),
            resourceTimeout: min(request.resourceTimeout, self.resourceTimeout)
        ), protocolClasses: self.protocolClasses)
    }
}
