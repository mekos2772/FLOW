import XCTest
@testable import SpatialLyricsPlayer

/// `.buffering` 的可达性与流式 stall 事件端到端映射。
///
/// 当播放流启用 `ProgressiveAudioStream` / `AVAssetResourceLoaderDelegate` 边下边播后，
/// 会话会在缓冲耗尽等待时发送 `.stalled(true)`，恢复播放后发送 `.stalled(false)`；
/// `PlaybackEngine` 将其映射为状态机的 `.stallBegan` / `.stallEnded`（`.playing` <-> `.buffering`），
/// `MorphPresentationModel.isBuffering` 与传输控制栏随之展示缓冲指示。
final class BufferingReachabilityTests: XCTestCase {

    func testStateMachineStillSupportsBuffering() {
        var machine = PlaybackStateMachine(now: .now)
        let track = Track(sourceID: SourceID(rawValue: "t"), externalID: "1",
                          title: "t", artist: "a", duration: 200)
        _ = machine.handle(.load(track, autoplay: false), now: .now)
        _ = machine.handle(.resourceReady(duration: 200), now: .now)
        _ = machine.handle(.play, now: .now)

        if case .playing = machine.state {
            _ = machine.handle(.stallBegan, now: .now)
            if case .buffering = machine.state {} else {
                XCTFail("九态机应当支持 buffering 通路（见 PlaybackStateMachine 注释）")
            }
            _ = machine.handle(.stallEnded, now: .now)
            if case .playing = machine.state {} else {
                XCTFail("缓冲结束后应回到 playing")
            }
        }
    }

    @MainActor
    func testSessionStallEventsDrivePlaybackEngineBufferingState() async throws {
        let source = GatedSource(id: SourceID("stream-test"))
        let registry = SourceRegistry()
        registry.register(source)
        let coordinator = PlaybackCoordinator(registry: registry)
        let engine = PlaybackEngine(clock: TestPlaybackClock(), coordinator: coordinator)
        let track = source.track("BV1stall01", duration: 120)
        engine.setQueue([track], current: track)

        await engine.load(track, autoplay: true)
        XCTAssertTrue(engine.state.isPlaying)
        let session = try XCTUnwrap(source.sessions(for: "BV1stall01").last)

        let model = MorphPresentationModel()
        session.emitStall(true)
        await waitUntil("进入 buffering") {
            if case .buffering = engine.state { return true }
            return false
        }
        model.state = engine.state
        XCTAssertTrue(model.isBuffering)

        session.emitStall(false)
        await waitUntil("恢复 playing") { engine.state.isPlaying }
        model.state = engine.state
        XCTAssertFalse(model.isBuffering)
    }
}
