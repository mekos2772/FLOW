import XCTest
@testable import SpatialLyricsPlayer

// 音量淡入淡出的全部契约：曲线数学 + 逐帧执行器。

@MainActor
final class AudioFadeTests: XCTestCase {

    func testEndpointsAreExact() {
        let values = FadeRamp.volumes(from: 1, to: 0, steps: 10)
        XCTAssertEqual(values.count, 11, "10 段应有 11 个采样点，含首尾")
        XCTAssertEqual(values.first, 1)
        XCTAssertEqual(values.last, 0)
    }

    func testVolumesAreMonotonicWhenFadingOut() {
        let values = FadeRamp.volumes(from: 1, to: 0, steps: 8)
        for (a, b) in zip(values, values.dropFirst()) {
            XCTAssertLessThanOrEqual(b, a, "淡出过程中音量不能回升")
        }
    }

    func testVolumesAreClampedIntoValidRange() {
        let values = FadeRamp.volumes(from: 1.5, to: -0.5, steps: 4)
        XCTAssertTrue(values.allSatisfy { $0 >= 0 && $0 <= 1 }, "越界音量必须在曲线里就被夹紧")
    }

    func testZeroStepsStillYieldsStartAndEnd() {
        let values = FadeRamp.volumes(from: 0.8, to: 0.2, steps: 0)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values.first, 0.8)
        XCTAssertEqual(values.last, 0.2)
    }

    func testStepCountRoundsUpAndNeverZero() {
        XCTAssertEqual(FadeRamp.stepCount(duration: .milliseconds(600), interval: .milliseconds(60)), 10)
        XCTAssertEqual(FadeRamp.stepCount(duration: .milliseconds(610), interval: .milliseconds(60)), 11,
                       "不足一段也要算一整段")
        XCTAssertEqual(FadeRamp.stepCount(duration: .zero, interval: .milliseconds(60)), 1)
        XCTAssertEqual(FadeRamp.stepCount(duration: .seconds(1), interval: .zero), 1, "非法间隔退化为一步")
    }

    private func makeHarness() -> (EngineHarness, TestPlaybackClock) {
        let harness = EngineHarness()
        return (harness, harness.clock)
    }

    func testFadeOutReachesSilenceWithoutTouchingUserVolume() async {
        let (harness, clock) = makeHarness()
        harness.engine.setVolume(0.6)

        let driver = FadeDriver(playback: harness.engine, clock: clock)
        let finished = await driver.fadeOut(over: .milliseconds(600))

        XCTAssertTrue(finished)
        XCTAssertEqual(harness.engine.outputGain, 0, accuracy: 0.001, "淡出结束时必须真的无声")
        XCTAssertEqual(harness.coordinator.targetVolume, 0, accuracy: 0.001)
        XCTAssertEqual(harness.engine.volume, 0.6, accuracy: 0.001,
                       "淡变不能改用户音量：那是他的设置，不是过渡效果的一部分")
        XCTAssertFalse(harness.engine.isMuted)
    }

    func testFadeInReturnsToFullGain() async {
        let (harness, clock) = makeHarness()
        harness.engine.setVolume(0.7)
        harness.engine.setOutputGain(0)

        let driver = FadeDriver(playback: harness.engine, clock: clock)
        await driver.fadeIn(over: .milliseconds(300))

        XCTAssertEqual(harness.engine.outputGain, 1, accuracy: 0.001)
        XCTAssertEqual(harness.coordinator.targetVolume, 0.7, accuracy: 0.001)
    }

    func testCancelRestoresFullGain() async {
        let (harness, clock) = makeHarness()
        harness.engine.setVolume(0.9)
        let driver = FadeDriver(playback: harness.engine, clock: clock)

        await driver.fadeOut(over: .milliseconds(600))
        XCTAssertEqual(harness.engine.outputGain, 0, accuracy: 0.001)

        driver.cancel()
        XCTAssertEqual(harness.engine.outputGain, 1, accuracy: 0.001,
                       "取消淡出必须把声音还回来")
        XCTAssertEqual(harness.coordinator.targetVolume, 0.9, accuracy: 0.001)
    }

    func testFadeInStartsAtZeroEndsAtOne() {
        XCTAssertEqual(AudioFade.gain(progress: 0, kind: .fadeIn), 0, accuracy: 0.0001)
        XCTAssertEqual(AudioFade.gain(progress: 1, kind: .fadeIn), 1, accuracy: 0.0001)
    }

    func testFadeOutStartsAtOneEndsAtZero() {
        XCTAssertEqual(AudioFade.gain(progress: 0, kind: .fadeOut), 1, accuracy: 0.0001)
        XCTAssertEqual(AudioFade.gain(progress: 1, kind: .fadeOut), 0, accuracy: 0.0001)
    }

    func testCurveIsMonotonic() {
        var previous: Float = -1
        for step in 0...20 {
            let value = AudioFade.gain(progress: Double(step) / 20, kind: .fadeIn)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testClampsOutOfRangeProgress() {
        XCTAssertEqual(AudioFade.gain(progress: -1, kind: .fadeIn), 0, accuracy: 0.0001)
        XCTAssertEqual(AudioFade.gain(progress: 2, kind: .fadeIn), 1, accuracy: 0.0001)
    }

    func testSequenceLengthFollowsDuration() {
        let sequence = AudioFade.sequence(duration: 0.12, kind: .fadeIn, interval: 0.02)
        XCTAssertEqual(sequence.count, 7, "0.12s / 0.02s = 6 步 + 终点")
        XCTAssertEqual(sequence.first ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(sequence.last ?? -1, 1, accuracy: 0.0001)
    }

    func testZeroDurationProducesEmptySequence() {
        XCTAssertTrue(AudioFade.sequence(duration: 0, kind: .fadeIn).isEmpty,
                      "时长为 0 表示禁用淡变，不应产生任何步进")
    }

    func testRunnerReachesTargetVolume() async {
        let runner = AudioFadeRunner()
        let recorder = VolumeRecorder()
        await runner.run(kind: .fadeIn, duration: 0.04, target: 0.8) { value in
            await recorder.record(value)
        }
        let values = await recorder.values
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values.last ?? 0, 0.8, accuracy: 0.02, "淡入结束必须落在目标音量")
        XCTAssertEqual(values.first ?? 1, 0, accuracy: 0.02, "淡入必须从静音开始")
    }

    func testNewFadeCancelsPrevious() async {
        let runner = AudioFadeRunner()
        let recorder = VolumeRecorder()
        async let first: Void = runner.run(kind: .fadeIn, duration: 0.2, target: 1) { value in
            await recorder.record(value)
        }
        try? await Task.sleep(for: .milliseconds(20))
        await runner.run(kind: .fadeOut, duration: 0.04, target: 1) { value in
            await recorder.record(value)
        }
        await first
        let values = await recorder.values
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values.last ?? 1, 0, accuracy: 0.05, "后一次淡出必须生效（淡出到 0）")
    }
}

/// 记录音量回调的 actor（回调是 @Sendable）。
actor VolumeRecorder {
    private(set) var values: [Float] = []
    func record(_ value: Float) { values.append(value) }
}
