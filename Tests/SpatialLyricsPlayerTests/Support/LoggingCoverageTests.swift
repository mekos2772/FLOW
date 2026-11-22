import XCTest
@testable import SpatialLyricsPlayer

/// 验证 `RedactingLog` 对敏感查询参数、用户主目录路径与长令牌的脱敏边界。
final class LoggingCoverageTests: XCTestCase {

    func testQueryStringIsRemoved() {
        let sanitized = RedactingLog.sanitize("https://api.example.com/x/player/v2?id=101&token=secret")
        XCTAssertFalse(sanitized.contains("token"))
        XCTAssertFalse(sanitized.contains("secret"))
        XCTAssertTrue(sanitized.contains("api.example.com") || sanitized.contains("<url>"))
    }

    func testUserHomePathIsCollapsed() {
        let sanitized = RedactingLog.sanitize("failed to open /Users/alice/Library/Application Support/x.store")
        XCTAssertFalse(sanitized.contains("alice"))
    }

    func testLongTokenIsTruncated() {
        let token = String(repeating: "abc123", count: 20)
        let sanitized = RedactingLog.sanitize("session=\(token)")
        XCTAssertLessThan(sanitized.count, token.count)
        XCTAssertFalse(sanitized.contains(token))
    }

    func testBenignMessageSurvives() {
        let message = "store restored from backup SpatialLyrics-1794745597.store"
        XCTAssertEqual(RedactingLog.sanitize(message), message)
    }
}
