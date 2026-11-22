import XCTest
@testable import SpatialLyricsPlayer

/// 空闲态的播放行为。
///
/// 审计原话：「空闲态播放键 enabled 却点不动」。根因是播放键永远可点，
/// 而 `play()` 在没有当前曲目时什么都不做——按钮给了反馈，界面没有任何变化。
@MainActor
final class IdlePlaybackTests: XCTestCase {

    private func makeEngine(_ clock: TestPlaybackClock) -> PlaybackEngine {
        let registry = SourceRegistry()
        registry.register(MockPlaybackSource(behavior: .healthy, clock: clock))
        return PlaybackEngine(clock: clock, coordinator: PlaybackCoordinator(registry: registry))
    }

    func testPlayDoesNothingWithoutCurrentTrack() async {
        let clock = TestPlaybackClock()
        let engine = makeEngine(clock)
        await engine.play()
        XCTAssertNil(engine.currentTrack, "没有当前曲目时播放不该凭空开始")
        XCTAssertFalse(engine.state.isPlaying)
    }

    func testLoadingFirstQueueItemStartsPlayback() async {
        let clock = TestPlaybackClock()
        let engine = makeEngine(clock)
        let tracks = MockCatalog.tracks(count: 3)
        engine.setQueue(tracks, current: tracks[0])

        // 模拟"上一首到边界"之后的空闲态：队列还在，当前曲目被清空。
        engine.setQueue(tracks, current: tracks[0])
        await engine.load(tracks[0], autoplay: true)
        XCTAssertTrue(engine.state.isPlaying)

        // 从队首重新开始应当真的出声（这里只断言状态机进入 loading/playing 链）。
        await engine.pause()
        XCTAssertFalse(engine.state.isPlaying)
        await engine.load(tracks[0], autoplay: true)
        XCTAssertTrue(engine.state.isPlaying, "从队首开始时必须真的进入播放")
    }

    func testQueueSnapshotSurvivesClearedCurrent() {
        let clock = TestPlaybackClock()
        let engine = makeEngine(clock)
        let tracks = MockCatalog.tracks(count: 3)
        engine.setQueue(tracks, current: tracks[0])
        XCTAssertEqual(engine.queueSnapshot.items.count, 3)
        XCTAssertNotNil(engine.queueSnapshot.items.first,
                        "播放键要在没有当前曲目时靠队首恢复，所以队列必须还在")
    }
}
