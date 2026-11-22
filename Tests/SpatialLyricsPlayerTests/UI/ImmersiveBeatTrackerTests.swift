import XCTest
@testable import SpatialLyricsPlayer

/// 节拍跟踪：用合成鼓点（底鼓、军鼓、镲 + 噪声）按抽头的格长（512 帧 @ 44.1 kHz）喂进去，
/// 按 30 帧/秒推进，对照真实拍点检查速度、相位、小节、可信度与输出时钟。
final class ImmersiveBeatTrackerTests: XCTestCase {
    private static let hop = 512.0 / 44_100

    /// 可复现的随机数（SplitMix64）。
    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double(z ^ (z >> 31)) / Double(UInt64.max)
        }
    }

    private struct Track {
        var bpm: Double
        var offset: Double
        var period: Double { 60 / bpm }
        func beatPosition(at t: Double) -> Double { (t - offset) / period }
    }

    /// 一首合成的歌：底鼓每拍（第一拍最重）、军鼓在 2、4 拍、镲在八分音符上，外加中频铺底和噪声。
    private func makeFrames(_ track: Track, from start: Double = 0, to end: Double, seed: UInt64 = 1,
                            jitter: Double = 0, missing: Double = 0, swing: Double = 0.5,
                            hats: Bool = true, accent: Bool = false,
                            tempoChange: (at: Double, bpm: Double)? = nil) -> [AudioOnsetFrame] {
        var random = Random(state: seed)
        var kicks: [(Double, Float)] = [], snares: [Double] = [], hatTimes: [Double] = []
        var beat = 0
        var t = track.offset
        var period = track.period
        while t < end + 1 {
            if let change = tempoChange, t >= change.at { period = 60 / change.bpm }
            let j = (random.next() * 2 - 1) * jitter
            let slot = beat % 4
            if random.next() >= missing {
                let amp: Float = accent ? (slot == 0 ? 1.0 : (slot == 2 ? 0.55 : 0.3)) : 0.8
                kicks.append((t + j, amp))
            }
            if slot == 1 || slot == 3 { snares.append(t + j) }
            if hats {
                hatTimes.append(t + j)
                hatTimes.append(t + period * swing + (random.next() * 2 - 1) * jitter)
            }
            t += period
            beat += 1
        }
        var frames: [AudioOnsetFrame] = []
        var time = start
        while time < end {
            var low: Float = 0.002 * Float(random.next())
            var mid: Float = 0.05 + 0.01 * Float(random.next())
            var high: Float = 0.003 * Float(random.next())
            for (k, amp) in kicks where k <= time + Self.hop && time - k < 0.5 {
                low += amp * Float(exp(-max(time - k, 0) / 0.08))
            }
            for s in snares where s <= time + Self.hop && time - s < 0.5 {
                mid += 0.5 * Float(exp(-max(time - s, 0) / 0.10))
                high += 0.3 * Float(exp(-max(time - s, 0) / 0.08))
            }
            for h in hatTimes where h <= time + Self.hop && time - h < 0.2 {
                high += 0.25 * Float(exp(-max(time - h, 0) / 0.03))
            }
            frames.append(AudioOnsetFrame(mediaTime: time, duration: Self.hop, low: low, mid: mid, high: high))
            time += Self.hop
        }
        return frames
    }

    private struct Sample {
        var time: Double
        var output: ImmersiveBeatTracker.Output
    }

    /// 按 30 帧推进：每帧先喂"抽头已经分析到"的格子（比听到的早约 90 ms），再按听到的位置取一次输出。
    @discardableResult
    private func run(_ tracker: inout ImmersiveBeatTracker, frames: [AudioOnsetFrame], from start: Double, to end: Double,
                     playing: Bool = true) -> [Sample] {
        var samples: [Sample] = []
        var next = frames.firstIndex { $0.mediaTime >= start } ?? frames.count
        var t = start
        while t < end {
            var batch: [AudioOnsetFrame] = []
            while next < frames.count, frames[next].mediaTime <= t + 0.09 {
                batch.append(frames[next])
                next += 1
            }
            tracker.ingest(batch)
            samples.append(Sample(time: t, output: tracker.step(mediaTime: t, dt: 1.0 / 30, isPlaying: playing)))
            t += 1.0 / 30
        }
        return samples
    }

    /// 拍内相位误差（秒）：输出拍数的小数部分对照真实拍点。
    private func phaseError(_ sample: Sample, _ track: Track) -> Double {
        var e = sample.output.beatTime - track.beatPosition(at: sample.time)
        e -= e.rounded()
        return e * track.period
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? .nan : sorted[sorted.count / 2]
    }

    // MARK: - 速度与相位

    func testLocksTempoAndPhaseOnCleanBeats() {
        for (bpm, offset) in [(75.0, 0.31), (92.0, 0.12), (120.0, 0.47), (128.0, 0.05)] {
            let track = Track(bpm: bpm, offset: offset)
            var tracker = ImmersiveBeatTracker()
            let samples = run(&tracker, frames: makeFrames(track, to: 12), from: 0, to: 12)
            let late = samples.filter { $0.time > 8 }
            let tempo = late.last!.output.tempo
            XCTAssertEqual(tempo, bpm, accuracy: bpm * 0.02, "\(bpm) BPM 速度没锁上：\(tempo)")
            XCTAssertLessThan(abs(median(late.map { phaseError($0, track) })), 0.035, "\(bpm) BPM 拍点偏差太大")
            XCTAssertGreaterThan(late.last!.output.confidence, 0.6, "\(bpm) BPM 清楚的鼓点却不可信")
            // 6 秒内锁定。
            let lock = samples.first { abs($0.output.tempo - bpm) < bpm * 0.02 && abs(phaseError($0, track)) < 0.035 }
            XCTAssertNotNil(lock)
            XCTAssertLessThan(lock?.time ?? 99, 6.5, "\(bpm) BPM 锁定太慢")
        }
    }

    func testToleratesJitterMissingKicksAndSwing() {
        let track = Track(bpm: 100, offset: 0.2)
        var tracker = ImmersiveBeatTracker()
        let frames = makeFrames(track, to: 14, seed: 7, jitter: 0.015, missing: 0.2, swing: 0.58)
        let late = run(&tracker, frames: frames, from: 0, to: 14).filter { $0.time > 9 }
        XCTAssertEqual(late.last!.output.tempo, 100, accuracy: 2)
        XCTAssertLessThan(abs(median(late.map { phaseError($0, track) })), 0.035)
    }

    /// 140 BPM、八分音符的镲很响：不能在 70 / 280 之间来回跳。
    func testFastSongDoesNotFlipOctaves() {
        let track = Track(bpm: 140, offset: 0.1)
        var tracker = ImmersiveBeatTracker()
        let samples = run(&tracker, frames: makeFrames(track, to: 24, seed: 3), from: 0, to: 24)
        let tempos = samples.filter { $0.time > 8 }.map(\.output.tempo)
        XCTAssertEqual(tempos.first ?? 0, 140, accuracy: 2.8)
        XCTAssertLessThan((tempos.max() ?? 0) - (tempos.min() ?? 0), 4, "速度在倍速 / 半速之间跳了")
    }

    func testFollowsTempoChange() {
        let track = Track(bpm: 100, offset: 0.1)
        var tracker = ImmersiveBeatTracker()
        let frames = makeFrames(track, to: 32, seed: 5, tempoChange: (15, 120))
        let samples = run(&tracker, frames: frames, from: 0, to: 32)
        XCTAssertEqual(samples.first { $0.time > 13 }!.output.tempo, 100, accuracy: 2)
        XCTAssertEqual(samples.last!.output.tempo, 120, accuracy: 2.4, "变速后没有重新锁定")
    }

    // MARK: - 可信度

    func testConfidenceFadesInSilenceAndStaysLowWithoutPulse() {
        let track = Track(bpm: 110, offset: 0)
        var tracker = ImmersiveBeatTracker()
        var frames = makeFrames(track, to: 12)
        var t = 12.0
        while t < 20 {
            frames.append(AudioOnsetFrame(mediaTime: t, duration: Self.hop, low: 0, mid: 0, high: 0))
            t += Self.hop
        }
        let samples = run(&tracker, frames: frames, from: 0, to: 20)
        XCTAssertGreaterThan(samples.first { $0.time > 11 }!.output.confidence, 0.6)
        XCTAssertLessThan(samples.first { $0.time > 16 }!.output.confidence, 0.2, "静音 4 秒后仍然可信")

        // 只有铺底和噪声、没有节拍：可信度一直低。
        var random = Random(state: 11)
        var pad: [AudioOnsetFrame] = []
        t = 0
        while t < 16 {
            pad.append(AudioOnsetFrame(mediaTime: t, duration: Self.hop, low: 0.05 * Float(random.next()),
                                       mid: 0.2 + 0.1 * Float(random.next()), high: 0.02 * Float(random.next())))
            t += Self.hop
        }
        var padTracker = ImmersiveBeatTracker()
        let padSamples = run(&padTracker, frames: pad, from: 0, to: 16)
        XCTAssertLessThan(padSamples.filter { $0.time > 6 }.map(\.output.confidence).max() ?? 1, 0.35,
                          "没有节拍的铺底不该被当成可信的拍子")
    }

    // MARK: - 拖动进度与输出时钟

    func testSeekKeepsGridAndClockStaysContinuous() {
        let track = Track(bpm: 120, offset: 0.37)
        var tracker = ImmersiveBeatTracker()
        let frames = makeFrames(track, to: 60, seed: 9)
        var samples = run(&tracker, frames: frames, from: 0, to: 15)
        samples += run(&tracker, frames: frames, from: 5, to: 9)      // 往回拖 10 秒
        samples += run(&tracker, frames: frames, from: 40, to: 44)    // 往前拖到 40 秒
        for (a, b) in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.output.beatTime, a.output.beatTime, "拍数倒退了")
            let step = b.output.beatTime - a.output.beatTime
            XCTAssertLessThan(step, 0.25, "拍数一帧跳了 \(step) 拍")
        }
        let afterBack = samples.filter { $0.time > 6.2 && $0.time < 9 }
        let afterForward = samples.filter { $0.time > 41.2 }
        XCTAssertLessThan(abs(median(afterBack.map { phaseError($0, track) })), 0.035, "往回拖之后没对齐")
        XCTAssertLessThan(abs(median(afterForward.map { phaseError($0, track) })), 0.035, "往前拖之后没对齐")
    }

    func testClockIsMonotonicThroughPausesSilenceAndBadInput() {
        let track = Track(bpm: 96, offset: 0.2)
        var tracker = ImmersiveBeatTracker()
        let frames = makeFrames(track, to: 30, seed: 13)
        var last = -Double.infinity
        var t = 0.0
        var next = 0
        var random = Random(state: 21)
        while t < 30 {
            var batch: [AudioOnsetFrame] = []
            while next < frames.count, frames[next].mediaTime <= t + 0.09 { batch.append(frames[next]); next += 1 }
            if random.next() < 0.05 {   // 坏数据、乱序
                batch.append(AudioOnsetFrame(mediaTime: .nan, duration: Self.hop, low: .nan, mid: -1, high: .infinity))
                batch.append(AudioOnsetFrame(mediaTime: t - 3, duration: Self.hop, low: 1, mid: 1, high: 1))
            }
            tracker.ingest(batch)
            let playing = !(10..<12).contains(t)
            let dt = random.next() < 0.02 ? 0.4 : 1.0 / 30
            let output = tracker.step(mediaTime: playing ? t : 10, dt: dt, isPlaying: playing)
            XCTAssertTrue(output.beatTime.isFinite && output.confidence.isFinite && output.barPhase.isFinite)
            XCTAssertGreaterThanOrEqual(output.beatTime, last)
            last = output.beatTime
            t += 1.0 / 30
        }
    }

    func testHoldsStillWhilePaused() {
        let track = Track(bpm: 120, offset: 0)
        var tracker = ImmersiveBeatTracker()
        run(&tracker, frames: makeFrames(track, to: 10), from: 0, to: 10)
        let before = tracker.step(mediaTime: 10, dt: 1.0 / 30, isPlaying: false).beatTime
        for _ in 0..<30 { _ = tracker.step(mediaTime: 10, dt: 1.0 / 30, isPlaying: false) }
        XCTAssertEqual(tracker.step(mediaTime: 10, dt: 1.0 / 30, isPlaying: false).beatTime, before)
    }

    // MARK: - 小节

    func testFindsDownbeatFromAccentedKicks() {
        let track = Track(bpm: 110, offset: 0.25)
        var tracker = ImmersiveBeatTracker()
        let samples = run(&tracker, frames: makeFrames(track, to: 30, seed: 17, accent: true), from: 0, to: 30)
        let late = samples.filter { $0.time > 20 }
        let errors = late.map { s -> Double in
            let truth = track.beatPosition(at: s.time) / 4
            var e = Double(s.output.barPhase) - (truth - truth.rounded(.down))
            e -= e.rounded()
            return abs(e)
        }
        XCTAssertLessThan(median(errors), 0.06, "第一拍没找对")
        XCTAssertGreaterThan(late.last!.output.barConfidence, 0.3)
    }

    // MARK: - 诊断

    func testDiagnosticsAlignment() {
        let track = Track(bpm: 120, offset: 0.1)
        var tracker = ImmersiveBeatTracker()
        run(&tracker, frames: makeFrames(track, to: 22, seed: 19), from: 0, to: 22)
        let clean = tracker.diagnostics()
        XCTAssertGreaterThan(clean.alignedRatio, 0.8)
        XCTAssertLessThan(abs(clean.meanOffsetMilliseconds), 25)
        XCTAssertGreaterThan(clean.strongOnsets, 20)

        // 先锁在 120 上，再喂一段完全随机的起音：对齐率应该掉下来。
        var random = Random(state: 23)
        var noisy: [AudioOnsetFrame] = []
        var t = 22.0
        var nextHit = 22.0
        var hit = -1.0
        while t < 44 {
            if t >= nextHit { hit = t; nextHit = t + 0.15 + random.next() * 0.5 }
            let low: Float = hit >= 0 ? Float(exp(-(t - hit) / 0.08)) : 0
            noisy.append(AudioOnsetFrame(mediaTime: t, duration: Self.hop, low: low, mid: 0.05, high: 0.01))
            t += Self.hop
        }
        run(&tracker, frames: noisy, from: 22, to: 44)
        // 拍点加半拍、±50 ms 的窗口本身就占了四成时间：随机起音落在这个水平附近。
        XCTAssertLessThan(tracker.diagnostics().alignedRatio, 0.65)
    }
}

