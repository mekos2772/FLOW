import XCTest
@testable import SpatialLyricsPlayer

/// 大体量队列。
///
/// 重度用户会把几百首加进队列。这条检查的是"结构在规模下仍然正确"，
/// 而不是性能数字：顺序不能乱、当前曲目不能丢、`next/later` 不能被截断。
final class QueueScaleTests: XCTestCase {

    private func ids(_ count: Int) -> [Track.ID] {
        (0..<count).map { _ in Track.ID() }
    }

    func testLargeQueueKeepsOrderAndCurrent() {
        let all = ids(500)
        var queue = PlaybackQueue(items: all, currentID: all[250])
        queue.setCurrent(all[250])

        XCTAssertEqual(queue.items.count, 500)
        XCTAssertEqual(queue.items, all, "顺序必须原样保留")
        XCTAssertEqual(queue.currentID, all[250])
    }

    /// 500 首移动一项：只应改变顺序，不能丢项。
    func testMovingItemAtScaleKeepsCount() {
        var queue = PlaybackQueue(items: ids(500))
        let before = queue.items.count
        queue.move(from: 10, to: 480)
        XCTAssertEqual(queue.items.count, before, "移动不能丢项")
        XCTAssertEqual(Set(queue.items).count, before, "也不能产生重复")
    }

    /// 编解码：一次存 500 个身份键，往返后一个不丢。
    func testPersistedPayloadRoundTripsAtScale() throws {
        let keys = (0..<500).map { "local::item-\($0)" }
        let payload = try JSONEncoder().encode(keys)
        XCTAssertLessThan(payload.count, 64 * 1024, "500 个键不该膨胀到几十 KB 以上")

        let restored = try JSONDecoder().decode([String].self, from: payload)
        XCTAssertEqual(restored, keys)
    }
}
