import XCTest
@testable import SpatialLyricsPlayer

/// 播放内核端到端测试：真实 registry + coordinator + engine + 模拟源，只把时钟换成假的。
@MainActor
final class PlaybackEngineTests: XCTestCase {

    private func label(_ state: PlaybackState) -> String { state.debugLabel }

    func testLoadWithAutoplayReachesPlaying() async {
        let harness = EngineHarness()
        await harness.engine.load(harness.tracks[0], autoplay: true)

        XCTAssertEqual(harness.engine.state.debugLabel, "playing")
        XCTAssertEqual(harness.engine.currentTrack, harness.tracks[0])
        XCTAssertEqual(harness.coordinator.activeSourceID, .mock)
        XCTAssertEqual(harness.engine.duration, harness.tracks[0].duration, accuracy: 0.001)
    }

    func testLoadWithoutAutoplayStopsAtReady() async {
        let harness = EngineHarness()
        await harness.engine.load(harness.tracks[0], autoplay: false)

        XCTAssertEqual(harness.engine.state.debugLabel, "ready")
        XCTAssertEqual(harness.engine.position(at: harness.clock.now), 0, accuracy: 0.001)
    }

    func testPauseFreezesPositionAndResumeContinues() async {
        let harness = EngineHarness()
        await harness.engine.load(harness.tracks[0], autoplay: true)

        harness.clock.advance(by: .seconds(10))
        XCTAssertEqual(harness.engine.position(at: harness.clock.now), 10, accuracy: 0.001)

        await harness.engine.pause()
        XCTAssertEqual(harness.engine.state.debugLabel, "paused(user)")

        harness.clock.advance(by: .seconds(60))
        XCTAssertEqual(harness.engine.position(at: harness.clock.now), 10, accuracy: 0.001)

        await harness.engine.play()
        XCTAssertEqual(harness.engine.state.debugLabel, "playing")
        XCTAssertEqual(harness.engine.position(at: harness.clock.now), 10, accuracy: 0.001)

        harness.clock.advance(by: .seconds(5))
        XCTAssertEqual(harness.engine.position(at: harness.clock.now), 15, accuracy: 0.001)
    }

    func testSeekMovesPositionAndKeepsPlaying() async {
        let harness = EngineHarness()
        await harness.engine.load(harness.tracks[0], autoplay: true)

        await harness.engine.seek(to: 90)
        XCTAssertEqual(harness.engine.state.debugLabel, "playing")
        XCTAssertEqual(harness.engine.position(at: harness.clock.now), 90, accuracy: 0.001)
    }

    func testSkipAdvancesToNeighbour() async {
        let harness = EngineHarness()
        await harness.engine.load(harness.tracks[0], autoplay: true)
        await harness.engine.skip(.next)

        XCTAssertEqual(harness.engine.currentTrack, harness.tracks[1])
        XCTAssertEqual(harness.engine.state.debugLabel, "playing")
    }

    func testSkipAtQueueTailWithoutRepeatStops() async {
        let harness = EngineHarness()
        await harness.engine.load(harness.tracks[harness.tracks.count - 1], autoplay: true)
        await harness.engine.skip(.next)

        XCTAssertEqual(harness.engine.state.debugLabel, "idle")
        XCTAssertNil(harness.engine.currentTrack)
    }

    func testPermanentFailureEntersFailedWithMappedError() async {
        let harness = EngineHarness(behavior: .failing(.decodeFailed(reason: "boom")))
        await harness.engine.load(harness.tracks[0], autoplay: true)

        XCTAssertEqual(harness.engine.state.debugLabel, "failed(decodeFailed(reason: \"boom\"))")
        XCTAssertEqual(harness.engine.lastError, .decodeFailed(reason: "boom"))
    }

    func testTransientFailureRecoversAfterTwoRetries() async {
        let behavior = MockBehavior.failOnAttempts([1, 2], with: .decodeFailed(reason: "flaky"))
        let harness = EngineHarness(behavior: behavior)

        await harness.engine.load(harness.tracks[0], autoplay: true)
        XCTAssertEqual(harness.engine.state.debugLabel, "failed(decodeFailed(reason: \"flaky\"))")

        await harness.engine.dispatch(.retry)
        XCTAssertEqual(harness.engine.state.debugLabel, "failed(decodeFailed(reason: \"flaky\"))")

        await harness.engine.dispatch(.retry)
        XCTAssertEqual(harness.engine.state.debugLabel, "playing")
    }

    func testStopReturnsToIdle() async {
        let harness = EngineHarness()
        await harness.engine.load(harness.tracks[0], autoplay: true)
        await harness.engine.stop()

        XCTAssertEqual(harness.engine.state.debugLabel, "idle")
        XCTAssertFalse(harness.coordinator.hasSession)
    }

    func testRejectedEventsAreCountedNotCrashing() async {
        let harness = EngineHarness()
        await harness.engine.dispatch(.play)
        await harness.engine.dispatch(.seek(10))
        await harness.engine.dispatch(.stop)

        XCTAssertEqual(harness.engine.state.debugLabel, "idle")
        XCTAssertEqual(harness.engine.rejectedEventCount, 3)
    }

    func testPlaybackFinishedEntersEnded() async {
        let harness = EngineHarness()
        await harness.engine.load(harness.tracks[0], autoplay: true)
        harness.clock.advance(by: .seconds(5))
        await harness.engine.dispatch(.playbackFinished)

        XCTAssertEqual(harness.engine.state.debugLabel, "ended")
    }
}
