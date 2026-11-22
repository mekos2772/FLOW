import AVFoundation
import XCTest
@testable import SpatialLyricsPlayer

final class AudioBandSplitterTests: XCTestCase {
    private let sampleRate = 44_100.0

    // MARK: - 辅助

    private func sine(frequencyHz: Double, amplitude: Double = 0.5, range: Range<Int>) -> [Float] {
        range.map { Float(amplitude * sin(2 * Double.pi * frequencyHz * Double($0) / sampleRate)) }
    }

    private func analyzeMono(_ splitter: inout AudioBandSplitter, _ samples: [Float]) -> AudioBandLevels {
        samples.withUnsafeBufferPointer { splitter.analyzeInterleaved($0, frameCount: samples.count, stride: 1) }
    }

    private func analyzeInterleaved(_ splitter: inout AudioBandSplitter, left: [Float], right: [Float]) -> AudioBandLevels {
        var interleaved = [Float](repeating: 0, count: left.count * 2)
        for i in left.indices {
            interleaved[i * 2] = left[i]
            interleaved[i * 2 + 1] = right[i]
        }
        return interleaved.withUnsafeBufferPointer {
            splitter.analyzeInterleaved($0, frameCount: left.count, stride: 2)
        }
    }

    /// 先喂一块把滤波器的起振瞬态吃掉，再测紧接着（相位连续）的下一块。
    private func steadyLevels(frequencyHz: Double) -> AudioBandLevels {
        var splitter = AudioBandSplitter()
        splitter.prepare(sampleRate: sampleRate)
        _ = analyzeMono(&splitter, sine(frequencyHz: frequencyHz, range: 0..<4096))
        return analyzeMono(&splitter, sine(frequencyHz: frequencyHz, range: 4096..<8192))
    }

