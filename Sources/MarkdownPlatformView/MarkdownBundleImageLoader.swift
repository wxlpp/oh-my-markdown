import Foundation

/// Serves images that ship inside the app, by resource name.
///
/// Deliberately **not** a file loader. It resolves a reference through
/// `Bundle.url(forResource:withExtension:subdirectory:)`, which only ever
/// returns something inside the bundle, so a document that arrived over the
/// network cannot turn `![x](../../../etc/passwd)` — or any absolute path — into
/// a read. A reference that names a scheme, an absolute path, or a `..` segment
/// is rejected before the bundle is consulted, so the rejection does not depend
/// on the bundle layout either.
///
/// The bytes still go through the same validated construction as a remote image:
/// declared type against sniffed type, and the pixel, frame and byte limits.
/// Being local buys trust about *where* the bytes came from, not about what they
/// decode to.
public actor MarkdownBundleImageLoader: MarkdownImageLoading {
    private let bundle: Bundle
    private let subdirectory: String?

    /// - Parameters:
    ///   - bundle: Where to look. `.main` is the app's own bundle; pass
    ///     `Bundle.module` to serve a package's resources.
    ///   - subdirectory: Restricts lookup to one directory inside the bundle.
    ///     A reference is still matched by name, never by path.
    public init(bundle: Bundle = .main, subdirectory: String? = nil) {
        self.bundle = bundle
        self.subdirectory = subdirectory
    }

    public func load(_ request: MarkdownImageRequest) async throws -> MarkdownImagePayload {
        guard let url = self.resolve(request.url) else { throw MarkdownResourceError.invalidScheme }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            // The category, not the error: a diagnostic must not carry a path.
            throw MarkdownResourceError.transport
        }
        // The bundle knows the extension; the declared type comes from it rather
        // than from the document, which cannot be trusted to describe its own
        // bytes. Validation still sniffs and compares.
        return MarkdownImagePayload(data: data, declaredMIMEType: Self.mimeType(forExtension: url.pathExtension))
    }

    /// A reference this loader is willing to look up, or `nil`.
    ///
    /// `nonisolated` and pure so the rejection rules are testable on their own —
    /// they are the security boundary, and a boundary that can only be exercised
    /// through I/O tends not to be.
    nonisolated func resolve(_ reference: URL) -> URL? {
        guard reference.scheme == nil else { return nil }
        let path = reference.relativePath
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ $0 != ".." && $0 != "." && !$0.isEmpty }) else { return nil }
        guard let name = components.last.map(String.init) else { return nil }
        let directory = components.dropLast().joined(separator: "/")
        let subdirectory = [self.subdirectory, directory.isEmpty ? nil : directory]
            .compactMap(\.self).joined(separator: "/")
        return self.bundle.url(
            forResource: (name as NSString).deletingPathExtension,
            withExtension: (name as NSString).pathExtension.isEmpty ? nil : (name as NSString).pathExtension,
            subdirectory: subdirectory.isEmpty ? nil : subdirectory
        )
    }

    /// Only the types validated construction accepts; anything else is refused
    /// here rather than being sniffed out one layer later.
    private static func mimeType(forExtension pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "heif": "image/heif"
        default: "application/octet-stream"
        }
    }
}

extension MarkdownImageConfiguration {
    /// Serves images from a bundle, by resource name. Nothing leaves the process.
    ///
    /// The identity is semantic and includes the bundle, so two views serving the
    /// same bundle share resolved images — which is what a host means by shipping
    /// one asset and referencing it twice.
    public static func bundle(_ bundle: Bundle = .main, subdirectory: String? = nil) -> Self {
        Self(
            loader: MarkdownBundleImageLoader(bundle: bundle, subdirectory: subdirectory),
            configurationID: .semantic(
                namespace: "markdown-bundle-images:\(bundle.bundlePath):\(subdirectory ?? "")", version: 1
            )
        )
    }
}
