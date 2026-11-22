import XCTest
@testable import SpatialLyricsPlayer

// 队列的全部契约：入队/切歌/删除/在线与本地的混合队列。

@MainActor
final class PlaybackQueueTests: XCTestCase {

@MainActor

    private func makeEngine() -> PlaybackEngine {
        let clock = TestPlaybackClock()
        let registry = SourceRegistry()
        registry.register(MockPlaybackSource(behavior: .healthy, clock: clock))
        return PlaybackEngine(clock: clock, coordinator: PlaybackCoordinator(registry: registry))
    }

    func testRemoveDropsOneItemAndKeepsOrder() {
        let engine = makeEngine()
        let tracks = MockCatalog.tracks(count: 4)
        engine.setQueue(tracks, current: tracks[0])

        XCTAssertTrue(engine.removeQueueItem(at: 2))
        XCTAssertEqual(engine.queueSnapshot.items, [tracks[0].id, tracks[1].id, tracks[3].id])
        XCTAssertEqual(engine.currentTrack?.identity, tracks[0].identity, "删别的项不该影响当前曲目")
    }

    func testRemovingCurrentTrackIsRefused() {
        let engine = makeEngine()
        let tracks = MockCatalog.tracks(count: 3)
        engine.setQueue(tracks, current: tracks[1])

        let currentIndex = engine.queueSnapshot.items.firstIndex(of: tracks[1].id)!
        XCTAssertFalse(engine.removeQueueItem(at: currentIndex),
                       "正在播放的那项不能删：删了当前曲目会凭空消失，音频却还在响")
        XCTAssertTrue(engine.queueSnapshot.items.contains(tracks[1].id))
    }

    func testOutOfRangeIsNoOp() {
        let engine = makeEngine()
        let tracks = MockCatalog.tracks(count: 2)
        engine.setQueue(tracks, current: tracks[0])
        let before = engine.queueSnapshot.items

        XCTAssertFalse(engine.removeQueueItem(at: 99))
        XCTAssertEqual(engine.queueSnapshot.items, before)
    }