    private func assertLevelsEqual(_ a: AudioBandLevels, _ b: AudioBandLevels,
                                   accuracy: Float = 1e-6,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.low, b.low, accuracy: accuracy, "low", file: file, line: line)
        XCTAssertEqual(a.mid, b.mid, accuracy: accuracy, "mid", file: file, line: line)
        XCTAssertEqual(a.high, b.high, accuracy: accuracy, "high", file: file, line: line)
        XCTAssertEqual(a.full, b.full, accuracy: accuracy, "full", file: file, line: line)
    }

    // MARK: - 频段分离

    func testLowFrequencySineLandsInLowBand() {
        let levels = steadyLevels(frequencyHz: 60)
        XCTAssertGreaterThan(levels.low, 0.25)
        XCTAssertGreaterThan(levels.low, levels.mid * 3)
        XCTAssertGreaterThan(levels.low, levels.high * 3)
    }

    func testMidFrequencySineLandsInMidBand() {
        let levels = steadyLevels(frequencyHz: 1_000)
        XCTAssertGreaterThan(levels.mid, 0.25)
        XCTAssertGreaterThan(levels.mid, levels.low * 3)
        XCTAssertGreaterThan(levels.mid, levels.high * 3)
    }

    func testHighFrequencySineLandsInHighBand() {
        let levels = steadyLevels(frequencyHz: 8_000)
        XCTAssertGreaterThan(levels.high, 0.25)
        XCTAssertGreaterThan(levels.high, levels.low * 3)
        XCTAssertGreaterThan(levels.high, levels.mid * 3)
    }

    func testSilenceYieldsZeroLevels() {
        var splitter = AudioBandSplitter()
        let levels = analyzeMono(&splitter, [Float](repeating: 0, count: 2048))
        assertLevelsEqual(levels, .silent)
    }

    func testFullBandRMSOfHalfAmplitudeSine() {
        // 1 kHz × 4410 帧 = 恰好 100 个整周期，RMS 理论值 0.5/√2 ≈ 0.3536。
        var splitter = AudioBandSplitter()
        let levels = analyzeMono(&splitter, sine(frequencyHz: 1_000, range: 0..<4410))
        XCTAssertEqual(levels.full, 0.3536, accuracy: 0.3536 * 0.05)
    }

    // MARK: - 声道布局

    func testIdenticalStereoInterleavedMatchesMono() {
        let signal = sine(frequencyHz: 220, range: 0..<2048)
        var mono = AudioBandSplitter()
        var stereo = AudioBandSplitter()
        let monoLevels = analyzeMono(&mono, signal)
        let stereoLevels = analyzeInterleaved(&stereo, left: signal, right: signal)
        assertLevelsEqual(monoLevels, stereoLevels)
        XCTAssertGreaterThan(monoLevels.full, 0.1)
    }

    func testPlanarMatchesInterleavedForSameSignal() {
        let left = sine(frequencyHz: 60, range: 0..<2048)
        let right = sine(frequencyHz: 5_000, amplitude: 0.3, range: 0..<2048)

        var interleavedSplitter = AudioBandSplitter()
        let interleavedLevels = analyzeInterleaved(&interleavedSplitter, left: left, right: right)

        var planarSplitter = AudioBandSplitter()
        let planarLevels = left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                planarSplitter.analyzePlanar([l, r], frameCount: left.count)
            }
        }
        assertLevelsEqual(interleavedLevels, planarLevels)

        // 抽头里走的是可写指针的重载，结果必须与只读版本一致。
        var mutableLeft = left
        var mutableRight = right
        var mutablePlanarSplitter = AudioBandSplitter()
        let mutablePlanarLevels = mutableLeft.withUnsafeMutableBufferPointer { l in
            mutableRight.withUnsafeMutableBufferPointer { r in
                mutablePlanarSplitter.analyzePlanar([l, r], frameCount: left.count)
            }
        }
        assertLevelsEqual(planarLevels, mutablePlanarLevels)
        XCTAssertGreaterThan(planarLevels.low, 0.05)
        XCTAssertGreaterThan(planarLevels.high, 0.05)
    }

    func testFrameCountBeyondBufferIsClampedInsteadOfReadingOutOfBounds() {
        var splitter = AudioBandSplitter()
        let short = sine(frequencyHz: 1_000, range: 0..<100)
        let levels = short.withUnsafeBufferPointer {
            splitter.analyzeInterleaved($0, frameCount: 10_000, stride: 2)
        }
        XCTAssertTrue(levels.full.isFinite)

        var planar = AudioBandSplitter()
        let empty = planar.analyzePlanar([UnsafeBufferPointer<Float>](), frameCount: 512)
        assertLevelsEqual(empty, .silent)
    }

    // MARK: - 健壮性

    func testNonFiniteInputDoesNotPoisonSubsequentBuffers() {
        var splitter = AudioBandSplitter()
        _ = analyzeMono(&splitter, sine(frequencyHz: 440, range: 0..<1024))

        var poisoned = sine(frequencyHz: 440, range: 1024..<2048)
        poisoned[300] = .nan
        poisoned[700] = .infinity
        let poisonedLevels = analyzeMono(&splitter, poisoned)
        assertLevelsEqual(poisonedLevels, .silent)

        // 坏块之后应自动清空状态：与一个全新的分析器处理同一块干净数据的结果完全一致。
        let clean = sine(frequencyHz: 1_000, range: 0..<2048)
        let recovered = analyzeMono(&splitter, clean)
        var fresh = AudioBandSplitter()
        let reference = analyzeMono(&fresh, clean)
        assertLevelsEqual(recovered, reference)
        XCTAssertGreaterThan(recovered.mid, 0.2)
    }

    // MARK: - 起音格子

    private func slice(_ splitter: inout AudioBandSplitter, _ samples: [Float], mediaTime: Double?) -> [AudioOnsetFrame] {
        let scratch = UnsafeMutableBufferPointer<AudioOnsetFrame>.allocate(capacity: 64)
        defer { scratch.deallocate() }
        var count = 0
        _ = samples.withUnsafeBufferPointer {
            splitter.analyzeInterleaved($0, frameCount: samples.count, stride: 1, mediaTime: mediaTime,
                                        onsets: scratch, onsetCount: &count)
        }
        return Array(scratch[0..<count])
    }

    func testOnsetHopsCarrySongTimeAcrossBuffers() {
        var splitter = AudioBandSplitter()
        splitter.prepare(sampleRate: sampleRate)
        XCTAssertEqual(splitter.hopFrames, 512)
        let hop = 512.0 / sampleRate
        // 1000 帧一块：格子跨块，时间仍然首尾相接。
        var frames: [AudioOnsetFrame] = []
        for block in 0..<9 {
            let start = block * 1000
            frames += slice(&splitter, sine(frequencyHz: 220, range: start..<start + 1000), mediaTime: 10 + Double(start) / sampleRate)
        }
        XCTAssertEqual(frames.count, 9000 / 512)
        for (k, frame) in frames.enumerated() {
            XCTAssertEqual(frame.mediaTime, 10 + Double(k) * hop, accuracy: 1e-9)
            XCTAssertEqual(frame.duration, hop, accuracy: 1e-12)
            XCTAssertTrue(frame.low.isFinite && frame.mid.isFinite && frame.high.isFinite)
        }
    }

    /// 实机：抽头每块 960 帧，报来的起点按编码包取整，在真实位置前后跳动约 12ms。
    /// 格子时间必须仍然等距、不倒退、不丢格。
    func testQuantizedBufferStartsStillGiveEvenHops() {
        var splitter = AudioBandSplitter()
        splitter.prepare(sampleRate: 48_000)
        let hop = Double(splitter.hopFrames) / 48_000
        var frames: [AudioOnsetFrame] = []
        for block in 0..<200 {
            let exact = 3.0 + Double(block * 960) / 48_000
            let reported = (exact / 0.011625).rounded(.down) * 0.011625   // 按包取整
            let samples = (0..<960).map { Float(0.3 * sin(2 * Double.pi * 70 * Double(block * 960 + $0) / 48_000)) }
            frames += slice(&splitter, samples, mediaTime: reported)
        }
        XCTAssertEqual(frames.count, 200 * 960 / splitter.hopFrames)
        for (a, b) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(b.mediaTime - a.mediaTime, hop, accuracy: 1e-9)
        }
        XCTAssertEqual(frames.first?.mediaTime ?? 0, 3.0, accuracy: 0.012)
    }

    func testSeekDiscardsHalfFilledHop() {
        var splitter = AudioBandSplitter()
        splitter.prepare(sampleRate: sampleRate)
        XCTAssertTrue(slice(&splitter, sine(frequencyHz: 220, range: 0..<300), mediaTime: 5).isEmpty)
        // 跳到 60 秒：前面攒的 300 帧不能拼进新位置的格子里。
        let after = slice(&splitter, sine(frequencyHz: 220, range: 0..<1024), mediaTime: 60)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after.first?.mediaTime ?? 0, 60, accuracy: 1e-9)
    }

    func testNoSongTimeMeansNoOnsets() {
        var splitter = AudioBandSplitter()
        splitter.prepare(sampleRate: sampleRate)
        XCTAssertTrue(slice(&splitter, sine(frequencyHz: 60, range: 0..<4096), mediaTime: nil).isEmpty)
    }

    func testKickBurstRaisesLowBandOfItsHop() {
        var splitter = AudioBandSplitter()
        splitter.prepare(sampleRate: sampleRate)
        var samples = [Float](repeating: 0, count: 4096)
        // 第 4 格（2048…2559）里放一记 60 Hz 的"底鼓"。
        for i in 2048..<2560 { samples[i] = Float(0.8 * sin(2 * Double.pi * 60 * Double(i - 2048) / sampleRate)) }
        let frames = slice(&splitter, samples, mediaTime: 0)
        XCTAssertEqual(frames.count, 8)
        let loudest = frames.indices.max { frames[$0].low < frames[$1].low }
        XCTAssertEqual(loudest, 4)
        XCTAssertGreaterThan(frames[4].low, frames[4].high * 20)
    }

    func testDefaultsTo44100AndRejectsInvalidSampleRate() {
        XCTAssertEqual(AudioBandSplitter().sampleRate, 44_100)
        var splitter = AudioBandSplitter()
        splitter.prepare(sampleRate: .nan)
        XCTAssertEqual(splitter.sampleRate, 44_100)
        splitter.prepare(sampleRate: 0)
        XCTAssertEqual(splitter.sampleRate, 44_100)
        splitter.prepare(sampleRate: 48_000)
        XCTAssertEqual(splitter.sampleRate, 48_000)
    }
}

