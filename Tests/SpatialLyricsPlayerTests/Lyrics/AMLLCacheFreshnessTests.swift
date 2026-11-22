import XCTest
@testable import SpatialLyricsPlayer

/// 索引缓存的过期判断。
///
/// 这条逻辑原来和文件 I/O 缠在一起，覆盖率为 0，也从没测过边界。
/// 抽成纯函数后可以精确验证"恰好过期""时钟回拨"这些情况。
@MainActor
final class AMLLCacheFreshnessTests: XCTestCase {

    private let ttl: TimeInterval = 7 * 24 * 3600

    func testFreshWithinTTL() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let modified = now.addingTimeInterval(-ttl + 60)
        XCTAssertTrue(AMLLLyricsProvider.isCacheFresh(modified: modified, now: now, ttl: ttl))
    }

    func testExactlyAtTTLIsStale() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let modified = now.addingTimeInterval(-ttl)
        XCTAssertFalse(AMLLLyricsProvider.isCacheFresh(modified: modified, now: now, ttl: ttl),
                       "恰好到期的边界必须算过期，否则会一直用旧索引")
    }

    func testOlderThanTTLIsStale() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let modified = now.addingTimeInterval(-ttl - 1)
        XCTAssertFalse(AMLLLyricsProvider.isCacheFresh(modified: modified, now: now, ttl: ttl))
    }

    func testFutureTimestampCountsAsFresh() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let modified = now.addingTimeInterval(3600)   // 时钟回拨导致的"未来文件"
        XCTAssertTrue(AMLLLyricsProvider.isCacheFresh(modified: modified, now: now, ttl: ttl),
                      "未来时间戳不该触发重下 1.7MB")
    }

    func testZeroTTLAlwaysStale() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(AMLLLyricsProvider.isCacheFresh(modified: now.addingTimeInterval(-1), now: now, ttl: 0))
    }
}