    private func ids(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    func testSequentialAdvance() {
        let list = ids(3)
        var queue = PlaybackQueue(items: list, currentID: list[0])

        XCTAssertEqual(queue.advance(), list[1])
        XCTAssertEqual(queue.advance(), list[2])
        XCTAssertNil(queue.advance(), "顺序模式到底应停下")
    }

    func testRepeatOneAllowsExplicitAdvance() {
        let list = ids(3)
        var queue = PlaybackQueue(items: list, currentID: list[1], repeatMode: .one)
        XCTAssertEqual(queue.advance(), list[2])
        XCTAssertNil(queue.advance())
        XCTAssertEqual(queue.repeatMode, .one)
    }

    func testRepeatAllWrapsAround() {
        let list = ids(3)
        var queue = PlaybackQueue(items: list, currentID: list[2], repeatMode: .all)
        XCTAssertEqual(queue.advance(), list[0])
    }

    func testRegressAtHeadNeedsRepeatAll() {
        let list = ids(3)
        var plain = PlaybackQueue(items: list, currentID: list[0])
        XCTAssertNil(plain.regress())

        var looping = PlaybackQueue(items: list, currentID: list[0], repeatMode: .all)
        XCTAssertEqual(looping.regress(), list[2])
    }

    func testNextUpIsLIFOAndTakesPriority() {
        let list = ids(3)
        let a = UUID(), b = UUID()
        var queue = PlaybackQueue(items: list, currentID: list[0])

        queue.enqueueNext(a)
        queue.enqueueNext(b)
        XCTAssertEqual(queue.advance(), b, "后插入的下一首应先播")
        XCTAssertEqual(queue.advance(), a)
        XCTAssertEqual(queue.advance(), list[1], "手动插播用完后回到正常顺序")
    }

    func testLaterIsFIFOAndYieldsToNextUp() {
        let list = ids(3)
        let a = UUID(), b = UUID(), manual = UUID()
        var queue = PlaybackQueue(items: list, currentID: list[0])

        queue.enqueueLater(a)
        queue.enqueueLater(b)
        queue.enqueueNext(manual)

        XCTAssertEqual(queue.advance(), manual)
        XCTAssertEqual(queue.advance(), a)
        XCTAssertEqual(queue.advance(), b)
    }

    func testClearLaterRemovesOnlyLater() {
        let list = ids(2)
        let manual = UUID()
        var queue = PlaybackQueue(items: list, currentID: list[0])
        queue.enqueueLater(manual)
        queue.enqueueNext(manual)

        queue.clearLater()
        XCTAssertEqual(queue.advance(), manual, "nextUp 不应被 clearLater 清掉")
    }

    func testShuffleDoesNotRepeatWithinCycle() {
        let list = ids(6)
        var queue = PlaybackQueue(items: list, currentID: list[0], repeatMode: .all, shuffleSeed: 42)

        var played: [UUID] = [list[0]]
        for _ in 0..<(list.count - 1) {
            guard let next = queue.advance() else { return XCTFail("循环模式下不应返回 nil") }
            played.append(next)
        }
        XCTAssertEqual(Set(played).count, list.count, "一轮内不得重复同一首")
    }

    func testShuffleIsDeterministicForSameSeed() {
        let list = ids(8)
        var a = PlaybackQueue(items: list, currentID: list[0], repeatMode: .all, shuffleSeed: 7)
        var b = PlaybackQueue(items: list, currentID: list[0], repeatMode: .all, shuffleSeed: 7)

        for _ in 0..<8 {
            XCTAssertEqual(a.advance(), b.advance(), "同 seed 必须得到同一序列")
        }
    }

    func testMoveReordersItems() {
        let list = ids(4)
        var queue = PlaybackQueue(items: list, currentID: list[0])
        queue.move(from: 3, to: 1)
        XCTAssertEqual(queue.items, [list[0], list[3], list[1], list[2]])
    }

    func testRemoveCurrentClearsCurrent() {
        let list = ids(3)
        var queue = PlaybackQueue(items: list, currentID: list[1])
        queue.remove(at: 1)
        XCTAssertNil(queue.currentID)
        XCTAssertEqual(queue.items.count, 2)
    }

    func testQueueCodableRoundTrip() throws {
        let list = ids(3)
        let manual = UUID()
        var queue = PlaybackQueue(items: list, currentID: list[0], repeatMode: .all, shuffleSeed: 5)
        queue.enqueueNext(manual)

        let data = try JSONEncoder().encode(queue)
        let restored = try JSONDecoder().decode(PlaybackQueue.self, from: data)
        XCTAssertEqual(restored, queue)
    }

    // MARK: - 清空待播

    /// 「清空待播」必须真的清掉屏幕上那一列。
    ///
    /// 旧实现只清 `later` 缓冲，而队列抽屉渲染的是 `items` —— 用户按下按钮，
    /// 列表一条没少、按钮也没反馈，看起来就像坏了。
    func testClearUpNextTruncatesAfterCurrent() {
        let list = ids(5)
        var queue = PlaybackQueue(items: list, currentID: list[1])

        XCTAssertTrue(queue.clearUpNext())

        XCTAssertEqual(queue.items, [list[0], list[1]], "当前曲目要留下，之后的全清掉")
        XCTAssertEqual(queue.currentID, list[1])
    }

    func testClearUpNextAlsoDropsManualBuffers() {
        let list = ids(3)
        var queue = PlaybackQueue(items: list, currentID: list[0])
        queue.enqueueNext(list[2])
        queue.enqueueLater(list[1])

        XCTAssertTrue(queue.clearUpNext())
        XCTAssertTrue(queue.nextUp.isEmpty, "「下一首播放」也要一起清")
        XCTAssertTrue(queue.later.isEmpty, "「稍后播放」也要一起清")
    }

    func testClearUpNextOnLastTrackReportsNoChange() {
        let list = ids(2)
        var queue = PlaybackQueue(items: list, currentID: list[1])

        XCTAssertFalse(queue.clearUpNext(), "后面本来就没有东西，不该报告为变化")
        XCTAssertEqual(queue.items, list, "没有可清的内容时不能动队列")
    }

    func testClearUpNextKeepsCurrentWhenItWasManuallyQueued() {
        // 手动插播：`nextUp` 里的那首就是当前曲目时，items 里可能没有它。
        let list = ids(3)
        var queue = PlaybackQueue(items: list, currentID: list[0])
        queue.enqueueNext(list[2])
        XCTAssertEqual(queue.advance(), list[2])

        queue.clearUpNext()
        XCTAssertEqual(queue.currentID, list[2], "当前曲目不能被清掉")
        XCTAssertTrue(queue.nextUp.isEmpty)
    }
}