final class AudioFeatureMeterTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slp-audio-meter-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        AudioFeatureMeter.shared.isEnabled = false
        AudioFeatureMeter.shared.reset()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private let sampleLevels = AudioBandLevels(low: 0.4, mid: 0.2, high: 0.1, full: 0.5)

    func testPublishIncrementsSequenceAndLatestReturnsLastReading() {
        let meter = AudioFeatureMeter()
        XCTAssertEqual(meter.latest(), .init(levels: .silent, timestamp: nil, sequence: 0))

        let t1 = ContinuousClock.now
        meter.publish(sampleLevels, at: t1)
        XCTAssertEqual(meter.latest(), .init(levels: sampleLevels, timestamp: t1, sequence: 1))

        let second = AudioBandLevels(low: 0.05, mid: 0.6, high: 0.3, full: 0.7)
        let t2 = t1.advanced(by: .milliseconds(10))
        meter.publish(second, at: t2)
        XCTAssertEqual(meter.latest(), .init(levels: second, timestamp: t2, sequence: 2))

        // 默认时间戳取当前时刻。
        meter.publish(sampleLevels)
        let third = meter.latest()
        XCTAssertEqual(third.sequence, 3)
        XCTAssertNotNil(third.timestamp)
        XCTAssertGreaterThanOrEqual(third.timestamp!, t1)
    }

    func testResetClearsReading() {
        let meter = AudioFeatureMeter()
        meter.publish(sampleLevels)
        meter.publish(sampleLevels)
        meter.reset()
        XCTAssertEqual(meter.latest(), .init(levels: .silent, timestamp: nil, sequence: 0))
    }

    private func onsetFrames(_ n: Int, from start: Int = 0) -> [AudioOnsetFrame] {
        (start..<start + n).map { AudioOnsetFrame(mediaTime: Double($0) * 0.01, duration: 0.01, low: 1, mid: 0.5, high: 0.25) }
    }

    func testOnsetRingDeliversIncrementallyAndKeepsTheLatestLap() {
        let meter = AudioFeatureMeter()
        onsetFrames(3000).withUnsafeBufferPointer { meter.publishOnsets($0) }
        var out: [AudioOnsetFrame] = []
        let seq = meter.onsets(after: 0, into: &out)
        XCTAssertEqual(seq, 3000)
        XCTAssertEqual(out.count, AudioFeatureMeter.onsetCapacity, "落后超过一圈只拿到最近一圈")
        XCTAssertEqual(out.first?.mediaTime ?? 0, Double(3000 - AudioFeatureMeter.onsetCapacity) * 0.01, accuracy: 1e-9)
        XCTAssertEqual(out.last?.mediaTime ?? 0, 29.99, accuracy: 1e-9)
        out.removeAll()
        XCTAssertEqual(meter.onsets(after: seq, into: &out), 3000)
        XCTAssertTrue(out.isEmpty)
        onsetFrames(5, from: 3000).withUnsafeBufferPointer { meter.publishOnsets($0) }
        XCTAssertEqual(meter.onsets(after: seq, into: &out), 3005)
        XCTAssertEqual(out.map(\.mediaTime), (3000..<3005).map { Double($0) * 0.01 })
    }

    func testOnsetRingResetLetsStaleReadersStartOver() {
        let meter = AudioFeatureMeter()
        onsetFrames(100).withUnsafeBufferPointer { meter.publishOnsets($0) }
        meter.reset()
        onsetFrames(3).withUnsafeBufferPointer { meter.publishOnsets($0) }
        var out: [AudioOnsetFrame] = []
        XCTAssertEqual(meter.onsets(after: 100, into: &out), 3)
        XCTAssertEqual(out.count, 3)
    }

    func testOnsetRingSanitizesBadEnergies() {
        let meter = AudioFeatureMeter()
        [AudioOnsetFrame(mediaTime: 1, duration: 0.01, low: .nan, mid: -1, high: .infinity)]
            .withUnsafeBufferPointer { meter.publishOnsets($0) }
        var out: [AudioOnsetFrame] = []
        _ = meter.onsets(after: 0, into: &out)
        XCTAssertEqual(out.first, AudioOnsetFrame(mediaTime: 1, duration: 0.01, low: 0, mid: 0, high: 0))
    }

    func testIsEnabledTogglesAndDefaultsOff() {
        let meter = AudioFeatureMeter()
        XCTAssertFalse(meter.isEnabled)
        meter.isEnabled = true
        XCTAssertTrue(meter.isEnabled)
        meter.isEnabled = false
        XCTAssertFalse(meter.isEnabled)
    }

    func testPublishSanitizesNonFiniteLevels() {
        let meter = AudioFeatureMeter()
        meter.publish(AudioBandLevels(low: .nan, mid: .infinity, high: -0.2, full: 0.3))
        XCTAssertEqual(meter.latest().levels, AudioBandLevels(low: 0, mid: 0, high: 0, full: 0.3))
    }

    func testConcurrentPublishAndReadDoesNotCrashOrLoseSequence() {
        let meter = AudioFeatureMeter()
        let iterations = 8
        let publishesPerIteration = 2_000
        DispatchQueue.concurrentPerform(iterations: iterations) { worker in
            for j in 0..<publishesPerIteration {
                let v = Float(j % 100) / 100
                meter.publish(AudioBandLevels(low: v, mid: v, high: v, full: v))
                _ = meter.latest()
                if j % 64 == 0 { meter.isEnabled = (worker + j) % 2 == 0 }
            }
        }
        XCTAssertEqual(meter.latest().sequence, UInt64(iterations * publishesPerIteration))
    }

    // MARK: - 与处理抽头的集成

    /// 用 `AVAssetReaderAudioMixOutput` 离线驱动同一个 `MTAudioProcessingTap`：
    /// 关闭时共享电平表一次都不应被写入，打开后应收到有限、非零的电平。
    func testProcessingTapPublishesToSharedMeterOnlyWhenEnabled() async throws {
        let m4a = try TestAudioFixture.makeM4A(in: tempDir, name: "meter-tap.m4a", seconds: 1)
        let meter = AudioFeatureMeter.shared
        meter.reset()

        meter.isEnabled = false
        try await readThroughTap(url: m4a)
        XCTAssertEqual(meter.latest().sequence, 0)

        meter.isEnabled = true
        try await readThroughTap(url: m4a)
        let reading = meter.latest()
        XCTAssertGreaterThan(reading.sequence, 0)
        XCTAssertNotNil(reading.timestamp)
        XCTAssertTrue(reading.levels.full.isFinite)
        XCTAssertGreaterThan(reading.levels.full, 0)
        // 起音格子带着歌曲时间：从 0 开始、单调递增、不超过文件长度。
        var onsets: [AudioOnsetFrame] = []
        _ = meter.onsets(after: 0, into: &onsets)
        XCTAssertGreaterThan(onsets.count, 50, "1 秒音频约 86 格")
        XCTAssertEqual(onsets.first?.mediaTime ?? -1, 0, accuracy: 0.02)
        XCTAssertTrue(zip(onsets, onsets.dropFirst()).allSatisfy { $1.mediaTime > $0.mediaTime })
        XCTAssertLessThan(onsets.last?.mediaTime ?? 99, 1.05)
        meter.isEnabled = false
    }

    private func readThroughTap(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let maybeBuilt = await AudioProcessingTap.buildAudioMix(for: asset, hub: AudioEffectsHub())
        let built = try XCTUnwrap(maybeBuilt)
        defer { built.handle.detach() }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: nil)
        output.audioMix = built.mix
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        while output.copyNextSampleBuffer() != nil {}
        XCTAssertEqual(reader.status, .completed)
    }
}
