import XCTest
@testable import SpatialLyricsPlayer

/// 「接下来」的顺序规则。
///
/// 之前是 `items.filter { $0 != currentID }`——排除了当前曲，却保留了它前面已播的。
/// 播到第 5 首时界面显示的是第 1 首，用户以为下一首是它。这里把正确顺序钉死。
final class UpNextPlannerTests: XCTestCase {

    private func queue(_ count: Int, current: Int?, nextUp: [Track.ID] = [], later: [Track.ID] = []) -> (PlaybackQueue, [Track.ID]) {
        let ids = (0..<count).map { _ in Track.ID() }
        let q = PlaybackQueue(items: ids, currentID: current.map { ids[$0] },
                              nextUp: nextUp, later: later)
        return (q, ids)
    }

    func testStartsAfterCurrent() {
        let (q, ids) = queue(5, current: 2)
        XCTAssertEqual(UpNextPlanner.upcoming(queue: q, currentID: ids[2]),
                       [ids[3], ids[4]],
                       "必须从当前曲之后开始，不能包含已播过的")
    }

    func testCurrentAtHead() {
        let (q, ids) = queue(3, current: 0)
        XCTAssertEqual(UpNextPlanner.upcoming(queue: q, currentID: ids[0]), [ids[1], ids[2]])
    }

    func testCurrentAtTail() {
        let (q, ids) = queue(3, current: 2)
        XCTAssertEqual(UpNextPlanner.upcoming(queue: q, currentID: ids[2]), [])
    }

    func testManualNextUpComesFirstReversed() {
        let (base, ids) = queue(3, current: 0)
        var q = base
        q.enqueueNext(ids[2])
        q.enqueueNext(ids[1])   // 后点的先播
        XCTAssertEqual(UpNextPlanner.upcoming(queue: q, currentID: ids[0]),
                       [ids[1], ids[2]],
                       "手动插播按后进先出排在最前；同一首不会预告两遍（实际也只播一遍）")
    }

    /// 预告的顺序必须就是实际播出的顺序——随机播放时也一样。
    func testPreviewMatchesWhatActuallyPlaysWhenShuffling() {
        let ids = (0..<8).map { _ in Track.ID() }
        let q = PlaybackQueue(items: ids, currentID: ids[0], shuffleSeed: 42)
        let preview = UpNextPlanner.upcoming(queue: q, currentID: ids[0])

        var live = q
        var played: [Track.ID] = []
        while let next = live.advance() { played.append(next) }

        XCTAssertEqual(preview, played)
        XCTAssertEqual(Set(preview).count, 7, "一轮内每首只出现一次")
    }

    func testRepeatAllStopsAfterOneLap() {
        let ids = (0..<3).map { _ in Track.ID() }
        let q = PlaybackQueue(items: ids, currentID: ids[1], repeatMode: .all)
        XCTAssertEqual(UpNextPlanner.upcoming(queue: q, currentID: ids[1]), [ids[2], ids[0]],
                       "列表循环：预告绕回来的那一圈，但不无限重复")
    }

    func testRepeatOneStillShowsTheQueue() {
        let ids = (0..<3).map { _ in Track.ID() }
        let q = PlaybackQueue(items: ids, currentID: ids[0], repeatMode: .one)
        XCTAssertEqual(UpNextPlanner.upcoming(queue: q, currentID: ids[0]), [ids[1], ids[2]])
    }

    func testLimitCapsThePreview() {
        let ids = (0..<10).map { _ in Track.ID() }
        let q = PlaybackQueue(items: ids, currentID: ids[0])
        XCTAssertEqual(UpNextPlanner.upcoming(queue: q, currentID: ids[0], limit: 3), Array(ids[1...3]))
    }

    func testNoCurrentFallsBackToWholeQueue() {
        let (q, ids) = queue(2, current: nil)
        XCTAssertEqual(UpNextPlanner.upcoming(queue: q, currentID: nil), ids)
    }
}
