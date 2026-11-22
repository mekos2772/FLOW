import XCTest
@testable import SpatialLyricsPlayer

/// 设置页的「循环模式 / 随机播放」是两个**真控件**，不是只读文字。
///
/// 之前那里只有一句「单曲循环」，而播放条上是连点轮转——想直接从列表选一种没有入口。
/// 下拉要能精确设定，所以引擎补了 `setRepeatMode(_:)` / `setShuffling(_:)`。
@MainActor
final class RepeatModeSettingTests: XCTestCase {

    func testSetRepeatModeIsIdempotentAndExact() {
        let harness = EngineHarness()
        harness.engine.setRepeatMode(.all)
        XCTAssertEqual(harness.engine.queueSnapshot.repeatMode, .all)

        harness.engine.setRepeatMode(.all)
        XCTAssertEqual(harness.engine.queueSnapshot.repeatMode, .all, "重复设定同一值不该有副作用")

        harness.engine.setRepeatMode(.one)
        XCTAssertEqual(harness.engine.queueSnapshot.repeatMode, .one, "要能直接跳到任意档，而不是只能轮转")
    }

    func testSetShufflingTogglesSeed() {
        let harness = EngineHarness()
        XCTAssertFalse(harness.engine.queueSnapshot.isShuffling)

        harness.engine.setShuffling(true)
        XCTAssertTrue(harness.engine.queueSnapshot.isShuffling)
        XCTAssertNotNil(harness.engine.queueSnapshot.shuffleSeed)

        harness.engine.setShuffling(false)
        XCTAssertFalse(harness.engine.queueSnapshot.isShuffling)
        XCTAssertNil(harness.engine.queueSnapshot.shuffleSeed, "关掉随机要清掉种子，否则下次行为不可复现")
    }
}
