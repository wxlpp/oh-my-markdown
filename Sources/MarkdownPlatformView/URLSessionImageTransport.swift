import Foundation
import Synchronization

package enum URLSessionImageTransport {
    package static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }

    package static func configuration(request: MarkdownImageRequest, protocolClasses: [URLProtocol.Type] = []) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = self.seconds(request.requestTimeout)
        configuration.timeoutIntervalForResource = self.seconds(request.resourceTimeout)
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        return configuration
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    package static func load(_ request: MarkdownImageRequest, protocolClasses: [URLProtocol.Type]) async throws -> MarkdownImagePayload {
        guard self.isAllowed(request.url) else { throw MarkdownResourceError.invalidScheme }
        let delegate = ImageTransferDelegate()
        let configuration = configuration(request: request, protocolClasses: protocolClasses)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: configuration.timeoutIntervalForRequest)
        urlRequest.httpShouldHandleCookies = false
        let task = session.dataTask(with: urlRequest)
        return try await withTaskCancellationHandler {
            try await delegate.start(task)
        } onCancel: {
            delegate.finish(.failure(.cancelled), cancelling: true)
        }
    }
}

/// One delegate and isolated session per transfer. Mutex protects completion vs.
/// cancellation; no task, continuation, or partial bytes survive completion.
package final class ImageTransferDelegate: NSObject, URLSessionDataDelegate {
    private struct State {
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<MarkdownImagePayload, any Error>?
        var result: Result<MarkdownImagePayload, MarkdownResourceError>?
        var data = Data()
        var mime: String?
    }

    private let state = Mutex(State())

    package func start(_ task: URLSessionDataTask) async throws -> MarkdownImagePayload {
        try await withCheckedThrowingContinuation { continuation in
            let prior = self.state.withLock { state -> Result<MarkdownImagePayload, MarkdownResourceError>? in
                if let result = state.result { return result }
                state.task = task
                state.continuation = continuation
                return nil
            }
            if let prior { continuation.resume(with: prior.mapError { $0 as any Error }); task.cancel() }
            else { task.resume() }
        }
    }

    package func finish(_ result: Result<MarkdownImagePayload, MarkdownResourceError>, cancelling: Bool) {
        let pending = self.state.withLock { state -> (CheckedContinuation<MarkdownImagePayload, any Error>?, URLSessionDataTask?)? in
            guard state.result == nil else { return nil }
            state.result = result
            let pending = (state.continuation, state.task)
            state.continuation = nil
            state.task = nil
            state.data = Data()
            return pending
        }
        guard let pending else { return }
        if cancelling { pending.1?.cancel() }
        pending.0?.resume(with: result.mapError { $0 as any Error })
    }

    package func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let failure: MarkdownResourceError?
        if !URLSessionImageTransport.isAllowed(response.url) { failure = .invalidScheme }
        else if let response = response as? HTTPURLResponse {
            if !(200 ..< 300).contains(response.statusCode) { failure = .status(response.statusCode) }
            else if let mime = ValidatedImageFactory.normalizedMIME(response.value(forHTTPHeaderField: "Content-Type")) {
                self.state.withLock { $0.mime = mime }
                failure = nil
            } else { failure = .typeMismatch }
        } else { failure = .transport }
        if let failure {
            self.finish(.failure(failure), cancelling: true)
            completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }

    package func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let failure = self.state.withLock { state -> MarkdownResourceError? in
            guard state.result == nil else { return nil }
            guard state.mime != nil else { return .transport }
            // Subtraction is safe because accepted data never exceeds the limit.
            guard data.count <= ValidatedImageFactory.encodedByteLimit - state.data.count else { return .encodedLimit }
            state.data.append(data)
            return nil
        }
        if let failure { self.finish(.failure(failure), cancelling: true) }
    }

    package func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { self.finish(.failure(.classify(error)), cancelling: false); return }
        let result = self.state.withLock { state -> Result<MarkdownImagePayload, MarkdownResourceError> in
            guard let mime = state.mime else { return .failure(.transport) }
            return .success(.init(data: state.data, declaredMIMEType: mime))
        }
        self.finish(result, cancelling: false)
    }

    package func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard URLSessionImageTransport.isAllowed(response.url), URLSessionImageTransport.isAllowed(request.url), let url = request.url else {
            self.finish(.failure(.redirectRejected), cancelling: true)
            completionHandler(nil)
            return
        }
        // Rebuild even same-origin redirects. No Authorization, Cookie, Referer,
        // host-specific header, URL credential, or body may cross this boundary.
        var redirected = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: task.originalRequest?.timeoutInterval ?? request.timeoutInterval)
        redirected.httpShouldHandleCookies = false
        completionHandler(redirected)
    }

    package func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        self.respond(to: challenge, completionHandler: completionHandler)
    }

    package func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        self.respond(to: challenge, completionHandler: completionHandler)
    }

    private func respond(to challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            self.finish(.failure(.transport), cancelling: true)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
