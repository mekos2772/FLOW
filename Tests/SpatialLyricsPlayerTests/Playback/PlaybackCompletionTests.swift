import XCTest
@testable import SpatialLyricsPlayer

/// 曲目边界行为：上一首的重播规则、自然播完之后的去向。
///
/// 这三条都是"用户会立刻感知到"的路径：
/// - 播过 3 秒按上一首应该重头播，而不是跳到上一首；
/// - 队首按上一首不该把当前曲目丢掉（旧实现会 `dispatch(.stop)` 直接退回首页）；
/// - 一首放完要按播放模式续播，而不是停在 `.playing` 让进度冻死。
@MainActor
final class PlaybackCompletionTests: XCTestCase {

    private func label(_ state: PlaybackState) -> String { state.debugLabel }

    /// 轮询等待异步条件成立：会话事件走的是独立 Task，断言前必须让它有机会跑。
    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 2,
                           _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let ok = await condition()
        XCTAssertTrue(ok, "等待超时：\(description)")
    }

    private func forceEnd(_ harness: EngineHarness) async {
        guard let session = harness.coordinator.session as? MockPlaybackSession else {
            return XCTFail("模拟会话缺失，无法制造自然播完")
        }
        await session.forceEnd()
    }

    // MARK: - 上一首

    func testPreviousRestartsCurrentTrackPastThreeSeconds() async {
        let harness = EngineHarness()
        await harness.engine.load(harness.tracks[1], autoplay: true)

        harness.clock.advance(by: .seconds(10))
        await harness.engine.skip(.previous)

        XCTAssertEqual(harness.engine.currentTrack?.id, harness.tracks[1].id,
                       "播过 3 秒按上一首应该重头播本曲，不该换曲目")
        XCTAssertEqual(harness.engine.position(at: harness.clock.now), 0, accuracy: 0.5)
        XCTAssertEqual(label(harness.engine.state), "playing")
    }

    func testPreviousAtQueueHeadRestartsInsteadOfClearing() async {
        let harness = EngineHarness()
        await harness.engine.load(harness.tracks[0], autoplay: true)

        // 队首 + 位置 0：旧实现会走 requestNeighbor 的 nil 分支直接 stop，曲目被清空。
        await harness.engine.skip(.previous)

        XCTAssertEqual(harness.engine.currentTrack?.id, harness.tracks[0].id,
                       "队首按上一首不该把当前曲目丢掉")
        XCTAssertNotEqual(label(harness.engine.state), "idle")
    }

    func testPreviousGoesBackWithinThreeSeconds() async {
        let harness = EngineHarness()
        await harness.engine.load(harness.tracks[1], autoplay: true)

        await harness.engine.skip(.previous)

        XCTAssertEqual(harness.engine.currentTrack?.id, harness.tracks[0].id,
                       "刚开播就按上一首应该回到上一首")
    }

    /// 失败态按上一首：音频资源已经 release，不能走 seek——整轨重载从头再播。
    func testPreviousOnFailedTrackReloadsFromStart() async {
        let rig = GatedEngine()
        let track = rig.source.track("t1", duration: 180)
        rig.engine.setQueue([track])
        rig.source.failNextPrepares(with: [.sourceUnavailable])
        await rig.engine.load(track, autoplay: true)
        XCTAssertNotNil(rig.engine.state.error, "装载失败要先进入 failed")
        rig.clock.advance(by: .seconds(10))

        await rig.engine.skip(.previous)

        // 重载成功（这次 prepare 不再失败）：回到同一首的 0 位置开始播。
        await waitUntil("重载后开始播") { rig.engine.state.isPlaying }
        XCTAssertEqual(rig.engine.currentTrack?.id, track.id)
        XCTAssertEqual(rig.engine.position(at: rig.clock.now), 0, accuracy: 0.5)
    }

    func testPreviousOnEndedTrackReplaysFromStart() async {
        let harness = EngineHarness()
        // 只放一首：没有下一首可续，才会停在 ended。
        harness.engine.restoreRepeatMode(.off, shuffleSeed: nil)
        harness.engine.setQueue([harness.tracks[0]])
        await harness.engine.load(harness.tracks[0], autoplay: true)
        await forceEnd(harness)
        await waitUntil("进入 ended") { label(harness.engine.state) == "ended" }

        await harness.engine.skip(.previous)

        XCTAssertEqual(harness.engine.currentTrack?.id, harness.tracks[0].id)
        XCTAssertEqual(harness.engine.position(at: harness.clock.now), 0, accuracy: 0.5)
        XCTAssertEqual(label(harness.engine.state), "playing")
    }

    // MARK: - 自然播完

    func testPlaybackFinishedAdvancesToNextTrack() async {
        let harness = EngineHarness()
        harness.engine.restoreRepeatMode(.off, shuffleSeed: nil)
        await harness.engine.load(harness.tracks[0], autoplay: true)

        await forceEnd(harness)
        await waitUntil("切到下一首并开始播") {
            harness.engine.currentTrack?.id == harness.tracks[1].id
                && label(harness.engine.state) == "playing"
        }

        XCTAssertEqual(harness.engine.currentTrack?.id, harness.tracks[1].id)
        XCTAssertEqual(label(harness.engine.state), "playing")
    }

    func testPlaybackFinishedRepeatsSameTrackOnRepeatOne() async {
        let harness = EngineHarness()
        harness.engine.restoreRepeatMode(.one, shuffleSeed: nil)
        await harness.engine.load(harness.tracks[0], autoplay: true)

        await forceEnd(harness)
        await waitUntil("单曲循环重播") {
            label(harness.engine.state) == "playing"
                && harness.engine.position(at: harness.clock.now) < 1
        }

        XCTAssertEqual(harness.engine.currentTrack?.id, harness.tracks[0].id)
        XCTAssertEqual(label(harness.engine.state), "playing")
    }

    func testPlaybackFinishedStopsAtEndOfQueueWithoutRepeat() async {
        let harness = EngineHarness()
        harness.engine.restoreRepeatMode(.off, shuffleSeed: nil)
        harness.engine.setQueue([harness.tracks[0]])
        await harness.engine.load(harness.tracks[0], autoplay: true)

        await forceEnd(harness)
        await waitUntil("停在 ended") { label(harness.engine.state) == "ended" }

        XCTAssertEqual(label(harness.engine.state), "ended")
        XCTAssertEqual(harness.engine.currentTrack?.id, harness.tracks[0].id,
                       "队列到头应停在当前曲目上，不该被清空")
    }

    func testPlayFromEndedRestartsTrack() async {
        let harness = EngineHarness()
        harness.engine.restoreRepeatMode(.off, shuffleSeed: nil)
        harness.engine.setQueue([harness.tracks[0]])
        await harness.engine.load(harness.tracks[0], autoplay: true)
        await forceEnd(harness)
        await waitUntil("停在 ended") { label(harness.engine.state) == "ended" }

        await harness.engine.play()

        XCTAssertEqual(label(harness.engine.state), "playing")
        XCTAssertEqual(harness.engine.position(at: harness.clock.now), 0, accuracy: 0.5,
                       "在 ended 上按播放应该从头再来")
    }
}
