import XCTest
@testable import SpatialLyricsPlayer

@MainActor
final class VolumeTests: XCTestCase {

    private func makeEngine() -> PlaybackEngine {
        let clock = TestPlaybackClock()
        let registry = SourceRegistry()
        registry.register(MockPlaybackSource(behavior: .healthy, clock: clock))
        return PlaybackEngine(clock: clock, coordinator: PlaybackCoordinator(registry: registry))
    }

    func testVolumeIsClamped() {
        let engine = makeEngine()
        engine.setVolume(1.8)
        XCTAssertEqual(engine.volume, 1, accuracy: 0.001)
        engine.setVolume(-0.5)
        XCTAssertEqual(engine.volume, 0, accuracy: 0.001)
        XCTAssertTrue(engine.isMuted, "音量为 0 即静音")
    }

    func testMuteTogglesWithoutLosingVolume() {
        let engine = makeEngine()
        engine.setVolume(0.6)
        engine.toggleMute()
        XCTAssertTrue(engine.isMuted)
        XCTAssertEqual(engine.volume, 0.6, accuracy: 0.001, "静音不应抹掉用户音量")
        engine.toggleMute()
        XCTAssertFalse(engine.isMuted)
    }

    func testResetToZeroClearsMuteOnRaisingVolume() {
        let engine = makeEngine()
        engine.setVolume(0)
        XCTAssertTrue(engine.isMuted)
        engine.setVolume(0.4)
        XCTAssertFalse(engine.isMuted)
    }
}

/// 静音不得成为"丢失音量"的单向门。
///
/// 现场事故：拖到 56% → 点静音 → 点取消静音，音量变成 0%，
/// 而且 0 被 `setEngineVolume` 写进磁盘，此后每次冷启动都是"默认音量 0%"。
@MainActor
final class VolumeMuteRestoreTests: XCTestCase {

    private func makeEngine() -> PlaybackEngine {
        let clock = TestPlaybackClock()
        let registry = SourceRegistry()
        registry.register(MockPlaybackSource(behavior: .healthy, clock: clock))
        return PlaybackEngine(clock: clock, coordinator: PlaybackCoordinator(registry: registry))
    }

    func testMuteKeepsLevelAndUnmuteRestoresIt() {
        let engine = makeEngine()
        engine.setVolume(0.56)

        engine.toggleMute()
        XCTAssertTrue(engine.isMuted)
        XCTAssertEqual(engine.volume, 0.56, accuracy: 0.001, "静音不该改动音量本身")

        engine.toggleMute()
        XCTAssertFalse(engine.isMuted)
        XCTAssertEqual(engine.volume, 0.56, accuracy: 0.001, "取消静音必须回到静音前的音量")
    }

    func testUnmuteAfterVolumeWasZeroedRestoresAudibleLevel() {
        let engine = makeEngine()
        engine.setVolume(0.56)
        engine.toggleMute()
        // 静音之后滑块被程序同步写成 0，等价于再调一次 setVolume(0)。
        engine.setVolume(0)
        XCTAssertTrue(engine.isMuted)

        engine.toggleMute()

        XCTAssertFalse(engine.isMuted)
        XCTAssertEqual(engine.volume, 0.56, accuracy: 0.001,
                       "音量被写成 0 后取消静音，应恢复到最后一次听得见的音量，而不是 0.001")
    }
}
