import XCTest
@testable import SpatialLyricsPlayer

/// 播放模式变化必须走状态广播——否则不持久化。
///
/// 实测：先切到"列表循环"，退出再打开，又变回"顺序播放"。
/// 根因是 `cycleRepeatMode()` / `toggleShuffle()` 只改了内存里的 `queue`，
/// 没有 `broadcastState()`——而持久化、控制中心、队列界面都订阅那条流。
@MainActor
final class PlaybackModeBroadcastTests: XCTestCase {

    private func makeEngine() -> PlaybackEngine {
        let registry = SourceRegistry()
        let clock = TestPlaybackClock()
        registry.register(MockPlaybackSource(behavior: .healthy, clock: clock))
        return PlaybackEngine(clock: clock, coordinator: PlaybackCoordinator(registry: registry))
    }

    func testCycleRepeatModeEmitsStateUpdate() async {
        let engine = makeEngine()
        let expectation = expectation(description: "repeat broadcast")
        let task = Task {
            for await _ in engine.stateUpdates() {
                expectation.fulfill()
                break
            }
        }
        try? await Task.sleep(for: .milliseconds(50))

        engine.cycleRepeatMode()
        await fulfillment(of: [expectation], timeout: 1)
        task.cancel()
        XCTAssertEqual(engine.queueSnapshot.repeatMode, .one)
    }

    func testToggleShuffleEmitsStateUpdate() async {
        let engine = makeEngine()
        let expectation = expectation(description: "shuffle broadcast")
        let task = Task {
            for await _ in engine.stateUpdates() {
                expectation.fulfill()
                break
            }
        }
        try? await Task.sleep(for: .milliseconds(50))

        engine.toggleShuffle()
        await fulfillment(of: [expectation], timeout: 1)
        task.cancel()
        XCTAssertTrue(engine.queueSnapshot.isShuffling)
    }

    /// 恢复持久化的播放模式时也要广播——否则界面标签停在默认值。
    func testRestoreRepeatModeEmitsStateUpdate() async {
        let engine = makeEngine()
        let expectation = expectation(description: "restore broadcast")
        let task = Task {
            for await _ in engine.stateUpdates() {
                expectation.fulfill()
                break
            }
        }
        try? await Task.sleep(for: .milliseconds(50))

        engine.restoreRepeatMode(.one, shuffleSeed: nil)
        await fulfillment(of: [expectation], timeout: 1)
        task.cancel()
        XCTAssertEqual(engine.queueSnapshot.repeatMode, .one)
    }
}
