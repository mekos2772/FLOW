import XCTest
@testable import SpatialLyricsPlayer

// 睡眠定时器的全部契约：倒计时、到点暂停、淡出、UI 分钟数。

@MainActor
final class SleepTimerTests: XCTestCase {

    private let origin = ContinuousClock().now

    func testArmedTimerReportsFullRemainingTime() {
        var timer = SleepTimer()
        timer.arm(for: .seconds(1800), now: origin)

        XCTAssertEqual(timer.remaining(at: origin), .seconds(1800))
        XCTAssertEqual(timer.state, .armed(deadline: origin + .seconds(1800)))
    }

    func testRemainingCountsDownWithoutFiringEarly() {
        var timer = SleepTimer()
        timer.arm(for: .seconds(1800), now: origin)

        let later = origin + .seconds(1740)
        XCTAssertEqual(timer.remaining(at: later), .seconds(60))
        XCTAssertFalse(timer.evaluate(at: later), "未到期限不应触发暂停")
        XCTAssertEqual(timer.state, .armed(deadline: origin + .seconds(1800)))
    }

    func testFiresExactlyOnceAtDeadline() {
        var timer = SleepTimer()
        timer.arm(for: .seconds(1800), now: origin)
        let deadline = origin + .seconds(1800)

        XCTAssertTrue(timer.evaluate(at: deadline))
        XCTAssertEqual(timer.state, .fired, "触发后必须离开 armed，避免重复暂停")
        XCTAssertFalse(timer.evaluate(at: deadline + .seconds(60)), "第二次调用不应再次触发")
    }

    func testCancelRestoresOff() {
        var timer = SleepTimer()
        timer.arm(for: .seconds(600), now: origin)
        timer.cancel()

        XCTAssertEqual(timer.state, .off)
        XCTAssertNil(timer.remaining(at: origin))
        XCTAssertFalse(timer.evaluate(at: origin + .seconds(3600)))
    }

    func testRearmingOverwritesInsteadOfAccumulating() {
        var timer = SleepTimer()
        timer.arm(for: .seconds(1800), now: origin)
        timer.arm(for: .seconds(300), now: origin + .seconds(100))

        XCTAssertEqual(timer.remaining(at: origin + .seconds(100)), .seconds(300),
                       "重新设定应覆盖旧期限，而不是把两段时间叠加")
    }

    func testZeroDurationDisarms() {
        var timer = SleepTimer()
        timer.arm(for: .seconds(1800), now: origin)
        timer.arm(for: .zero, now: origin)

        XCTAssertEqual(timer.state, .off)
    }

@MainActor

    /// 必须复用 harness 内部的时钟：引擎和模拟源都挂在它上面，
    /// 换成另一个时钟，定时器"过完 30 分钟"时引擎那边的时间并没有动。
    private func makeHarness() -> (EngineHarness, TestPlaybackClock) {
        let harness = EngineHarness()
        return (harness, harness.clock)
    }

    func testFiresAndPausesPlayback() async throws {
        let (harness, clock) = makeHarness()
        harness.engine.setQueue(harness.tracks, current: harness.tracks[0])
        await harness.engine.load(harness.tracks[0], autoplay: true)
        await harness.engine.play()

        let driver = SleepTimerDriver(playback: harness.engine, clock: clock)
        driver.start(for: .seconds(1800))
        XCTAssertTrue(driver.isArmed)

        // 假时钟的 sleep 会立即推进到期限，等待任务随即调用 pause。
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(harness.engine.state.debugLabel, "paused(user)",
                       "到点必须真的暂停，而不是只把定时器状态改成 fired")
        XCTAssertFalse(driver.isArmed, "触发后不应仍然处于 armed")
    }


    func testFadeOutRunsBeforePause() async throws {
        let (harness, clock) = makeHarness()
        harness.engine.setQueue(harness.tracks, current: harness.tracks[0])
        await harness.engine.load(harness.tracks[0], autoplay: true)
        await harness.engine.play()
        harness.engine.setVolume(0.8)

        let fade = FadeDriver(playback: harness.engine, clock: clock)
        let driver = SleepTimerDriver(playback: harness.engine, clock: clock, fade: fade)
        driver.start(for: .seconds(1800))

        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(harness.engine.state.debugLabel, "paused(user)")
        // 淡出只是到点那一下的过渡：用户的音量设置一个字都不能动，
        // 否则第二天按播放是无声的（旧实现把音量永久写成了 0）。
        XCTAssertEqual(harness.engine.volume, 0.8, accuracy: 0.001, "用户音量必须原样保留")
        XCTAssertFalse(harness.engine.isMuted, "不能把用户静音了")
        XCTAssertEqual(harness.engine.outputGain, 1, accuracy: 0.001, "暂停之后增益必须还原")
        XCTAssertEqual(harness.coordinator.targetVolume, 0.8, accuracy: 0.001,
                       "下一次播放要按用户音量出声")
    }

