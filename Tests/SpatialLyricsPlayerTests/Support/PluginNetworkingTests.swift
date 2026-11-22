import Foundation
import Network
import XCTest
@testable import SpatialLyricsPlayer

final class PluginNetworkingTests: XCTestCase {
    /// Real HTTP redirects exercise URLSession's delegate and prove that rejected targets are not contacted.
    private final class HTTPServer: @unchecked Sendable {
        struct Request: Sendable {
            let path: String
            let method: String
            let host: String
        }
        struct Reply: Sendable {
            var status = 200
            var body = "[]"
            var location: String?
        }
        private let listener: NWListener
        private let queue = DispatchQueue(label: "plugin-redirect-tests")
        private let lock = NSLock()
        private var requests: [Request] = []
        private var connections: [NWConnection] = []
        private var handler: @Sendable (Request) -> Reply = { _ in Reply(status: 404) }

        private init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }

        static func start() async throws -> HTTPServer {
            let server = try HTTPServer()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                server.listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        server.listener.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed(let error):
                        server.listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
                server.listener.newConnectionHandler = { [weak server] connection in
                    guard let server else { connection.cancel(); return }
                    server.lock.withLock { server.connections.append(connection) }
                    connection.start(queue: server.queue)
                    server.receive(connection, buffer: Data())
                }
                server.listener.start(queue: server.queue)
            }
            return server
        }

        func url(_ path: String, host: String = "localhost") -> URL {
            URL(string: "http://\(host):\(listener.port!.rawValue)\(path)")!
        }

        func configure(_ handler: @escaping @Sendable (Request) -> Reply) {
            lock.withLock {
                self.handler = handler
                requests = []
            }
        }

        var receivedRequests: [Request] { lock.withLock { requests } }

        func stop() {
            listener.cancel()
            let connections = lock.withLock { self.connections }
            for connection in connections { connection.cancel() }
        }

        private func receive(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                    if !complete, error == nil, buffer.count < 16_384 {
                        self.receive(connection, buffer: buffer)
                    } else { connection.cancel() }
                    return
                }
                let lines = text.components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                guard first.count >= 2 else { connection.cancel(); return }
                let host = lines.first { $0.lowercased().hasPrefix("host:") }?
                    .dropFirst(5).trimmingCharacters(in: .whitespaces) ?? ""
                let request = Request(path: String(first[1]), method: String(first[0]), host: host)
                let handler = self.lock.withLock {
                    self.requests.append(request)
                    return self.handler
                }
                let reply = handler(request)
                let body = Data(reply.body.utf8)
                let location = reply.location.map { "Location: \($0)\r\n" } ?? ""
                var response = Data("HTTP/1.1 \(reply.status) Test\r\n\(location)Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private final class NetworkPermission: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = true
        var isEnabled: Bool { lock.withLock { enabled } }
        func disable() { lock.withLock { enabled = false } }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }

    private func makeRuntime(session: URLSession,
                             networkAllowed: @escaping @Sendable () -> Bool = { true }) throws -> JSPluginRuntime {
        try JSPluginRuntime(scriptSource: """
            module.exports = {
                id: "redirect-security-test",
                allowedDomains: ["localhost"],
                async search(url) { return (await flow.request({url: url})).data; }
            };
            """, session: session, secrets: InMemorySecretStore(), networkAllowed: networkAllowed)
    }

    func testJSRejectsRedirectBeforeContactingDisallowedHost() async throws {
        let server = try await HTTPServer.start()
        defer { server.stop() }
        server.configure { _ in .init(status: 302, location: server.url("/secret", host: "127.0.0.1").absoluteString) }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let runtime = try makeRuntime(session: session)
        defer { runtime.invalidate() }
        do {
            _ = try await runtime.call("search", args: [server.url("/start").absoluteString])
            XCTFail("A redirect outside the plugin allowlist must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("127.0.0.1"), "Unexpected error: \(error)")
        }
        XCTAssertEqual(server.receivedRequests.map(\.path), ["/start"])
    }

    func testEveryRedirectHopIsValidatedForAllRedirectStatuses() async throws {
        let server = try await HTTPServer.start()
        defer { server.stop() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        for status in [301, 302, 303, 307, 308] {
            server.configure { request in
                .init(status: status, location: request.path.hasPrefix("/start-") ? "/second-\(status)" : server.url("/secret", host: "127.0.0.1").absoluteString)
            }
            var request = URLRequest(url: server.url("/start-\(status)"))
            request.httpMethod = "POST"
            request.httpBody = Data("payload".utf8)
            do {
                _ = try await PluginHTTPClient.data(for: request, session: session,
                                                    allowedDomains: ["localhost"], networkAllowed: { true })
                XCTFail("The second redirect must be checked for HTTP \(status)")
            } catch let violation as SourceDomainPolicy.Violation {
                guard case .disallowedDomain(let host, _) = violation else {
                    XCTFail("Unexpected policy failure: \(violation)")
                    continue
                }
                XCTAssertEqual(host, "127.0.0.1")
            }
            XCTAssertEqual(server.receivedRequests.map(\.path), ["/start-\(status)", "/second-\(status)"])
            XCTAssertEqual(server.receivedRequests.last?.method, [301, 302, 303].contains(status) ? "GET" : "POST")
        }
    }

    func testRelativeRedirectsSucceed() async throws {
        let server = try await HTTPServer.start()
        defer { server.stop() }
        server.configure { request in
            request.path == "/start" ? .init(status: 302, location: "/result") : .init(body: #"[{"id":"1","title":"Redirected"}]"#)
        }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let runtime = try makeRuntime(session: session)
        defer { runtime.invalidate() }
        let result = try await runtime.call("search", args: [server.url("/start").absoluteString]) as? [[String: Any]]
        XCTAssertEqual(result?.first?["title"] as? String, "Redirected")
        XCTAssertEqual(server.receivedRequests.map(\.path), ["/start", "/result"])
    }

    func testEmptyAndStarDomainRulesStillAllowCrossHostRedirects() async throws {
        let server = try await HTTPServer.start()
        defer { server.stop() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        for domains in [[], ["*"], ["  "]] as [[String]] {
            server.configure { request in
                request.path == "/start"
                    ? .init(status: 302, location: server.url("/result", host: "127.0.0.1").absoluteString)
                    : .init(body: "ok")
            }
            let (data, _) = try await PluginHTTPClient.data(
                for: URLRequest(url: server.url("/start")), session: session,
                allowedDomains: domains, networkAllowed: { true }
            )
            XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
            XCTAssertEqual(server.receivedRequests.map(\.path), ["/start", "/result"])
            XCTAssertTrue(server.receivedRequests.last!.host.hasPrefix("127.0.0.1:"))
        }
    }

    func testDelegateRejectsSchemesAndHonorsWildcardRules() throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let response = HTTPURLResponse(url: URL(string: "https://allowed.test/start")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let task = session.dataTask(with: response.url!)
        defer { task.cancel() }
        let cases: [(String, [String], Bool)] = [
            ("file:///etc/passwd", [], false),
            ("ftp://allowed.test/data", ["*"], false),
            ("https://edge.media.test/end", ["*.media.test"], true),
            ("https://media.test/end", ["*.media.test"], true),
            ("https://media.test.evil.test/end", ["*.media.test"], false),
            ("https://evilmedia.test/end", ["*.media.test"], false)
        ]
        for (target, domains, allowed) in cases {
            let validator = PluginHTTPClient.RedirectValidator(allowedDomains: domains, networkAllowed: { true })
            validator.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                 newRequest: URLRequest(url: URL(string: target)!)) { request in
                XCTAssertEqual(request != nil, allowed, target)
            }
            XCTAssertEqual(validator.violation == nil, allowed, target)
        }
    }

    func testNetworkPermissionIsRecheckedBeforeFollowingRedirect() async throws {
        let permission = NetworkPermission()
        let server = try await HTTPServer.start()
        defer { server.stop() }
        server.configure { _ in
            permission.disable()
            return .init(status: 302, location: "/result")
        }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let runtime = try makeRuntime(session: session, networkAllowed: { permission.isEnabled })
        defer { runtime.invalidate() }
        do {
            _ = try await runtime.call("search", args: [server.url("/start").absoluteString])
            XCTFail("Networking disabled during a redirect must fail")
        } catch let error as PlaybackError {
            XCTAssertEqual(error, .networkDisabled)
        }
        XCTAssertEqual(server.receivedRequests.count, 1)
    }

    func testInvalidInitialURLAndDisabledNetworkNeverCreateRequests() async throws {
        let server = try await HTTPServer.start()
        defer { server.stop() }
        server.configure { _ in .init() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        for (url, enabled) in [(server.url("/start", host: "127.0.0.1"), true), (URL(string: "file:///etc/passwd")!, true), (server.url("/start"), false)] {
            do {
                _ = try await PluginHTTPClient.data(
                    for: URLRequest(url: url), session: session,
                    allowedDomains: ["localhost"], networkAllowed: { enabled }
                )
                XCTFail("The initial request must be rejected")
            } catch is SourceDomainPolicy.Violation {
                // Expected before URLSession starts a task.
            }
        }
        XCTAssertTrue(server.receivedRequests.isEmpty)
    }

    func testJSONTemplateSearchResolveArtworkAndLyricsRejectRedirects() async throws {
        let server = try await HTTPServer.start()
        defer { server.stop() }
        server.configure { request in
            if request.path == "/catalog" {
                return .init(body: """
                    [{"id":"1","title":"Song","artist":"Artist","lyrics":"\(server.url("/custom-lyrics").absoluteString)"}]
                    """)
            }
            return .init(status: 302, location: server.url("/secret", host: "127.0.0.1").absoluteString)
        }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let source = JSONTemplateSource(definition: JSONTemplateDefinition(
            id: "redirect-json", name: "Redirect JSON", allowedDomains: ["localhost"],
            search: .init(url: server.url("/search").absoluteString),
            discover: .init(url: server.url("/discover").absoluteString),
            resolve: .init(url: server.url("/resolve").absoluteString),
            lyrics: .init(url: server.url("/lyrics").absoluteString)
        ), session: session)
        let track = Track(sourceID: source.descriptor.id, externalID: "1", title: "Song", artist: "Artist", duration: 1)
        let actions: [() async throws -> Void] = [
            { _ = try await source.search(SearchRequest(query: "test")) },
            { _ = try await source.discoverTracks(limit: 1, progress: nil) },
            { _ = try await source.makeSession(for: track) },
            { _ = try await source.artwork(for: ArtworkReference(.remote(server.url("/art")))) },
            { _ = try await source.lyrics(for: track) }
        ]
        for action in actions {
            do {
                try await action()
                XCTFail("All JSON template networking must reject disallowed redirects")
            } catch let violation as SourceDomainPolicy.Violation {
                guard case .disallowedDomain = violation else {
                    return XCTFail("Unexpected policy failure: \(violation)")
                }
            }
        }
        // Both raw-text paths: a configured endpoint and a per-track lyrics URL.
        for customURL in [false, true] {
            let lyricsSource = JSONTemplateSource(definition: JSONTemplateDefinition(
                id: "redirect-json", name: "Redirect JSON", allowedDomains: ["localhost"],
                search: .init(url: server.url("/catalog").absoluteString, fields: .init(lyricsUrl: customURL ? "lyrics" : nil)),
                lyrics: .init(url: server.url("/lyrics").absoluteString, textPath: nil)
            ), session: session)
            let tracks = try await lyricsSource.search(SearchRequest(query: "test"))
            do {
                _ = try await lyricsSource.lyrics(for: XCTUnwrap(tracks.first))
                XCTFail("Text lyrics redirects must also be checked")
            } catch let violation as SourceDomainPolicy.Violation {
                guard case .disallowedDomain = violation else {
                    return XCTFail("Unexpected policy failure: \(violation)")
                }
            }
        }
        XCTAssertFalse(server.receivedRequests.contains { $0.path == "/secret" })
        XCTAssertTrue(server.receivedRequests.contains { $0.path == "/custom-lyrics" })
    }

    func testJSArtworkRejectsRedirect() async throws {
        let server = try await HTTPServer.start()
        defer { server.stop() }
        server.configure { _ in .init(status: 302, location: server.url("/secret", host: "127.0.0.1").absoluteString) }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let source = try JSPluginSource(scriptSource: """
            module.exports = {id: "art-test", allowedDomains: ["localhost"], search() { return []; }};
            """, session: session, secrets: InMemorySecretStore())
        defer { source.runtime.invalidate() }
        do {
            _ = try await source.artwork(for: ArtworkReference(.remote(server.url("/art"))))
            XCTFail("JS source artwork must validate redirects")
        } catch let violation as SourceDomainPolicy.Violation {
            guard case .disallowedDomain = violation else {
                return XCTFail("Unexpected policy failure: \(violation)")
            }
        }
        XCTAssertEqual(server.receivedRequests.map(\.path), ["/art"])
    }
}