/// 送进着色器的节拍参数：幅度、半速、画面拍数的连续性。
final class ImmersiveRhythmTests: XCTestCase {
    private func output(beat: Double, tempo: Double, bar: Float, confidence: Float = 1) -> ImmersiveBeatTracker.Output {
        ImmersiveBeatTracker.Output(tempo: tempo, confidence: confidence, beatTime: beat, barPhase: bar, barConfidence: 1)
    }

    func testAmplitudesFollowSettingAndFadeWhenInactive() {
        var rhythm = ImmersiveRhythm()
        var r = SIMD4<Float>(0, 0, 0, 0)
        for i in 0..<120 {
            let beat = Double(i) / 15
            r = rhythm.step(output(beat: beat, tempo: 120, bar: Float((beat / 4).truncatingRemainder(dividingBy: 1))),
                            dt: 1.0 / 30, active: true, response: 1, sync: .standard)
        }
        XCTAssertEqual(r.w, ImmersiveBeatSync.standard.beatGain, accuracy: 0.1)
        XCTAssertEqual(r.z, ImmersiveBeatSync.standard.barGain, accuracy: 0.1)
        for i in 120..<180 {
            let beat = Double(i) / 15
            r = rhythm.step(output(beat: beat, tempo: 120, bar: 0), dt: 1.0 / 30, active: false, response: 1, sync: .standard)
        }
        XCTAssertLessThan(r.w, 0.05, "暂停后节拍波没有淡出")
        var off = ImmersiveRhythm()
        let silent = off.step(output(beat: 1, tempo: 120, bar: 0), dt: 1, active: true, response: 1, sync: .off)
        XCTAssertEqual(silent.z, 0)
        XCTAssertEqual(silent.w, 0)
    }