    func testMutedListenerIsNotUnmutedByFade() async throws {
        let (harness, clock) = makeHarness()
        harness.engine.setQueue(harness.tracks, current: harness.tracks[0])
        await harness.engine.load(harness.tracks[0], autoplay: true)
        harness.engine.setVolume(0.8)
        harness.engine.toggleMute()

        let fade = FadeDriver(playback: harness.engine, clock: clock)
        let driver = SleepTimerDriver(playback: harness.engine, clock: clock, fade: fade)
        driver.start(for: .seconds(1800))
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(harness.engine.isMuted, "静音着听的人，到点淡出不能替他取消静音")
        XCTAssertEqual(harness.engine.volume, 0.8, accuracy: 0.001)
        XCTAssertEqual(harness.coordinator.targetVolume, 0, accuracy: 0.001)
    }

    func testTimerFiringWhilePausedLeavesEverythingAlone() async throws {
        let (harness, clock) = makeHarness()
        harness.engine.setQueue(harness.tracks, current: harness.tracks[0])
        await harness.engine.load(harness.tracks[0], autoplay: true)
        harness.engine.setVolume(0.8)
        await harness.engine.pause()

        let fade = FadeDriver(playback: harness.engine, clock: clock)
        let driver = SleepTimerDriver(playback: harness.engine, clock: clock, fade: fade)
        driver.start(for: .seconds(1800))
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(harness.engine.outputGain, 1, accuracy: 0.001)
        XCTAssertEqual(harness.engine.volume, 0.8, accuracy: 0.001)
        XCTAssertFalse(driver.isArmed)
    }


    func testZeroFadeDurationSkipsFadeAndPausesImmediately() async throws {
        let (harness, clock) = makeHarness()
        harness.engine.setQueue(harness.tracks, current: harness.tracks[0])
        await harness.engine.load(harness.tracks[0], autoplay: true)
        await harness.engine.play()
        harness.engine.setVolume(0.8)

        let fade = FadeDriver(playback: harness.engine, clock: clock)
        let driver = SleepTimerDriver(playback: harness.engine, clock: clock,
                                      fade: fade, fadeOutDuration: .zero)
        driver.start(for: .seconds(1800))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(harness.engine.volume, 0.8, accuracy: 0.001,
                       "淡出时长为 0 时不能改动音量")
        XCTAssertEqual(harness.engine.state.debugLabel, "paused(user)", "但必须照常暂停")
    }

    func testCancelPreventsPause() async throws {
        let (harness, clock) = makeHarness()
        harness.engine.setQueue(harness.tracks, current: harness.tracks[0])
        await harness.engine.load(harness.tracks[0], autoplay: true)
        await harness.engine.play()

        let driver = SleepTimerDriver(playback: harness.engine, clock: clock)
        driver.start(for: .seconds(1800))
        driver.cancel()

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNotEqual(harness.engine.state.debugLabel, "paused(user)",
                          "取消之后不能再暂停")
        XCTAssertFalse(driver.isArmed)
    }

@MainActor

    func testCountdownFormatsMinutesAndSeconds() {
        XCTAssertEqual(SettingsView.countdownText(.seconds(1798)), "29:58")
        XCTAssertEqual(SettingsView.countdownText(.seconds(59)), "0:59")
        XCTAssertEqual(SettingsView.countdownText(.seconds(600)), "10:00")
    }

    func testCountdownNeverShowsNegative() {
        XCTAssertEqual(SettingsView.countdownText(.seconds(-5)), "0:00")
        XCTAssertEqual(SettingsView.countdownText(.zero), "0:00")
}

/// 下拉需要稳定值：用"设定的是多少分钟"，而不是用剩余时间反推。

@MainActor

    func testArmedMinutesTracksStartAndCancel() {
        let clock = TestPlaybackClock()
        let registry = SourceRegistry()
        registry.register(MockPlaybackSource(behavior: .healthy, clock: clock))
        let engine = PlaybackEngine(clock: clock, coordinator: PlaybackCoordinator(registry: registry))
        let driver = SleepTimerDriver(playback: engine, clock: clock)

        XCTAssertNil(driver.armedMinutes, "未设定时下拉应停在「关闭」")

        driver.start(for: .seconds(30 * 60))
        XCTAssertEqual(driver.armedMinutes, 30)

        driver.start(for: .seconds(90 * 60))
        XCTAssertEqual(driver.armedMinutes, 90, "重新设定要覆盖旧值")

        driver.cancel()
        XCTAssertNil(driver.armedMinutes, "取消后回到「关闭」")
        XCTAssertFalse(driver.isArmed)
    }
}
