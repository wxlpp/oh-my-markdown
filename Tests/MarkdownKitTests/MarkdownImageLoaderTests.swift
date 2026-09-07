import Foundation
import ImageIO
@testable import MarkdownPlatformView
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MarkdownImageLoaderTests {
    /// Original generated fixture, not a renamed HEIC: ISO-BMFF mif1/jpeg brands,
    /// a jpeg item, and complete JPEG-coded pixel data produced by ImageIO.
    /// Box layout follows ISO/IEC 14496-12 and 23008-12; no third-party image or
    /// implementation is distributed. libheif's JPEG codec documentation was
    /// consulted to confirm that a full JPEG bitstream needs no jpgC split.
    static func jpegHEIF() throws -> Data {
        func word(_ n: Int) -> Data {
            Data([UInt8((n >> 8) & 255), UInt8(n & 255)])
        }
        func integer(_ n: Int) -> Data {
            Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
        }
        func box(_ type: String, _ body: Data) -> Data {
            integer(body.count + 8) + Data(type.utf8) + body
        }
        let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let pixels = try #require(context.makeImage())
        let jpeg = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, nil)
        #expect(CGImageDestinationFinalize(destination))
        let ftyp = box("ftyp", Data("mif1".utf8) + integer(0) + Data("mif1jpeg".utf8))
        func metadata(offset: Int) -> Data {
            let hdlr = box("hdlr", integer(0) + integer(0) + Data("pict".utf8) + Data(repeating: 0, count: 13))
            let pitm = box("pitm", integer(0) + word(1))
            let iloc = box("iloc", integer(0) + Data([0x44, 0]) + word(1) + word(1) + word(0) + word(1) + integer(offset) + integer(jpeg.length))
            let infe = box("infe", integer(0x0200_0000) + word(1) + word(0) + Data("jpeg".utf8) + Data([0]))
            let iinf = box("iinf", integer(0) + word(1) + infe)
            let ispe = box("ispe", integer(0) + integer(32) + integer(32))
            let pixi = box("pixi", integer(0) + Data([3, 8, 8, 8]))
            let ipco = box("ipco", ispe + pixi)
            let ipma = box("ipma", integer(0) + integer(1) + word(1) + Data([2, 0x81, 0x82]))
            return box("meta", integer(0) + hdlr + pitm + iloc + iinf + box("iprp", ipco + ipma))
        }
        return ftyp + metadata(offset: ftyp.count + metadata(offset: 0).count + 8) + box("mdat", jpeg as Data)
    }

    @Test func genuineHEIFValidatesOnlyWithItsDistinctDeclaredMIME() throws {
        let data = try Self.jpegHEIF()
        let source = CGImageSourceCreateIncremental([kCGImageSourceShouldCache: false] as CFDictionary)
        CGImageSourceUpdateData(source, data as CFData, true)
        #expect(CGImageSourceGetType(source) as String? == "public.heif")
        #expect(CGImageSourceGetStatus(source) == .statusComplete)
        #expect(CGImageSourceGetCount(source) == 1)
        // Fixture fidelity: ImageIO can actually decode these JPEG-coded pixels.
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 32 && image.height == 32)
        let validated = try ValidatedImageFactory.validate(.init(data: data, declaredMIMEType: "image/heif"))
        #expect(validated.metadata == .init(mimeType: "image/heif", pixelWidth: 32, pixelHeight: 32, frameCount: 1, cumulativePixels: 1024))
        for mime in ["image/heic", "image/jpeg", "image/png"] {
            #expect(throws: MarkdownResourceError.typeMismatch) { try ValidatedImageFactory.validate(.init(data: data, declaredMIMEType: mime)) }
        }
    }

    @Test func directLoaderUsesTheStricterConfiguredAndRequestTimeoutCaps() async throws {
        for (requested, expected) in [(15, 15), (20, 20), (120, 75)] {
            let url = Self.route { proto in
                #expect(proto.request.timeoutInterval == Double(expected))
                proto.respond()
            }
            defer { ControlledProtocol.routes.withLock { $0[url.path] = nil } }
            let loader = DefaultHTTPSImageLoader(requestTimeout: .seconds(75), resourceTimeout: .seconds(95), protocolClasses: [ControlledProtocol.self])
            let request = requested == 15 ? MarkdownImageRequest(url: url) : MarkdownImageRequest(url: url, requestTimeout: .seconds(requested))
            #expect(try await loader.load(request).data == Self.png)
        }
    }

    #if os(macOS)
    @Test func constructionGateRejectsAlternateConstructorSpellings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-image-gate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("MarkdownPlatformView"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "package struct MarkdownEncodedImage {}".write(to: fixture.appendingPathComponent("MarkdownPlatformView/ValidatedImageFactory.swift"), atomically: true, encoding: .utf8)
        func status(_ source: String) throws -> Int32 {
            try source.write(to: fixture.appendingPathComponent("Consumer.swift"), atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [root.appendingPathComponent("Scripts/check-validated-image-construction.sh").path, fixture.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try status("func consume(_ image: MarkdownEncodedImage) {}") == 0)
        for source in [
            "MarkdownEncodedImage(validatedData: data, metadata: metadata)",
            "MarkdownPlatformView.MarkdownEncodedImage\n (validatedData: data, metadata: metadata)",
            "MarkdownEncodedImage /* outer /* inner */ end */ . `init` (validatedData: data, metadata: metadata)",
            "let constructor = MarkdownEncodedImage.init",
            "typealias Alias = MarkdownEncodedImage",
            "typealias\n Alias =\n MarkdownEncodedImage",
            "extension MarkdownEncodedImage { init() {} }",
            "let image: MarkdownEncodedImage = .init(\n validatedData: data, metadata: metadata)",
        ] {
            #expect(try status(source) == 1, "Gate accepted: \(source)")
        }
    }
    #endif
    final class ControlledProtocol: URLProtocol, @unchecked Sendable {
        struct Route {
            let start: @Sendable (ControlledProtocol) -> Void
            let stop: @Sendable () -> Void
        }

        static let routes = Mutex<[String: Route]>([:])
        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            let route = Self.routes.withLock { $0[self.request.url!.path] }
            route?.start(self)
        }

        override func stopLoading() {
            let route = Self.routes.withLock { $0[self.request.url!.path] }
            route?.stop()
        }

        func respond(status: Int = 200, mime: String = "image/png", finalURL: URL? = nil, data: Data = MarkdownImageLoaderTests.png) {
            let response = HTTPURLResponse(url: finalURL ?? self.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    static func route(start: @escaping @Sendable (ControlledProtocol) -> Void, stop: @escaping @Sendable () -> Void = {}) -> URL {
        let path = "/" + UUID().uuidString
        ControlledProtocol.routes.withLock { $0[path] = .init(start: start, stop: stop) }
        return URL(string: "https://image-transport.test" + path)!
    }

    @Test func isolatedConfigurationNeverUsesAmbientStorageAndClampsTimeouts() async throws {
        let request = try MarkdownImageRequest(url: #require(URL(string: "https://example.test")), requestTimeout: .zero, resourceTimeout: .seconds(1000))
        let configuration = URLSessionImageTransport.configuration(request: request)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.timeoutIntervalForRequest == 1)
        #expect(configuration.timeoutIntervalForResource == 120)
        let defaults = URLSessionImageTransport.configuration(request: .init(url: request.url))
        #expect(defaults.timeoutIntervalForRequest == 15)
        #expect(defaults.timeoutIntervalForResource == 30)

        let url = Self.route { proto in
            #expect(proto.request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(proto.request.value(forHTTPHeaderField: "Authorization") == nil)
            proto.respond()
        }
        let host = try #require(url.host)
        let cookie = try #require(HTTPCookie(properties: [.domain: host, .path: "/", .name: "private-" + UUID().uuidString, .value: "ambient-secret", .secure: "TRUE"]))
        HTTPCookieStorage.shared.setCookie(cookie)
        let credential = URLCredential(user: "ambient-user", password: "ambient-password", persistence: .forSession)
        let space = try URLProtectionSpace(host: #require(url.host), port: 443, protocol: "https", realm: UUID().uuidString, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        URLCredentialStorage.shared.setDefaultCredential(credential, for: space)
        try URLCache.shared.storeCachedResponse(CachedURLResponse(response: #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])), data: Data("cached-secret".utf8)), for: URLRequest(url: url))
        defer {
            HTTPCookieStorage.shared.deleteCookie(cookie)
            URLCredentialStorage.shared.remove(credential, for: space)
            URLCache.shared.removeCachedResponse(for: URLRequest(url: url))
            ControlledProtocol.routes.withLock { $0[url.path] = nil }
        }
        let payload = try await DefaultHTTPSImageLoader(protocolClasses: [ControlledProtocol.self]).load(.init(url: url))
        #expect(payload.data == Self.png)
    }

    @Test func redirectPolicyRejectsDowngradeAndRebuildsCrossHostRequests() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = try session.dataTask(with: #require(URL(string: "https://first.test/image")))
        let originalURL = try #require(task.originalRequest?.url)
        let response = try #require(HTTPURLResponse(url: originalURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [:]))
        for url in ["http://second.test/image", "https://user:secret@second.test/image"] {
            let delegate = ImageTransferDelegate()
            let observed = Mutex(false)
            try delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: #require(URL(string: url)))) { value in observed.withLock { $0 = value == nil } }
            #expect(observed.withLock { $0 })
            await #expect(throws: MarkdownResourceError.redirectRejected) { try await delegate.start(task) }
        }
        var request = try URLRequest(url: #require(URL(string: "https://second.test/image")))
        request.allHTTPHeaderFields = ["Authorization": "Bearer secret", "X-Host-Secret": "secret", "Cookie": "secret", "Referer": "secret"]
        request.httpBody = Data("body-secret".utf8)
        let observed = Mutex<URLRequest?>(nil)
        ImageTransferDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { value in observed.withLock { $0 = value } }
        let forwarded = try #require(observed.withLock { $0 })
        #expect(forwarded.url == request.url)
        #expect(forwarded.allHTTPHeaderFields?.isEmpty != false)
        #expect(forwarded.httpBody == nil)
        #expect(!forwarded.httpShouldHandleCookies)
        #expect(forwarded.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func actualRedirectDowngradeIsRejected() async {
        let url = Self.route { proto in
            let response = HTTPURLResponse(url: proto.request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "http://image-transport.test/downgrade"])!
            proto.client?.urlProtocol(proto, wasRedirectedTo: URLRequest(url: URL(string: "http://image-transport.test/downgrade")!), redirectResponse: response)
        }
        defer { ControlledProtocol.routes.withLock { $0[url.path] = nil } }
        await #expect(throws: MarkdownResourceError.redirectRejected) {
            try await DefaultHTTPSImageLoader(protocolClasses: [ControlledProtocol.self]).load(.init(url: url))
        }
    }

    @Test func actualCrossHostRedirectDoesNotForwardHostHeaders() async throws {
        let target = Self.route { proto in
            #expect(proto.request.url?.host == "second-host.test")
            for header in ["Authorization", "X-Host-Secret", "Cookie", "Referer"] {
                #expect(proto.request.value(forHTTPHeaderField: header) == nil)
            }
            proto.respond()
        }
        let destination = try #require(URL(string: target.absoluteString.replacingOccurrences(of: "image-transport.test", with: "second-host.test")))
        let source = Self.route { proto in
            let response = HTTPURLResponse(url: proto.request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString])!
            var request = URLRequest(url: destination)
            request.allHTTPHeaderFields = ["Authorization": "secret", "X-Host-Secret": "secret", "Cookie": "secret", "Referer": "secret"]
            proto.client?.urlProtocol(proto, wasRedirectedTo: request, redirectResponse: response)
        }
        defer { ControlledProtocol.routes.withLock { $0[target.path] = nil; $0[source.path] = nil } }
        let payload = try await DefaultHTTPSImageLoader(protocolClasses: [ControlledProtocol.self]).load(.init(url: source))
        #expect(payload.data == Self.png)
    }

    @Test func protocolAuthenticationChallengeCannotUseProposedCredential() async {
        let url = Self.route { proto in
            let space = URLProtectionSpace(host: proto.request.url!.host!, port: 443, protocol: "https", realm: "private", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: URLCredential(user: "private-user", password: "private-password", persistence: .forSession), previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender())
            proto.client?.urlProtocol(proto, didReceive: challenge)
        }
        defer { ControlledProtocol.routes.withLock { $0[url.path] = nil } }
        await #expect(throws: MarkdownResourceError.transport) {
            try await DefaultHTTPSImageLoader(protocolClasses: [ControlledProtocol.self]).load(.init(url: url))
        }
    }

    @Test func allowedMIMESetStillRequiresMatchingDetectedImageType() async throws {
        for mime in ["image/png", "image/jpeg", "image/gif", "image/webp", "image/heic", "image/heif"] {
            let url = Self.route { $0.respond(mime: mime) }
            defer { ControlledProtocol.routes.withLock { $0[url.path] = nil } }
            let payload = try await DefaultHTTPSImageLoader(protocolClasses: [ControlledProtocol.self]).load(.init(url: url))
            #expect(payload.declaredMIMEType == mime)
            if mime != "image/png" {
                #expect(throws: MarkdownResourceError.typeMismatch) { try ValidatedImageFactory.validate(payload) }
            }
        }
    }

    @Test func exactMetadataBudgetsAreAcceptedAndTruncatedContainersAreRejected() throws {
        let gif = try Self.validGIF(width: 2000, height: 2000, frames: 10)
        #expect(try ValidatedImageFactory.validate(.init(data: gif, declaredMIMEType: "image/gif")).metadata.cumulativePixels == 40_000_000)
        var boundary = Self.png
        boundary.append(Data(repeating: 0, count: 20 * 1024 * 1024 - boundary.count))
        #expect(try ValidatedImageFactory.validate(.init(data: boundary, declaredMIMEType: " IMAGE/PNG; charset=binary ")).data.count == 20 * 1024 * 1024)
        for data in [Self.png.prefix(40), Self.gif().dropLast(4)] {
            #expect(throws: MarkdownResourceError.typeMismatch) {
                try ValidatedImageFactory.validate(.init(data: Data(data), declaredMIMEType: data.first == 137 ? "image/png" : "image/gif"))
            }
        }
    }

    @Test func JPEGWebPAndHEICSignaturesSelectTheirMatchingImageIODecoder() throws {
        for (type, mime) in [("public.jpeg", "image/jpeg"), ("public.heic", "image/heic")] {
            let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let image = try #require(context.makeImage())
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            let validated = try ValidatedImageFactory.validate(.init(data: data as Data, declaredMIMEType: mime))
            #expect(validated.metadata.mimeType == mime)
            #expect(validated.metadata.pixelWidth == 32)
        }
        let webp = try #require(Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"))
        #expect(try ValidatedImageFactory.validate(.init(data: webp, declaredMIMEType: "image/webp")).metadata.pixelWidth == 1)
    }

    final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
        func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
        func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
    }

    @Test func implicitAuthenticationIsCancelledForSessionAndTaskChallenges() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = try session.dataTask(with: #require(URL(string: "https://example.test/image")))
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodServerTrust] {
            let space = URLProtectionSpace(host: "example.test", port: 443, protocol: "https", realm: "private", authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: URLCredential(user: "secret-user", password: "secret-password", persistence: .forSession), previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender())
            let expected: URLSession.AuthChallengeDisposition = method == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge
            let delegate = ImageTransferDelegate()
            let calls = Mutex(0)
            let handler: @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void = { disposition, credential in
                #expect(disposition == expected)
                #expect(credential == nil)
                calls.withLock { $0 += 1 }
            }
            delegate.urlSession(session, didReceive: challenge, completionHandler: handler)
            delegate.urlSession(session, task: task, didReceive: challenge, completionHandler: handler)
            #expect(calls.withLock { $0 } == 2)
        }
    }

    @Test func nonHTTPAndMissingResponsesAreRejected() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "https://example.test"))
        for hasResponse in [true, false] {
            let delegate = ImageTransferDelegate()
            let task = session.dataTask(with: url)
            if hasResponse {
                delegate.urlSession(session, dataTask: task, didReceive: URLResponse(url: url, mimeType: "image/png", expectedContentLength: 0, textEncodingName: nil)) { #expect($0 == .cancel) }
            } else { delegate.urlSession(session, task: task, didCompleteWithError: nil) }
            await #expect(throws: MarkdownResourceError.transport) { try await delegate.start(task) }
        }
    }

    @Test func isolatedTransportDeliversBodyAndAcceptsExactEncodedLimit() async throws {
        for size in [Self.png.count, 20 * 1024 * 1024] {
            let url = Self.route { proto in
                #expect(proto.request.value(forHTTPHeaderField: "Cookie") == nil)
                #expect(proto.request.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(proto.request.cachePolicy == .reloadIgnoringLocalCacheData)
                proto.respond(data: Data(repeating: 7, count: size))
            }
            defer { ControlledProtocol.routes.withLock { $0[url.path] = nil } }
            let payload = try await DefaultHTTPSImageLoader(protocolClasses: [ControlledProtocol.self]).load(.init(url: url))
            #expect(payload.data.count == size)
            #expect(payload.declaredMIMEType == "image/png")
        }
    }

    @Test func oversizedStreamCancelsBeforeCompletion() async {
        let (stopped, stop) = AsyncStream<Void>.makeStream()
        let url = Self.route(start: { proto in
            let response = HTTPURLResponse(url: proto.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
            proto.client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
            proto.client?.urlProtocol(proto, didLoad: Data(repeating: 0, count: 20 * 1024 * 1024))
            proto.client?.urlProtocol(proto, didLoad: Data([1]))
            // Deliberately never finish. Returning requires cancelling at the limit.
        }, stop: { stop.yield(()); stop.finish() })
        defer { ControlledProtocol.routes.withLock { $0[url.path] = nil } }
        await #expect(throws: MarkdownResourceError.encodedLimit) {
            try await DefaultHTTPSImageLoader(protocolClasses: [ControlledProtocol.self]).load(.init(url: url))
        }
        if await stopped.first(where: { true }) == nil { Issue.record("Transport did not cancel oversized transfer") }
    }

    @Test func HTTPResponsePolicyAndTimeoutErrorsAreTyped() async {
        let cases: [(Int, String, String?, MarkdownResourceError)] = [
            (404, "image/png", nil, .status(404)),
            (200, "text/html", nil, .typeMismatch),
            (200, "image/svg+xml", nil, .typeMismatch),
            (200, "image/png", "http://image-transport.test/downgrade", .invalidScheme),
        ]
        for (status, mime, finalURL, expected) in cases {
            let url = Self.route { $0.respond(status: status, mime: mime, finalURL: finalURL.flatMap(URL.init(string:))) }
            defer { ControlledProtocol.routes.withLock { $0[url.path] = nil } }
            await #expect(throws: expected) {
                try await DefaultHTTPSImageLoader(protocolClasses: [ControlledProtocol.self]).load(.init(url: url))
            }
        }
        let url = Self.route { $0.client?.urlProtocol($0, didFailWithError: URLError(.timedOut)) }
        defer { ControlledProtocol.routes.withLock { $0[url.path] = nil } }
        await #expect(throws: MarkdownResourceError.timedOut) {
            try await DefaultHTTPSImageLoader(protocolClasses: [ControlledProtocol.self]).load(.init(url: url))
        }
    }

    @Test func callerCancellationStopsTheActualTransport() async {
        let (started, start) = AsyncStream<Void>.makeStream()
        let (stopped, stop) = AsyncStream<Void>.makeStream()
        let url = Self.route(start: { _ in start.yield(()); start.finish() }, stop: { stop.yield(()); stop.finish() })
        defer { ControlledProtocol.routes.withLock { $0[url.path] = nil } }
        let task = Task { try await DefaultHTTPSImageLoader(protocolClasses: [ControlledProtocol.self]).load(.init(url: url)) }
        guard await started.first(where: { true }) != nil else { Issue.record("Transport never started"); return }
        task.cancel()
        await #expect(throws: MarkdownResourceError.cancelled) { try await task.value }
        #expect(await stopped.first(where: { true }) != nil)
    }

    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==")!

    static func gif(width: UInt16 = 1, height: UInt16 = 1, frames: Int = 1) -> Data {
        func word(_ value: UInt16) -> [UInt8] {
            [UInt8(value & 255), UInt8(value >> 8)]
        }
        var bytes = Array("GIF89a".utf8) + word(width) + word(height) + [0x80, 0, 0, 0, 0, 0, 255, 255, 255]
        for _ in 0 ..< frames {
            bytes += [0x2C, 0, 0, 0, 0] + word(width) + word(height) + [0, 2, 2, 0x44, 1, 0]
        }
        bytes.append(0x3B)
        return Data(bytes)
    }

    static func validGIF(width: Int, height: Int, frames: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, frames, nil))
        for _ in 0 ..< frames {
            CGImageDestinationAddImage(destination, image, nil)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func validPNGAndGIFMetadataCanReachTheConsumer() throws {
        let png = try ValidatedImageFactory.validate(.init(data: Self.png, declaredMIMEType: "image/png"))
        #expect(png.metadata == .init(mimeType: "image/png", pixelWidth: 1, pixelHeight: 1, frameCount: 1, cumulativePixels: 1))
        let gif = try ValidatedImageFactory.validate(.init(data: Self.gif(frames: 32), declaredMIMEType: "image/gif"))
        #expect(gif.metadata.frameCount == 32)
        #expect(gif.metadata.cumulativePixels == 32)
        let boundary = try ValidatedImageFactory.validate(.init(data: Self.gif(width: 8192), declaredMIMEType: "image/gif"))
        #expect(boundary.metadata.pixelWidth == 8192)
    }

    @Test func rejectedMetadataNeverReachesAFullImageConsumer() throws {
        let cases: [(Data, String?, MarkdownResourceError)] = try [
            (Self.png, "image/jpeg", .typeMismatch),
            (Self.png, nil, .typeMismatch),
            (Self.png, "image/svg+xml", .typeMismatch),
            (Self.png, ";image/png", .typeMismatch),
            (Data("not an image".utf8), "image/png", .typeMismatch),
            (Self.png.prefix(24), "image/png", .typeMismatch),
            (Self.gif(width: 8193), "image/gif", .metadataLimit),
            // This synthetic header has insufficient compressed pixels; ImageIO
            // rejects it as malformed before exposing any frame properties.
            (Self.gif(width: 65535, height: 65535), "image/gif", .typeMismatch),
            (Self.gif(frames: 33), "image/gif", .metadataLimit),
            (Self.validGIF(width: 2000, height: 2000, frames: 11), "image/gif", .metadataLimit),
            (Data(repeating: 0, count: 20 * 1024 * 1024 + 1), "image/png", .encodedLimit),
        ]
        var consumerCalls = 0
        for (data, mime, expected) in cases {
            do {
                _ = try ValidatedImageFactory.validate(.init(data: data, declaredMIMEType: mime))
                consumerCalls += 1
                Issue.record("Rejected payload reached consumer: \(expected)")
            } catch {
                #expect(error as? MarkdownResourceError == expected, "Fixture bytes=\(data.count), header=\(Array(data.prefix(10)))")
            }
        }
        #expect(consumerCalls == 0)
    }

    @Test(arguments: ["http://example.test/a", "file:///tmp/a", "data:image/png;base64,AA", "https://user:secret@example.test/a"])
    func builtInRejectsInitialSchemesAndEmbeddedCredentials(url: String) async throws {
        await #expect(throws: MarkdownResourceError.invalidScheme) {
            try await DefaultHTTPSImageLoader().load(.init(url: #require(URL(string: url))))
        }
    }
}