    /// 快歌按半速给画面，而且切换半速时画面拍数不跳、不倒退。
    func testHalfTimeForFastSongsWithoutJumps() {
        var rhythm = ImmersiveRhythm()
        var previous = 0.0
        var beat = 0.0
        for i in 0..<600 {
            let tempo = i < 300 ? 110.0 : 142.0
            beat += tempo / 60 / 30
            let bar = Float((beat / 4).truncatingRemainder(dividingBy: 1))
            _ = rhythm.step(output(beat: beat, tempo: tempo, bar: bar), dt: 1.0 / 30, active: true, response: 1, sync: .standard)
            XCTAssertGreaterThanOrEqual(rhythm.visualBeats, previous)
            XCTAssertLessThan(rhythm.visualBeats - previous, 0.25)
            previous = rhythm.visualBeats
        }
        XCTAssertTrue(rhythm.halfTime)
        // 门槛附近有迟滞：125 BPM 不会切回来。
        _ = rhythm.step(output(beat: beat + 0.07, tempo: 125, bar: 0), dt: 1.0 / 30, active: true, response: 1, sync: .standard)
        XCTAssertTrue(rhythm.halfTime)
        _ = rhythm.step(output(beat: beat + 0.14, tempo: 118, bar: 0), dt: 1.0 / 30, active: true, response: 1, sync: .standard)
        XCTAssertFalse(rhythm.halfTime)
    }

    /// 画面拍数会靠到"小节里该在的那一拍"上：小数部分对齐真实拍点。
    func testVisualBeatsConvergeToBarPosition() {
        var rhythm = ImmersiveRhythm()
        var beat = 37.3
        var last = SIMD4<Float>(0, 0, 0, 0)
        for _ in 0..<300 {
            beat += 100.0 / 60 / 30
            let bar = Float((beat / 4).truncatingRemainder(dividingBy: 1))
            last = rhythm.step(output(beat: beat, tempo: 100, bar: bar), dt: 1.0 / 30, active: true, response: 1, sync: .standard)
        }
        var e = Double(last.y) - (beat / 4).truncatingRemainder(dividingBy: 1)
        e -= e.rounded()
        XCTAssertLessThan(abs(e), 0.02)
    }
}
