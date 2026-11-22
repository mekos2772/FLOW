import XCTest
@testable import SpatialLyricsPlayer

/// 最近搜索。
final class RecentSearchStoreTests: XCTestCase {

    private func makeStore() -> RecentSearchStore {
        let suite = "search.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return RecentSearchStore(defaults: defaults)
    }

    func testRecordMovesExistingToFrontWithoutDuplicating() {
        let store = makeStore()
        store.record("夜曲")
        store.record("稻香")
        store.record("夜曲")
        XCTAssertEqual(store.all, ["夜曲", "稻香"], "同一个词再搜一次应当提前，而不是出现两次")
    }

    func testTrimsAndIgnoresEmpty() {
        let store = makeStore()
        store.record("   晴天  ")
        store.record("   ")
        XCTAssertEqual(store.all, ["晴天"])
    }

    func testCapsAtLimit() {
        let store = makeStore()
        for index in 0..<12 { store.record("歌\(index)") }
        XCTAssertEqual(store.all.count, RecentSearchStore.limit)
        XCTAssertEqual(store.all.first, "歌11", "最新的在最前")
        XCTAssertFalse(store.all.contains("歌0"), "超出上限的旧词要被丢掉")
    }

    func testClearRemovesAllRecentSearches() {
        let store = makeStore()
        store.record("七里香")
        store.clear()
        XCTAssertTrue(store.all.isEmpty)
    }

    func testCaseInsensitiveDedupe() {
        let store = makeStore()
        store.record("Hello")
        store.record("hello")
        XCTAssertEqual(store.all, ["hello"], "大小写不同也算同一个词")
    }
}
