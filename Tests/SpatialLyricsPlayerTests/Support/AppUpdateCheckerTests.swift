import Foundation
import XCTest
@testable import SpatialLyricsPlayer

final class AppUpdateCheckerTests: XCTestCase {

    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) private static var requestCount = 0

        static func install(_ newHandler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
            lock.withLock {
                handler = newHandler
                requestCount = 0
            }
        }

        static func reset() {
            lock.withLock {
                handler = nil
                requestCount = 0
            }
        }

        static var recordedRequests: Int {
            lock.withLock { requestCount }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let currentHandler = Self.lock.withLock { () -> (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? in
                Self.requestCount += 1
                return Self.handler
            }
            guard let currentHandler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (response, data) = try currentHandler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testSemanticVersionComparisonHandlesMultiDigitAndPrerelease() throws {
        let v015 = try XCTUnwrap(SemanticVersion(rawValue: "0.1.5"))
        let v015Prefixed = try XCTUnwrap(SemanticVersion(rawValue: "v0.1.5"))
        let v0110 = try XCTUnwrap(SemanticVersion(rawValue: "v0.1.10"))
        let v020Beta = try XCTUnwrap(SemanticVersion(rawValue: "0.2.0-beta.1"))
        let v020 = try XCTUnwrap(SemanticVersion(rawValue: "0.2.0"))

        XCTAssertEqual(v015, v015Prefixed)
        XCTAssertLessThan(v015, v0110)
        XCTAssertLessThan(v0110, v020Beta)
        XCTAssertLessThan(v020Beta, v020)
        XCTAssertNil(SemanticVersion(rawValue: "invalid"))
    }

    @MainActor
    func testCheckForUpdatesDetectsNewerReleaseAndPicksArm64DMG() async {
        let json = """
        {
          "tag_name": "v0.2.0",
          "html_url": "https://github.com/mekos2772/FLOW/releases/tag/v0.2.0",
          "body": "## 更新亮点\\n- 新增在线检查更新\\n- 修复音频破音",
          "assets": [
            {
              "name": "FLOW-0.2.0-universal.zip",
              "browser_download_url": "https://github.com/mekos2772/FLOW/releases/download/v0.2.0/FLOW-0.2.0-universal.zip"
            },
            {
              "name": "FLOW-0.2.0-arm64.dmg",
              "browser_download_url": "https://github.com/mekos2772/FLOW/releases/download/v0.2.0/FLOW-0.2.0-arm64.dmg"
            }
          ]
        }
        """
        StubURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }

        let checker = AppUpdateChecker(
            currentVersionProvider: { "0.1.5" },
            networkAllowed: { true },
            session: makeStubSession()
        )
        await checker.checkForUpdates()

        guard case .updateAvailable(let info) = checker.state else {
            return XCTFail("Expected .updateAvailable, got \(checker.state)")
        }
        XCTAssertEqual(info.tagName, "v0.2.0")
        XCTAssertEqual(info.version, "0.2.0")
        XCTAssertEqual(info.releaseURL.absoluteString, "https://github.com/mekos2772/FLOW/releases/tag/v0.2.0")
        XCTAssertEqual(info.downloadURL?.absoluteString, "https://github.com/mekos2772/FLOW/releases/download/v0.2.0/FLOW-0.2.0-arm64.dmg")
        XCTAssertEqual(info.summary, "- 新增在线检查更新\n- 修复音频破音")
    }

    @MainActor
    func testCheckForUpdatesRejectsUntrustedDownloadAndReleaseHosts() async {
        let json = """
        {
          "tag_name": "v0.3.0",
          "html_url": "https://evil.example.com/phishing",
          "body": "",
          "assets": [
            {
              "name": "FLOW-0.3.0-arm64.dmg",
              "browser_download_url": "http://github.com/mekos2772/FLOW/releases/download/v0.3.0/FLOW-0.3.0-arm64.dmg"
            }
          ]
        }
        """
        StubURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }

        let checker = AppUpdateChecker(
            currentVersionProvider: { "0.1.5" },
            networkAllowed: { true },
            session: makeStubSession()
        )
        await checker.checkForUpdates()

        guard case .updateAvailable(let info) = checker.state else {
            return XCTFail("Expected .updateAvailable, got \(checker.state)")
        }
        XCTAssertEqual(info.releaseURL, AppUpdateChecker.releasesPageURL)
        XCTAssertNil(info.downloadURL)
    }

    @MainActor
    func testCheckForUpdatesReportsUpToDateWhenVersionMatches() async {
        let json = """
        {
          "tag_name": "v0.1.5",
          "html_url": "https://github.com/mekos2772/FLOW/releases/tag/v0.1.5",
          "assets": []
        }
        """
        StubURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }

        let checker = AppUpdateChecker(
            currentVersionProvider: { "0.1.5" },
            networkAllowed: { true },
            session: makeStubSession()
        )
        await checker.checkForUpdates()

        XCTAssertEqual(checker.state, .upToDate(currentVersion: "0.1.5"))
    }

    @MainActor
    func testCheckForUpdatesRespectsNetworkDisabledWithoutIssuingRequest() async {
        StubURLProtocol.install { request in
            XCTFail("Network is disabled; no request should be issued to \(request.url?.absoluteString ?? "")")
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let checker = AppUpdateChecker(
            currentVersionProvider: { "0.1.5" },
            networkAllowed: { false },
            session: makeStubSession()
        )
        await checker.checkForUpdates()

        XCTAssertEqual(StubURLProtocol.recordedRequests, 0)
        guard case .failed(let message) = checker.state else {
            return XCTFail("Expected .failed, got \(checker.state)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    @MainActor
    func testCheckForUpdatesHandlesRateLimitGracefully() async {
        StubURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: ["X-RateLimit-Remaining": "0"]
            )!
            return (response, Data("{\"message\":\"API rate limit exceeded\"}".utf8))
        }

        let checker = AppUpdateChecker(
            currentVersionProvider: { "0.1.5" },
            networkAllowed: { true },
            session: makeStubSession()
        )
        await checker.checkForUpdates()

        guard case .failed(let message) = checker.state else {
            return XCTFail("Expected .failed, got \(checker.state)")
        }
        XCTAssertTrue(message.contains("GitHub"))
    }
}
