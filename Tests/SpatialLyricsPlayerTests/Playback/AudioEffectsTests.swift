import AVFoundation
import XCTest
@testable import SpatialLyricsPlayer

final class AudioEffectsTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slp-audio-effects-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        AudioEffectsHub.shared.configure(
            loudnessEnabled: true,
            bandGainsDB: EqualizerPreset.off.defaultGainsDB
        )
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - EqualizerSpec & EqualizerPreset

    func testEqualizerSpecParsesClampsAndSerializesBands() {
        XCTAssertEqual(EqualizerSpec.bands.count, EqualizerSpec.bandCount)
        XCTAssertEqual(EqualizerSpec.parseBands("bad,1,2"), [0, 0, 0, 0, 0])
        XCTAssertEqual(EqualizerSpec.parseBands("25, -30, 3.5, NaN, inf"), [12, -12, 3.5, 0, 0])
        XCTAssertEqual(EqualizerSpec.serializeBands([20, -20, 1.25]), "12.0,-12.0,1.2,0.0,0.0")

        for preset in EqualizerPreset.allCases {
            XCTAssertEqual(preset.defaultGainsDB.count, EqualizerSpec.bandCount)
            XCTAssertFalse(preset.displayName.isEmpty)
        }
    }

    // MARK: - DSP & Soft Limiter

    func testProcessorBypassAndSoftLimiter() {
        XCTAssertEqual(AudioEffectsProcessor.softLimit(0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(AudioEffectsProcessor.softLimit(-0.92), -0.92, accuracy: 1e-12)
        XCTAssertLessThan(AudioEffectsProcessor.softLimit(5.0), 1.0)
        XCTAssertGreaterThan(AudioEffectsProcessor.softLimit(-5.0), -1.0)

        var processor = AudioEffectsProcessor(
            sampleRate: 44_100,
            channelCount: 2,
            bandGainsDB: EqualizerPreset.off.defaultGainsDB,
            loudnessGain: 1.0
        )
        XCTAssertTrue(processor.isEQBypassed)

        let frames = 256
        var left = (0..<frames).map { Float(0.25 * sin(2 * Double.pi * 1000 * Double($0) / 44_100)) }
        var right = left
        let expected = left

        left.withUnsafeMutableBufferPointer { lPtr in
            right.withUnsafeMutableBufferPointer { rPtr in
                processor.processPlanar([lPtr, rPtr], frameCount: frames)
            }
        }
        for i in 0..<frames {
            XCTAssertEqual(left[i], expected[i], accuracy: 1e-6)
            XCTAssertEqual(right[i], expected[i], accuracy: 1e-6)
        }
    }

    func testBiquadFiltersBoostAndCutTargetFrequenciesAndMatchPlanarInterleaved() {
        let sampleRate = 44_100.0
        let frames = 4096

        func measureRMS(frequencyHz: Double, gainsDB: [Double]) -> Double {
            var proc = AudioEffectsProcessor(
                sampleRate: sampleRate,
                channelCount: 2,
                bandGainsDB: gainsDB,
                loudnessGain: 1.0
            )
            var left = (0..<frames).map {
                Float(0.1 * sin(2 * Double.pi * frequencyHz * Double($0) / sampleRate))
            }
            var right = left
            left.withUnsafeMutableBufferPointer { lPtr in
                right.withUnsafeMutableBufferPointer { rPtr in
                    proc.processPlanar([lPtr, rPtr], frameCount: frames)
                }
            }
            let steadyStart = frames / 2
            let slice = left[steadyStart..<frames]
            let meanSq = slice.reduce(0.0) { $0 + Double($1 * $1) } / Double(slice.count)
            return sqrt(meanSq)
        }

        let flat25 = measureRMS(frequencyHz: 25, gainsDB: [0, 0, 0, 0, 0])
        let boost25 = measureRMS(frequencyHz: 25, gainsDB: [9, 0, 0, 0, 0])
        let cut25 = measureRMS(frequencyHz: 25, gainsDB: [-9, 0, 0, 0, 0])
        let flat3600WithBassBoost = measureRMS(frequencyHz: 3600, gainsDB: [9, 0, 0, 0, 0])
        let flat3600 = measureRMS(frequencyHz: 3600, gainsDB: [0, 0, 0, 0, 0])
        let boost3600 = measureRMS(frequencyHz: 3600, gainsDB: [0, 0, 0, 9, 0])
        let cut3600 = measureRMS(frequencyHz: 3600, gainsDB: [0, 0, 0, -9, 0])

        XCTAssertGreaterThan(boost25, flat25 * 2.2)
        XCTAssertLessThan(cut25, flat25 * 0.45)
        XCTAssertEqual(flat3600WithBassBoost / flat3600, 1.0, accuracy: 0.08)
        XCTAssertGreaterThan(boost3600, flat3600 * 2.2)
        XCTAssertLessThan(cut3600, flat3600 * 0.45)

        // Planar 与 Interleaved 对同一立体声缓冲的处理结果必须完全一致。
        let gains = EqualizerPreset.vocal.defaultGainsDB
        var planarProc = AudioEffectsProcessor(sampleRate: sampleRate, channelCount: 2, bandGainsDB: gains, loudnessGain: 1.2)
        var interleavedProc = AudioEffectsProcessor(sampleRate: sampleRate, channelCount: 2, bandGainsDB: gains, loudnessGain: 1.2)

        let n = 512
        var pLeft = (0..<n).map { Float(0.15 * sin(2 * Double.pi * 440 * Double($0) / sampleRate)) }
        var pRight = (0..<n).map { Float(0.12 * cos(2 * Double.pi * 880 * Double($0) / sampleRate)) }
        var interleaved = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            interleaved[i * 2] = pLeft[i]
            interleaved[i * 2 + 1] = pRight[i]
        }
        pLeft.withUnsafeMutableBufferPointer { lPtr in
            pRight.withUnsafeMutableBufferPointer { rPtr in
                planarProc.processPlanar([lPtr, rPtr], frameCount: n)
            }
        }
        interleaved.withUnsafeMutableBufferPointer { iPtr in
            interleavedProc.processInterleaved(iPtr, frameCount: n, stride: 2)
        }
        for i in 0..<n {
            XCTAssertEqual(pLeft[i], interleaved[i * 2], accuracy: 1e-6)
            XCTAssertEqual(pRight[i], interleaved[i * 2 + 1], accuracy: 1e-6)
        }
    }

    // MARK: - LoudnessAnalyzer & LoudnessCache

    func testLoudnessAnalyzerMeasuresQuietHotAndSilentSignals() {
        XCTAssertNil(LoudnessAnalyzer.analyzeSamples([Float](repeating: 0.0005, count: 2048)))

        let quiet = (0..<4096).map { Float(0.04 * sin(2 * Double.pi * 440 * Double($0) / 44_100)) }
        let quietProfile = LoudnessAnalyzer.analyzeSamples(quiet)
        XCTAssertNotNil(quietProfile)
        XCTAssertGreaterThan(quietProfile!.recommendedGain, 1.4)
        XCTAssertLessThanOrEqual(quietProfile!.recommendedGain, LoudnessAnalyzer.gainRange.upperBound)

        let hot = (0..<4096).map { Float(0.85 * sin(2 * Double.pi * 440 * Double($0) / 44_100)) }
        let hotProfile = LoudnessAnalyzer.analyzeSamples(hot)
        XCTAssertNotNil(hotProfile)
        XCTAssertLessThan(hotProfile!.recommendedGain, 0.5)
        XCTAssertLessThanOrEqual(Double(hotProfile!.recommendedGain) * hotProfile!.peak, 0.99)

        // 前奏长静音不能把活跃响度拉低。
        let padded = [Float](repeating: 0.0, count: 16_384) + hot
        let paddedProfile = LoudnessAnalyzer.analyzeSamples(padded)
        XCTAssertEqual(paddedProfile?.rms ?? 0, hotProfile?.rms ?? -1, accuracy: 1e-4)
    }

    func testLoudnessCacheAnalyzesM4AFilesAndPersistsToDisk() async throws {
        let m4a = try TestAudioFixture.makeM4A(in: tempDir, name: "tone.m4a", seconds: 2)
        let storeURL = tempDir.appendingPathComponent("loudness.json")

        let cache = LoudnessCache(fileURL: storeURL)
        let profile = await cache.measureIfNeeded(key: "track-1", url: m4a)
        XCTAssertNotNil(profile)
        let cached = await cache.cachedProfile(forKey: "track-1")
        XCTAssertEqual(cached?.rms, profile?.rms)
        XCTAssertEqual(cached?.recommendedGain, profile?.recommendedGain)

        // 重建实例应从磁盘 JSON 读出同一份档案。
        let reloaded = LoudnessCache(fileURL: storeURL)
        let reloadedProfile = await reloaded.cachedProfile(forKey: "track-1")
        XCTAssertEqual(reloadedProfile?.recommendedGain, profile?.recommendedGain)

        await reloaded.clear()
        let cleared = await reloaded.cachedProfile(forKey: "track-1")
        XCTAssertNil(cleared)
    }

    // MARK: - AudioProcessingTap & BilibiliPlayerSession

    @MainActor
    func testAudioProcessingTapAndBilibiliPlayerSessionPrepareLifecycle() async throws {
        let m4a = try TestAudioFixture.makeM4A(in: tempDir, name: "session-eq.m4a", seconds: 2)
        let hub = AudioEffectsHub()
        hub.configure(loudnessEnabled: true, bandGainsDB: EqualizerPreset.warm.defaultGainsDB)

        let built = await AudioProcessingTap.buildAudioMix(
            for: AVURLAsset(url: m4a),
            trackLoudnessGain: 1.25,
            hub: hub
        )
        XCTAssertNotNil(built)
        built?.handle.setTrackLoudnessGain(0.8)
        hub.configure(loudnessEnabled: false, bandGainsDB: EqualizerPreset.bright.defaultGainsDB)
        built?.handle.detach()

        let stream = AudioStreamDescriptor(
            cacheKey: "eq-probe",
            fileExtension: "m4a",
            qualityTier: .standard,
            qualityID: 30216,
            codec: "AAC",
            bandwidth: 64_000,
            sampleRate: 44_100,
            isLossless: false,
            url: m4a
        )
        let session = try HTTPStreamPlayerSession(stream: stream, localURL: m4a, title: "eq-probe")
        try await session.prepare()
        XCTAssertGreaterThan(session.duration, 0)
        await session.invalidate()
    }

    // MARK: - AppearanceSettings Integration

    @MainActor
    func testAppearanceSettingsSyncsHubAndPersistsEQAndLoudness() async {
        let store = InMemorySettingsStore()
        let appearance = AppearanceSettings(settings: store)

        XCTAssertTrue(appearance.loudnessNormalizationEnabled)
        XCTAssertEqual(appearance.eqPreset, .off)
        XCTAssertEqual(appearance.effectiveEQBands, [0, 0, 0, 0, 0])

        appearance.setLoudnessNormalizationEnabled(false)
        appearance.setEQPreset(.vocal)
        XCTAssertFalse(AudioEffectsHub.shared.currentConfiguration.loudnessEnabled)
        XCTAssertEqual(AudioEffectsHub.shared.currentConfiguration.bandGainsDB, EqualizerPreset.vocal.defaultGainsDB)

        appearance.setEQBand(index: 0, gainDB: 5.5)
        XCTAssertEqual(appearance.eqPreset, .custom)
        XCTAssertEqual(appearance.eqBands[0], 5.5, accuracy: 0.001)
        XCTAssertEqual(AudioEffectsHub.shared.currentConfiguration.bandGainsDB[0], 5.5, accuracy: 0.001)

        appearance.resetEQ()
        XCTAssertEqual(appearance.eqPreset, .off)
        XCTAssertEqual(appearance.effectiveEQBands, [0, 0, 0, 0, 0])

        for _ in 0..<50 where store.eqBandsRaw != "0.0,0.0,0.0,0.0,0.0" || store.loudnessNormalizationEnabled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.loudnessNormalizationEnabled)
        XCTAssertEqual(store.eqPresetRaw, EqualizerPreset.off.rawValue)
        XCTAssertEqual(store.eqBandsRaw, "0.0,0.0,0.0,0.0,0.0")
    }
}
