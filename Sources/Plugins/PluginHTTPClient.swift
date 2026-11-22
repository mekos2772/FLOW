import Foundation

/// Applies the plugin URL policy to the initial request and every redirect, before it is followed.
enum PluginHTTPClient {
    static func data(for request: URLRequest,
                     session: URLSession,
                     allowedDomains: [String],
                     networkAllowed: @escaping @Sendable () -> Bool,
                     maximumBytes: Int? = nil) async throws -> (Data, URLResponse) {
        let redirects = RedirectValidator(
            allowedDomains: allowedDomains,
            originURL: request.url,
            networkAllowed: networkAllowed
        )
        try redirects.validate(request)
        // Background sessions follow redirects without consulting task delegates. Fail closed.
        guard session.configuration.identifier == nil else {
            throw URLError(.unsupportedURL)
        }
        do {
            if let maximumBytes {
                let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
                defer { bytes.task.cancel() }
                if let violation = redirects.violation { throw violation }
                guard response.expectedContentLength <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                var buffer = Data()
                buffer.reserveCapacity(min(maximumBytes, 64 * 1024))
                for try await byte in bytes {
                    guard buffer.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                    if buffer.count.isMultiple(of: 16 * 1024) {
                        try Task.checkCancellation()
                        guard networkAllowed() else { throw SourceDomainPolicy.Violation.networkDisabled }
                    }
                    buffer.append(byte)
                }
                if let violation = redirects.violation { throw violation }
                return (buffer, response)
            }
            let result = try await session.data(for: request, delegate: redirects)
            if let violation = redirects.violation { throw violation }
            return result
        } catch {
            // Refusing a redirect may complete with its 3xx response or a cancellation error.
            // Always surface the policy failure rather than exposing the redirect as a success.
            if let violation = redirects.violation { throw violation }
            throw error
        }
    }

    /// 跨源仅保留通用播放头，任意自定义认证头也不能随重定向或 HLS 子请求外发。
    static func headers(_ headers: [String: String], from origin: URL, to target: URL) -> [String: String] {
        let safe: Set<String> = ["accept", "accept-language", "user-agent", "range", "if-range", "cache-control", "pragma"]
        return headers.filter { key, _ in
            let name = key.lowercased()
            guard !["host", "connection", "proxy-authorization", "content-length"].contains(name) else { return false }
            return SourceDomainPolicy.isSameOrigin(origin, as: target) || safe.contains(name)
        }
    }

    final class RedirectValidator: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let allowedDomains: [String]
        private let originURL: URL?
        private let originIsPrivate: Bool
        private let networkAllowed: @Sendable () -> Bool
        private let lock = NSLock()
        private var rejectedRedirect: SourceDomainPolicy.Violation?

        init(allowedDomains: [String],
             originURL: URL? = nil,
             networkAllowed: @escaping @Sendable () -> Bool) {
            self.allowedDomains = allowedDomains
            self.originURL = originURL
            self.originIsPrivate = originURL?.host.map(SourceDomainPolicy.isPrivateOrLoopbackHost) ?? false
            self.networkAllowed = networkAllowed
        }

        var violation: SourceDomainPolicy.Violation? { lock.withLock { rejectedRedirect } }

        func validate(_ request: URLRequest) throws {
            guard networkAllowed() else { throw SourceDomainPolicy.Violation.networkDisabled }
            guard let url = request.url else { throw SourceDomainPolicy.Violation.invalidURL("") }
            _ = try SourceDomainPolicy.validate(url: url, allowedDomains: allowedDomains)
        }

        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            do {
                try validate(request)
                if let targetURL = request.url,
                   let host = targetURL.host,
                   !originIsPrivate,
                   SourceDomainPolicy.isPrivateOrLoopbackHost(host) {
                    throw SourceDomainPolicy.Violation.disallowedDomain(host: host, allowed: allowedDomains)
                }
                var sanitized = request
                if let sourceURL = response.url ?? originURL,
                   let targetURL = sanitized.url,
                   !SourceDomainPolicy.isSameOrigin(sourceURL, as: targetURL),
                   let fields = sanitized.allHTTPHeaderFields {
                    let retained = PluginHTTPClient.headers(fields, from: sourceURL, to: targetURL)
                    for name in fields.keys where retained[name] == nil {
                        sanitized.setValue(nil, forHTTPHeaderField: name)
                    }
                    sanitized.httpShouldHandleCookies = false
                }
                completionHandler(sanitized)
            } catch let violation as SourceDomainPolicy.Violation {
                lock.withLock { rejectedRedirect = violation }
                completionHandler(nil)
            } catch {
                lock.withLock { rejectedRedirect = .invalidURL(request.url?.absoluteString ?? "") }
                completionHandler(nil)
            }
        }
    }
}
