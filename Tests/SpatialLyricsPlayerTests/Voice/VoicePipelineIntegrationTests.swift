import AVFoundation
import XCTest
@testable import SpatialLyricsPlayer

/// FLOW Voice 任务调度、缓存失效、播放协同（离线+预热）及端到端原生推理集成测试。
@MainActor
final class VoicePipelineIntegrationTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-integ-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeSettings(network: Bool = false) -> InMemorySettingsStore {
        InMemorySettingsStore(enableNetwork: network)
    }

    private func makeManager(
        rootSubpath: String = "Voice",
        network: Bool = false
    ) -> (manager: VoiceManager, cache: VoiceCacheManager, assets: VoiceModelAssetsManager, root: URL) {
        let root = tempDir.appendingPathComponent(rootSubpath, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = makeSettings(network: network)
        let packStore = VoicePackStore(packsRoot: root.appendingPathComponent("Packs", isDirectory: true))
        let cache = VoiceCacheManager(rootURL: root)
        let assets = VoiceModelAssetsManager(voiceRoot: root)
        let presets = VoicePresetStore(directory: root)
        let manager = VoiceManager(
            settings: settings,
            packStore: packStore,
            cache: cache,
            assets: assets,
            presetStore: presets
        )
        return (manager, cache, assets, root)
    }

    func testVoiceTaskManagerCancelTransitionsCleanlyWithoutTrailingOverwrite() async throws {
        let cache = VoiceCacheManager(rootURL: tempDir)
        let assets = VoiceModelAssetsManager(voiceRoot: tempDir)
        var events: [(String, VoiceTaskState)] = []
        let mgr = VoiceTaskManager(
            cache: cache,
            assets: assets,
            allowNetwork: { false },
            onStateChanged: { id, st in events.append((id, st)) }
        )

        let dummyWav = tempDir.appendingPathComponent("dummy.wav")
        try VoiceAudioDSP.writeWAV(left: [Float](repeating: 0.1, count: 16_000), right: nil, sampleRate: 16_000, to: dummyWav)
        let dummyONNX = tempDir.appendingPathComponent("m.onnx")
        try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64)).write(to: dummyONNX)

        let job = VoiceConversionJob(
            jobID: "job-cancel-1",
            trackKey: "t1",
            inputPath: dummyWav.path,
            outputPath: cache.renderURL(renderKey: "rk-cancel").path,
            packID: "p1",
            versionID: "v1",
            engineID: "rvc",
            weightPath: dummyONNX.path,
            sampleRate: 40_000,
            parameters: ["separation_model": .string("none")],
            pipelineVersion: VoiceCacheManager.pipelineVersion
        )
        _ = try mgr.enqueue(job: job)
        mgr.cancel(jobID: "job-cancel-1")
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(mgr.state(for: "job-cancel-1"), .cancelled)
        XCTAssertFalse(events.contains { _, st in
            if case .succeeded = st { return true }
            return false
        })
    }

    func testVoiceManagerInvalidatesRenderCacheOnPackAndParamChanges() async throws {
        let settings = makeSettings()
        let packStore = VoicePackStore(packsRoot: tempDir.appendingPathComponent("Packs"))
        let cache = VoiceCacheManager(rootURL: tempDir)
        let assets = VoiceModelAssetsManager(voiceRoot: tempDir)
        let presets = VoicePresetStore(directory: tempDir)
        let manager = VoiceManager(
            settings: settings,
            packStore: packStore,
            cache: cache,
            assets: assets,
            presetStore: presets
        )

        let modelURL = tempDir.appendingPathComponent("voice_a.onnx")
        try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64)).write(to: modelURL)
        let pack = try await manager.importPack(weightURL: modelURL, displayName: "VoiceA")

        let track = Track(
            id: UUID(),
            sourceID: "local",
            externalID: "ext",
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 10
        )
        let tKey = TrackIdentity.storageKey(track.identity)
        manager.renders[tKey] = VoiceRender(
            trackKey: tKey,
            cacheKey: "r1",
            fileURL: tempDir.appendingPathComponent("r1.m4a"),
            duration: 10,
            sampleRate: 44100,
            packID: pack.packID,
            versionID: "v1",
            pipelineVersion: 2
        )

        var invalidatedCount = 0
        manager.onVoiceContextChanged = { invalidatedCount += 1 }
        manager.setParameterOverride(packID: pack.packID, key: "f0_up_key", value: .int(4))

        XCTAssertNil(manager.existingRender(for: track), "调参后必须失效旧内存渲染引用")
        XCTAssertGreaterThanOrEqual(invalidatedCount, 1)

        manager.qualityMode = .best
        XCTAssertGreaterThanOrEqual(invalidatedCount, 2)
    }

    func testPlaybackCoordinatorSupportsOfflineVoiceSessionAndGaplessPrewarm() async throws {
        let registry = SourceRegistry()
        let coord = PlaybackCoordinator(registry: registry)

        let aiFile = tempDir.appendingPathComponent("ai_cached.wav")
        try VoiceAudioDSP.writeWAV(
            left: [Float](repeating: 0.2, count: 44_100),
            right: [Float](repeating: 0.2, count: 44_100),
            sampleRate: 44_100,
            to: aiFile
        )

        let track1 = Track(id: UUID(), sourceID: "bili", externalID: "b1", title: "Offline AI 1", artist: "A", duration: 1)
        let track2 = Track(id: UUID(), sourceID: "bili", externalID: "b2", title: "Offline AI 2", artist: "A", duration: 1)

        coord.isNetworkEnabled = { false }
        coord.offlineSessionFactory = { _ in nil }
        coord.voiceSessionFactory = { t, _ in
            let stream = AudioStreamDescriptor(
                cacheKey: "\(t.id)#voice",
                fileExtension: "wav",
                qualityTier: .lossless,
                qualityID: 0,
                codec: "PCM",
                bandwidth: 0,
                sampleRate: 44_100,
                isLossless: true,
                url: aiFile
            )
            return try await MainActor.run {
                try HTTPStreamPlayerSession(stream: stream, localURL: aiFile, title: t.title)
            }
        }

        // 1. 即使未注册流媒体源且关闭联网、offlineSession 为 nil，只要 AI 会话就绪就应起播成功
        let dur1 = try await coord.beginLoading(track: track1, startAt: 0)
        XCTAssertGreaterThan(dur1, 0.5)
        XCTAssertFalse(coord.lastLoadWasGaplessHit)

        // 2. Gapless 预热 track2 的 AI 会话后切歌应直接命中 standby
        coord.prewarm(track: track2)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(coord.prewarmedTrackID, track2.id)

        let dur2 = try await coord.beginLoading(track: track2, startAt: 0, preferGaplessTransition: true)
        XCTAssertGreaterThan(dur2, 0.5)
        XCTAssertTrue(coord.lastLoadWasGaplessHit)
        XCTAssertEqual(coord.standbyHitCount, 1)
    }

    func testNativeEndToEndONNXVoiceConversionWhenModelsPresent() async throws {
        let appSupportModels = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FLOW/Voice/Models", isDirectory: true)
        let rmvpeSrc = appSupportModels.appendingPathComponent("rmvpe.onnx")
        let hubertSrc = appSupportModels.appendingPathComponent("hubert_base.onnx")
        let voicePackSrc = URL(fileURLWithPath: "/tmp/voice_ref/f0G40k.voicepack", isDirectory: true)
        let inputSong = URL(fileURLWithPath: "/tmp/voice_ref/input_song.wav")

        guard FileManager.default.fileExists(atPath: rmvpeSrc.path),
              FileManager.default.fileExists(atPath: hubertSrc.path),
              FileManager.default.fileExists(atPath: voicePackSrc.appendingPathComponent("model.onnx").path),
              FileManager.default.fileExists(atPath: inputSong.path) else {
            return
        }

        let voiceRoot = tempDir.appendingPathComponent("E2EVoiceRoot", isDirectory: true)
        let modelsDir = voiceRoot.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: modelsDir.appendingPathComponent("rmvpe.onnx"), withDestinationURL: rmvpeSrc)
        try FileManager.default.createSymbolicLink(at: modelsDir.appendingPathComponent("hubert_base.onnx"), withDestinationURL: hubertSrc)

        let settings = makeSettings(network: false)
        let packStore = VoicePackStore(packsRoot: voiceRoot.appendingPathComponent("Packs", isDirectory: true))
        let cache = VoiceCacheManager(rootURL: voiceRoot)
        let assets = VoiceModelAssetsManager(voiceRoot: voiceRoot)
        let presets = VoicePresetStore(directory: voiceRoot)

        let manager = VoiceManager(
            settings: settings,
            packStore: packStore,
            cache: cache,
            assets: assets,
            presetStore: presets
        )
        await manager.attach()

        let manifest = try await manager.importPack(weightURL: voicePackSrc)
        try manager.setParameterOverrides(packID: manifest.packID, overrides: [
            "f0_up_key": .int(0),
            "separation_model": .string("none"),
            "rms_mix_rate": .double(0.25),
            "protect": .double(0.33),
        ])

        let track = Track(
            id: UUID(),
            sourceID: "local",
            externalID: "e2e",
            title: "InputSong",
            artist: "Test",
            duration: 4.8
        )
        _ = try await manager.requestRender(for: track, inputAudioURL: inputSong)

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let rendered = manager.existingRender(for: track) {
                XCTAssertTrue(FileManager.default.fileExists(atPath: rendered.fileURL.path))
                XCTAssertEqual(rendered.fileURL.pathExtension, "m4a")
                XCTAssertGreaterThan(rendered.duration, 3.0)
                let decoded = try VoiceAudioDSP.decodeMono(url: rendered.fileURL, targetSampleRate: 16_000)
                let rms = sqrt(decoded.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(decoded.count, 1)))
                XCTAssertGreaterThan(rms, 0.005, "合成输出不能是静音")
                return
            }
            if let err = manager.lastError {
                XCTFail("原生 E2E 推理失败: \(err)")
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("原生 E2E 推理超时")
    }

    func testForceRenderInvalidatesRenderAndConversionWhileKeepingSeparationCache() async throws {
        let setup = makeManager(rootSubpath: "ForceRender")
        let manager = setup.manager
        let cache = setup.cache
        await manager.attach()

        let modelURL = tempDir.appendingPathComponent("force_pack.onnx")
        try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64)).write(to: modelURL)
        let pack = try await manager.importPack(weightURL: modelURL, displayName: "ForcePack")
        let version = try XCTUnwrap(pack.selectedVersion)

        let inputURL = tempDir.appendingPathComponent("force_input.wav")
        try VoiceAudioDSP.writeWAV(
            left: [Float](repeating: 0.15, count: 16_000),
            right: nil,
            sampleRate: 16_000,
            to: inputURL
        )
        let track = Track(
            id: UUID(),
            sourceID: "local",
            externalID: "force-1",
            title: "Force Song",
            artist: "Tester",
            duration: 1
        )
        let tKey = TrackIdentity.storageKey(track.identity)
        let keys = try await manager.cacheKeys(
            for: track,
            pack: pack,
            version: version,
            inputAudioURL: inputURL
        )

        // 预置三级缓存：一级分离 + 二级转换人声 + 三级成品与清单
        try VoiceAudioDSP.writeWAV(left: [Float](repeating: 0.1, count: 100), right: nil, sampleRate: 16_000, to: cache.vocalsURL(sepKey: keys.separationKey))
        try VoiceAudioDSP.writeWAV(left: [Float](repeating: 0.1, count: 100), right: nil, sampleRate: 16_000, to: cache.instURL(sepKey: keys.separationKey))
        try VoiceAudioDSP.writeWAV(left: [Float](repeating: 0.1, count: 100), right: nil, sampleRate: 16_000, to: cache.convertedVocalsURL(convKey: keys.conversionKey))
        try Data("fake-m4a".utf8).write(to: cache.renderURL(renderKey: keys.renderKey))
        try cache.writeRenderManifest(VoiceRender(
            trackKey: tKey,
            cacheKey: keys.renderKey,
            fileURL: cache.renderURL(renderKey: keys.renderKey),
            duration: 1,
            sampleRate: 44_100,
            packID: pack.packID,
            versionID: version.id,
            pipelineVersion: VoiceCacheManager.pipelineVersion
        ))

        let hit = try await manager.requestRender(for: track, inputAudioURL: inputURL)
        XCTAssertNotNil(hit)
        XCTAssertNotNil(manager.existingRender(for: track))

        // force: true 应清理二/三级缓存并重新入队，同时保留一级人声分离缓存
        let forcedReturn = try await manager.requestRender(for: track, inputAudioURL: inputURL, force: true)
        XCTAssertNil(forcedReturn)
        XCTAssertNil(manager.existingRender(for: track))
        XCTAssertFalse(cache.conversionExists(convKey: keys.conversionKey))
        XCTAssertFalse(cache.renderExists(renderKey: keys.renderKey))
        XCTAssertTrue(cache.separationExists(sepKey: keys.separationKey))
        XCTAssertNotNil(manager.taskInfo(for: track))

        manager.cancelRender(trackKey: tKey)
        try await Task.sleep(for: .milliseconds(80))
    }

    func testRequestRenderForUncachedOnlineTrackSetsTrackErrorAndClearsWhenCached() async throws {
        let setup = makeManager(rootSubpath: "UncachedFeedback")
        let manager = setup.manager
        await manager.attach()

        let modelURL = tempDir.appendingPathComponent("uncached_pack.onnx")
        try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64)).write(to: modelURL)
        _ = try await manager.importPack(weightURL: modelURL, displayName: "UncachedPack")
        manager.isEnabled = true

        let onlineTrack = Track(
            id: UUID(),
            sourceID: "bili",
            externalID: "BV1uncached",
            title: "Online Only",
            artist: "Streamer",
            duration: 120
        )
        let otherTrack = Track(
            id: UUID(),
            sourceID: "bili",
            externalID: "BV1other",
            title: "Other Track",
            artist: "Streamer",
            duration: 120
        )

        var resolvedURL: URL?
        manager.inputResolver = { _ in resolvedURL }

        do {
            _ = try await manager.requestRender(for: onlineTrack)
            XCTFail("未缓存的在线曲目在显式生成时应给出明确错误反馈")
        } catch let err as VoiceError {
            XCTAssertFalse(err.localizedDescription.isEmpty)
        }

        XCTAssertNotNil(manager.errorMessage(for: onlineTrack))
        XCTAssertNil(manager.errorMessage(for: otherTrack), "错误提示应按曲目隔离，不能串台到其他歌曲")

        let cachedWav = tempDir.appendingPathComponent("now_cached.wav")
        try VoiceAudioDSP.writeWAV(left: [Float](repeating: 0.1, count: 16_000), right: nil, sampleRate: 16_000, to: cachedWav)
        resolvedURL = cachedWav
        await manager.refreshRenderAvailability(for: onlineTrack)
        XCTAssertNil(manager.errorMessage(for: onlineTrack), "歌曲落盘缓存后，旧的未缓存错误提示应自动清除")
    }

    func testTrackSwitchNeverAutoQueuesRenderEvenWhenFullyEligible() async throws {
        let setup = makeManager(rootSubpath: "OptionalAutoQueue")
        let manager = setup.manager
        let assets = setup.assets
        await manager.attach()

        // 1. 初始状态：可选功能默认关闭、无音色包、无底座模型
        XCTAssertFalse(manager.isEnabled)
        XCTAssertTrue(manager.packs.isEmpty)
        XCTAssertFalse(manager.baseModelsReady)

        let localWav = tempDir.appendingPathComponent("auto_local.wav")
        try VoiceAudioDSP.writeWAV(left: [Float](repeating: 0.1, count: 16_000), right: nil, sampleRate: 16_000, to: localWav)
        final class ResolverBox: @unchecked Sendable {
            var urls: [UUID: URL] = [:]
        }
        let resolverBox = ResolverBox()
        let resolver: @MainActor (Track) async -> URL? = { resolverBox.urls[$0.id] }
        manager.inputResolver = resolver
        let driver = VoicePlaybackDriver(voice: manager, inputResolver: resolver)

        let localTrack = Track(id: UUID(), sourceID: "local", externalID: "loc-1", title: "Local", artist: "A", duration: 1)
        let onlineTrack = Track(id: UUID(), sourceID: "bili", externalID: "bili-1", title: "Online", artist: "B", duration: 1)
        resolverBox.urls[localTrack.id] = localWav

        let ctxLocal = PlaybackContext(
            trackID: localTrack.id,
            duration: 1,
            anchor: .anchored(at: 0, now: SystemPlaybackClock().now, rate: 0),
            retryCount: 0,
            pauseReason: nil,
            pendingAutoplay: true
        )

        // 未开启时切歌：完全静默，不入队不报错
        await driver.handlePlaybackStateChange(state: .playing(ctxLocal), track: localTrack)
        XCTAssertNil(manager.taskInfo(for: localTrack))
        XCTAssertNil(manager.lastError)

        // 2. 开启但尚无底座模型（初始不自带模型场景）：切歌仍必须保持静默
        let modelURL = tempDir.appendingPathComponent("auto_pack.onnx")
        try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64)).write(to: modelURL)
        let pack = try await manager.importPack(weightURL: modelURL, displayName: "AutoPack")
        try manager.setParameterOverrides(packID: pack.packID, overrides: ["separation_model": .string("none")])
        manager.isEnabled = true

        XCTAssertFalse(manager.baseModelsReady)
        let ctxOnline = PlaybackContext(
            trackID: onlineTrack.id,
            duration: 1,
            anchor: .anchored(at: 0, now: SystemPlaybackClock().now, rate: 0),
            retryCount: 0,
            pauseReason: nil,
            pendingAutoplay: true
        )
        await driver.handlePlaybackStateChange(state: .preparing(ctxOnline), track: onlineTrack)
        XCTAssertNil(manager.taskInfo(for: onlineTrack))
        XCTAssertNil(manager.lastError)

        // 3. 开关、底座模型、音色、本地音频全部就绪：搜索/切歌播放仍不得自动入队（用户反馈"搜索播放后自动触发"）
        try Data(repeating: 0x01, count: 2048).write(to: assets.url(for: .rmvpe))
        try Data(repeating: 0x02, count: 2048).write(to: assets.url(for: .hubert))
        manager.refreshEnvironmentStatus()
        XCTAssertTrue(manager.baseModelsReady)

        let ctxOnline2 = PlaybackContext(
            trackID: onlineTrack.id,
            duration: 1,
            anchor: .anchored(at: 0, now: SystemPlaybackClock().now, rate: 0),
            retryCount: 0,
            pauseReason: nil,
            pendingAutoplay: true
        )
        await driver.handlePlaybackStateChange(state: .preparing(ctxOnline2), track: onlineTrack)
        XCTAssertNil(manager.taskInfo(for: onlineTrack))
        XCTAssertNil(manager.errorMessage(for: onlineTrack))

        // 在线音频随后缓存落盘、进入 .playing，以及落盘回调：都只刷新命中，不入队
        resolverBox.urls[onlineTrack.id] = localWav
        await driver.handlePlaybackStateChange(state: .playing(ctxOnline2), track: onlineTrack)
        await driver.handleAudioCachedOnCurrentTrack()
        XCTAssertNil(manager.taskInfo(for: onlineTrack), "缓存落盘后也不能自动开始转换")

        await driver.handlePlaybackStateChange(state: .preparing(ctxLocal), track: localTrack)
        await driver.handlePlaybackStateChange(state: .playing(ctxLocal), track: localTrack)
        XCTAssertNil(manager.taskInfo(for: localTrack), "条件全部就绪时切歌也只能由用户显式生成")
        XCTAssertNil(manager.lastError)

        // 显式请求仍然正常入队
        _ = try await manager.requestRender(for: localTrack)
        XCTAssertNotNil(manager.taskInfo(for: localTrack))
        manager.cancelRender(trackKey: TrackIdentity.storageKey(localTrack.identity))
        try await Task.sleep(for: .milliseconds(80))
    }

    func testStoredCoversGroupByTrackAndPackAndDeleteFreesOwnedIntermediates() async throws {
        let setup = makeManager(rootSubpath: "StoredCovers")
        let manager = setup.manager
        let cache = setup.cache
        await manager.attach()

        let modelURL = tempDir.appendingPathComponent("covers_pack.onnx")
        try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64)).write(to: modelURL)
        let pack = try await manager.importPack(weightURL: modelURL, displayName: "高松灯")
        let version = try XCTUnwrap(pack.selectedVersion)

        let songA = Track(sourceID: "js-bilibili", externalID: "BV-a", title: "春日影", artist: "MyGO", duration: 0)
        let songB = Track(sourceID: "js-bilibili", externalID: "BV-b", title: "迷星叫", artist: "MyGO", duration: 200)
        let keyA = TrackIdentity.storageKey(songA.identity)
        let keyB = TrackIdentity.storageKey(songB.identity)

        func writeRender(_ renderKey: String, track: Track, sep: String, conv: String, age: TimeInterval) throws {
            try Data(repeating: 1, count: 64).write(to: cache.vocalsURL(sepKey: sep))
            try Data(repeating: 1, count: 64).write(to: cache.instURL(sepKey: sep))
            try Data(repeating: 2, count: 32).write(to: cache.convertedVocalsURL(convKey: conv))
            try Data(repeating: 3, count: 16).write(to: cache.renderURL(renderKey: renderKey))
            try cache.writeRenderManifest(
                VoiceRender(trackKey: TrackIdentity.storageKey(track.identity), cacheKey: renderKey,
                            fileURL: cache.renderURL(renderKey: renderKey), duration: 180, sampleRate: 44_100,
                            packID: pack.packID, versionID: version.id,
                            pipelineVersion: VoiceCacheManager.pipelineVersion),
                metadata: .init(track: track, packName: "高松灯", separationKey: sep, conversionKey: conv)
            )
            let manifest = cache.url(for: .manifests).appendingPathComponent("\(renderKey).json")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
            json["createdAt"] = Date().addingTimeInterval(-age).timeIntervalSinceReferenceDate
            try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        }

        // A 同音色生成过两次（调过参数），共享同一份人声分离；B 一次
        try writeRender("render-3-a-old", track: songA, sep: "sep-3-a", conv: "vc-3-a-old", age: 300)
        try writeRender("render-3-a-new", track: songA, sep: "sep-3-a", conv: "vc-3-a-new", age: 100)
        try writeRender("render-3-b", track: songB, sep: "sep-3-b", conv: "vc-3-b", age: 200)
        manager.reloadStoredCovers()

        XCTAssertEqual(manager.storedCovers.map(\.trackKey), [keyA, keyB], "按最新生成时间排序，同曲同音色只列一条")
        let coverA = try XCTUnwrap(manager.storedCovers.first)
        XCTAssertEqual(coverA.id, "render-3-a-new")
        XCTAssertEqual(coverA.cacheKeys, ["render-3-a-old", "render-3-a-new"])
        XCTAssertEqual(coverA.track?.title, "春日影")
        XCTAssertEqual(manager.packName(for: coverA), "高松灯")

        let freed = manager.deleteStoredCovers([coverA])
        XCTAssertGreaterThan(freed, 0)
        XCTAssertEqual(manager.storedCovers.map(\.trackKey), [keyB])
        XCTAssertFalse(cache.renderExists(renderKey: "render-3-a-old"))
        XCTAssertFalse(cache.renderExists(renderKey: "render-3-a-new"))
        XCTAssertFalse(cache.conversionExists(convKey: "vc-3-a-old"))
        XCTAssertFalse(cache.conversionExists(convKey: "vc-3-a-new"))
        XCTAssertFalse(cache.separationExists(sepKey: "sep-3-a"), "只被 A 引用的人声分离应一并释放")
        XCTAssertTrue(cache.separationExists(sepKey: "sep-3-b"), "其他歌曲的中间文件不能误删")
        XCTAssertTrue(cache.renderExists(renderKey: "render-3-b"))

        // 音色包删除后仍显示生成时记下的名字
        try manager.deletePack(pack.packID)
        let coverB = try XCTUnwrap(manager.storedCovers.first)
        XCTAssertEqual(manager.packName(for: coverB), "高松灯")
    }

    func testPinnedStoredCoverPlaysRegardlessOfSelectedPackAndClearsOnVoiceChange() async throws {
        let setup = makeManager(rootSubpath: "PinnedCover")
        let manager = setup.manager
        let cache = setup.cache
        await manager.attach()

        let modelURL = tempDir.appendingPathComponent("pin_pack.onnx")
        try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64)).write(to: modelURL)
        let packA = try await manager.importPack(weightURL: modelURL, displayName: "PackA")
        let packB = try await manager.importPack(weightURL: modelURL, displayName: "PackB")
        XCTAssertEqual(manager.selectedPackID, packB.packID)

        let track = Track(sourceID: "js-bilibili", externalID: "BV-pin", title: "Pinned", artist: "A", duration: 1)
        let renderKey = "render-3-pinned"
        try VoiceAudioDSP.writeWAV(left: [Float](repeating: 0.1, count: 22_050), right: nil,
                                   sampleRate: 22_050, to: cache.renderURL(renderKey: renderKey))
        try cache.writeRenderManifest(
            VoiceRender(trackKey: TrackIdentity.storageKey(track.identity), cacheKey: renderKey,
                        fileURL: cache.renderURL(renderKey: renderKey), duration: 1, sampleRate: 22_050,
                        packID: packA.packID, versionID: try XCTUnwrap(packA.selectedVersion?.id),
                        pipelineVersion: VoiceCacheManager.pipelineVersion),
            metadata: .init(track: track, packName: "PackA")
        )
        manager.reloadStoredCovers()
        let cover = try XCTUnwrap(manager.storedCovers.first)

        // 底座模型缺失、当前选中的是别的音色：常规路径不会命中
        manager.inputResolver = { _ in nil }
        let driver = VoicePlaybackDriver(voice: manager, inputResolver: { _ in nil })
        XCTAssertFalse(manager.baseModelsReady)
        let unpinnedSession = try await driver.makeSessionIfAvailable(for: track)
        XCTAssertNil(unpinnedSession)

        // 离线页点播：钉住成品后直接播它，并自动打开 AI 开关
        var startedTrack: Track?
        manager.onStartTrackRequested = { startedTrack = $0 }
        await manager.playStoredCover(cover, track: track, queue: [cover])
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(startedTrack?.identity, track.identity)
        let pinnedSignature = await driver.activeRoutingSignature(for: track)
        XCTAssertEqual(pinnedSignature, renderKey)
        let pinnedSession = try await driver.makeSessionIfAvailable(for: track)
        XCTAssertNotNil(pinnedSession, "钉住的成品不依赖当前所选音色与底座模型")

        // 用户切换音色：钉住失效，回到按当前音色匹配
        manager.selectPack(packA.packID)
        let afterSwitch = await driver.activeRoutingSignature(for: track)
        XCTAssertNil(afterSwitch)

        // 删除后列表清空、文件消失
        manager.deleteStoredCovers([cover])
        XCTAssertTrue(manager.storedCovers.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.renderURL(renderKey: renderKey).path))
    }

    func testUninstallAllRemovesModelsPacksCachesAndHidesPlayerEntry() async throws {
        let setup = makeManager(rootSubpath: "UninstallAll")
        let manager = setup.manager
        let cache = setup.cache
        let assets = setup.assets
        await manager.attach()

        // 准备底座模型（含普通文件与符号链接）+ 音色包 + 渲染缓存 + 自定义预设
        try Data(repeating: 0x11, count: 4096).write(to: assets.url(for: .rmvpe))
        let externalHubert = tempDir.appendingPathComponent("external_hubert.onnx")
        try Data(repeating: 0x22, count: 4096).write(to: externalHubert)
        try FileManager.default.createSymbolicLink(at: assets.url(for: .hubert), withDestinationURL: externalHubert)
        try Data(repeating: 0x33, count: 4096).write(to: assets.url(for: .mdxSeparator))

        let modelURL = tempDir.appendingPathComponent("uninstall_pack.onnx")
        try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64)).write(to: modelURL)
        _ = try await manager.importPack(weightURL: modelURL, displayName: "UninstallPack")
        try Data("cached-render".utf8).write(to: cache.renderURL(renderKey: "rk-uninstall"))
        _ = try manager.presetStore.save(VoiceProcessingPreset(
            id: "custom-u",
            displayName: "Custom",
            parameters: ["f0_up_key": .int(2)],
            suggestedQualityMode: "balanced",
            isBuiltIn: false
        ))

        manager.isEnabled = true
        manager.refreshEnvironmentStatus()
        XCTAssertTrue(manager.baseModelsReady)
        XCTAssertTrue(manager.mdxSeparatorReady)
        XCTAssertTrue(manager.hasAnyLocalData)
        XCTAssertGreaterThan(manager.totalDiskFootprintBytes, 0)
        XCTAssertTrue(manager.showEntryInPlayer)

        // 先测单项移除 MDX 底座模型：只删模型本身，保留符号链接外部原件
        let freedMdx = try manager.removeBaseAsset(.mdxSeparator)
        XCTAssertGreaterThanOrEqual(freedMdx, 4096)
        XCTAssertFalse(manager.mdxSeparatorReady)
        XCTAssertTrue(manager.baseModelsReady)

        // 完全卸载：清空 Models / Packs / 缓存 / 自定义预设，关闭开关并隐藏播放栏入口
        var contextChanged = 0
        manager.onVoiceContextChanged = { contextChanged += 1 }
        let freedTotal = try manager.uninstallAll(hidePlayerEntry: true)

        XCTAssertGreaterThan(freedTotal, 8192)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(manager.showEntryInPlayer)
        XCTAssertFalse(manager.baseModelsReady)
        XCTAssertFalse(manager.hasAnyLocalData)
        XCTAssertEqual(manager.totalDiskFootprintBytes, 0)
        XCTAssertTrue(manager.packs.isEmpty)
        XCTAssertNil(manager.selectedPack)
        XCTAssertEqual(manager.presetStore.all.count, VoiceProcessingPreset.builtIns.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalHubert.path), "卸载只能删符号链接本身，不得删外部源文件")
        XCTAssertGreaterThanOrEqual(contextChanged, 1)

        // 卸载后若重新导入音色包，播放器入口应自动恢复显示
        _ = try await manager.importPack(weightURL: modelURL, displayName: "ReinstalledPack")
        XCTAssertTrue(manager.showEntryInPlayer)
    }

    func testPipelineVersion3AndLatestRenderFallbackWhenOriginalUncached() async throws {
        XCTAssertEqual(VoiceCacheManager.pipelineVersion, 3)
        let setup = makeManager(rootSubpath: "V3Fallback")
        let manager = setup.manager
        let cache = setup.cache
        let assets = setup.assets
        await manager.attach()

        // 写入模拟底座并导入测试音色
        for kind in VoiceModelAssetsManager.AssetKind.allCases {
            try Data(repeating: 0x02, count: 2048).write(to: assets.url(for: kind))
        }
        let onnxURL = tempDir.appendingPathComponent("v3_singer.onnx")
        try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64)).write(to: onnxURL)
        let pack = try await manager.importPack(weightURL: onnxURL, displayName: "MikuV3")
        let versionID = try XCTUnwrap(pack.selectedVersion?.id)

        // 写入旧版 pipelineVersion = 2 残留与当前 pipelineVersion = 3 渲染成品
        let oldRender = cache.renderURL(renderKey: "render-2-old")
        try Data(repeating: 0x11, count: 32).write(to: oldRender)
        let manifestsDir = cache.url(for: .manifests)
        try FileManager.default.createDirectory(at: manifestsDir, withIntermediateDirectories: true)
        let oldManifestURL = manifestsDir.appendingPathComponent("render-2-old.json")
        try Data("{}".utf8).write(to: oldManifestURL)
        cache.pruneObsoletePipelineArtifacts()
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRender.path), "旧 pipelineVersion 产物应被自动清理")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldManifestURL.path), "旧 pipelineVersion 清单应被自动清理")

        let track = Track(
            sourceID: SourceID("net-test"),
            externalID: "uncached-orig-1",
            title: "Ghost Track",
            artist: "Singer",
            duration: 4.0
        )
        let trackKey = TrackIdentity.storageKey(track.identity)

        // 写入两个 v3 清单：较早的 key1 与较新的 key2
        let render1Key = "render-3-earlier"
        let render1URL = cache.renderURL(renderKey: render1Key)
        try VoiceAudioDSP.writeWAV(left: [Float](repeating: 0.05, count: 22_050), right: nil, sampleRate: 22_050, to: render1URL)
        let render1 = VoiceRender(
            trackKey: trackKey,
            cacheKey: render1Key,
            fileURL: render1URL,
            duration: 1.0,
            sampleRate: 22_050,
            packID: pack.packID,
            versionID: versionID,
            pipelineVersion: VoiceCacheManager.pipelineVersion
        )
        try cache.writeRenderManifest(render1)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30)],
            ofItemAtPath: manifestsDir.appendingPathComponent("\(render1Key).json").path
        )

        let render2Key = "render-3-latest"
        let render2URL = cache.renderURL(renderKey: render2Key)
        try VoiceAudioDSP.writeWAV(left: [Float](repeating: 0.08, count: 44_100), right: nil, sampleRate: 22_050, to: render2URL)
        let render2 = VoiceRender(
            trackKey: trackKey,
            cacheKey: render2Key,
            fileURL: render2URL,
            duration: 2.0,
            sampleRate: 22_050,
            packID: pack.packID,
            versionID: versionID,
            pipelineVersion: VoiceCacheManager.pipelineVersion
        )
        try cache.writeRenderManifest(render2)

        // 验证原声未缓存时（inputResolver 返回 nil）也能回退命中最新 v3 渲染
        manager.inputResolver = { _ in nil }
        XCTAssertFalse(manager.isEnabled, "开关关闭时也应检测并展示已有 AI 翻唱缓存")
        await manager.refreshRenderAvailability(for: track)
        XCTAssertNotNil(manager.existingRender(for: track))

        let resolved = await manager.resolvePlayableRender(for: track)
        XCTAssertEqual(resolved?.cacheKey, render2Key)

        // 开启 AI 开关后驱动应能直接产出可播 AI 会话，而不因缺少原声文件退回原曲
        manager.isEnabled = true
        let driver = VoicePlaybackDriver(voice: manager, inputResolver: { _ in nil })
        let aiSession = try await driver.makeSessionIfAvailable(for: track)
        XCTAssertNotNil(aiSession)
    }

    func testVoiceOriginalAndAIRouteSwitchingAndPositionPreservation() async throws {
        // 1. 验证 MediaAudioCache 流完整落盘回调可联动驱动刷新并等待在途流完成
        let payloadURL = try TestAudioFixture.makeM4A(in: tempDir.appendingPathComponent("fixture"), name: "stream_src.m4a", seconds: 10)
        let payload = try Data(contentsOf: payloadURL)
        let streamRemoteURL = URL(string: "https://voice-range.test/voice-switch-cache.m4s")!
        LocalRangeStubProtocol.setPayload(payload, for: streamRemoteURL.absoluteString)
        defer { LocalRangeStubProtocol.setPayload(nil, for: streamRemoteURL.absoluteString) }

        let mediaCache = MediaAudioCache(
            directory: tempDir.appendingPathComponent("media-cache"),
            session: LocalRangeStubProtocol.makeSession(),
            initialStreamChunkBytes: 16 * 1024,
            streamChunkBytes: 32 * 1024
        )
        let offline = OfflineLibraryManager(
            audioCache: mediaCache,
            manifestURL: tempDir.appendingPathComponent("offline.json"),
            qualityProvider: { .high },
            networkAllowed: { false }
        )

        actor NotificationBox {
            private(set) var keys: [String] = []
            func append(_ key: String) { keys.append(key) }
            func contains(_ key: String) -> Bool { keys.contains(key) }
        }
        let cachedBox = NotificationBox()
        await mediaCache.setOnAudioCached { key in
            Task { await cachedBox.append(key) }
        }

        let streamTrack = Track(
            sourceID: SourceID("gated"),
            externalID: "switch-song-1",
            title: "Switch Song",
            artist: "Tester",
            duration: 10
        )
        let expectedCacheKey = TrackIdentity.storageKey(streamTrack.identity)
        let descriptor = AudioStreamDescriptor(
            cacheKey: expectedCacheKey,
            fileExtension: "m4a",
            qualityTier: .high,
            qualityID: 0,
            codec: "AAC",
            bandwidth: 128_000,
            sampleRate: 44_100,
            isLossless: false,
            url: streamRemoteURL
        )

        // 先打开流，并在后台持续拉片落盘期间并发验证 ensureCachedAudioFileURL 等待在途流完成 + onAudioCached 回调触达
        let media = try await mediaCache.openMedia(descriptor: descriptor)
        guard case let .stream(progressive) = media else {
            return XCTFail("期望为渐进式流对象")
        }
        defer { progressive.releaseConsumer() }

        let ensuredURL = await offline.ensureCachedAudioFileURL(for: streamTrack, using: nil)
        XCTAssertNotNil(ensuredURL, "ensureCachedAudioFileURL 应能等待在途渐进流完整落盘并返回有效文件")
        let completedURL = await progressive.waitForLocalFile()
        XCTAssertNotNil(completedURL)
        await waitUntil("流落盘通知送达") {
            await cachedBox.contains(expectedCacheKey)
        }

        // 2. 组装 GatedEngine + VoiceManager + VoicePlaybackDriver 验证原曲 <-> AI 版实时切换与位置保留
        let rig = GatedEngine(sourceID: SourceID("gated"))
        let engine = rig.engine
        let coordinator = rig.coordinator

        let setup = makeManager(rootSubpath: "SwitchRoute")
        let manager = setup.manager
        let assets = setup.assets
        let cache = setup.cache
        await manager.attach()

        for kind in VoiceModelAssetsManager.AssetKind.allCases {
            try Data(repeating: 0x02, count: 2048).write(to: assets.url(for: kind))
        }
        let onnxURL = tempDir.appendingPathComponent("switch_singer.onnx")
        try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64)).write(to: onnxURL)
        let pack = try await manager.importPack(weightURL: onnxURL, displayName: "SwitchSinger")
        let version = try XCTUnwrap(pack.selectedVersion)

        // 写入现成 10s AI 翻唱成品（使用真实输入计算对应的 renderKey）
        let ensuredLocalURL = try XCTUnwrap(ensuredURL)
        let keys = try await manager.cacheKeys(
            for: streamTrack,
            pack: pack,
            version: version,
            inputAudioURL: ensuredLocalURL
        )
        let aiWavURL = tempDir.appendingPathComponent("ai_10s.wav")
        let samples = (0..<(10 * 22_050)).map { i in 0.1 * sin(2 * Float.pi * 440 * Float(i) / 22_050) }
        try VoiceAudioDSP.writeWAV(left: samples, right: nil, sampleRate: 22_050, to: aiWavURL)
        let trackKey = TrackIdentity.storageKey(streamTrack.identity)
        let render = VoiceRender(
            trackKey: trackKey,
            cacheKey: keys.renderKey,
            fileURL: aiWavURL,
            duration: 10.0,
            sampleRate: 22_050,
            packID: pack.packID,
            versionID: version.id,
            pipelineVersion: VoiceCacheManager.pipelineVersion
        )
        try cache.writeRenderManifest(render)

        let driver = VoicePlaybackDriver(voice: manager, inputResolver: { _ in ensuredURL })
        coordinator.voiceSessionFactory = { [weak driver] t, isPrewarm in
            try await driver?.makeSessionIfAvailable(for: t, isPrewarm: isPrewarm)
        }
        coordinator.voiceRoutingSignature = { [weak driver] t in
            await driver?.activeRoutingSignature(for: t)
        }
        manager.inputResolver = { _ in ensuredURL }
        manager.onPlayVersionRequested = { [weak driver, weak engine, weak coordinator] t, autoplay in
            guard let driver, let engine, let coordinator else { return }
            await driver.playRequestedVersion(of: t, playback: engine, coordinator: coordinator, autoplay: autoplay)
        }
        manager.onVoiceContextChanged = { [weak driver, weak engine, weak coordinator] in
            guard let driver, let engine, let coordinator else { return }
            Task { @MainActor in
                await driver.reconcileActiveTrackRouting(playback: engine, coordinator: coordinator)
            }
        }

        // 初始关闭 AI 翻唱：从原曲起播，并 seek 到 4.0s，同时触发 prewarm 测试 standby 隔离
        manager.isEnabled = false
        await engine.load(streamTrack, autoplay: true)
        XCTAssertFalse(engine.isPlayingVoiceAI)
        XCTAssertFalse(coordinator.isPlayingVoiceAI)

        await engine.seek(to: 4.0)
        XCTAssertGreaterThanOrEqual(engine.position(at: rig.clock.now), 3.8)

        // 预热同曲目原曲 standby 后切向 AI 版：因路由签名不同绝不能误用原曲 standby
        coordinator.prewarm(track: streamTrack)
        try await Task.sleep(for: .milliseconds(80))

        try await manager.switchToVoicePlayback(for: streamTrack, autoplay: true)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertTrue(coordinator.isPlayingVoiceAI)
        XCTAssertTrue(engine.isPlayingVoiceAI)
        XCTAssertGreaterThanOrEqual(engine.position(at: rig.clock.now), 3.5, "切换为 AI 翻唱时应保留原曲当前播放进度")

        // 切回原曲也应切回原会话并继续保持进度
        await manager.switchToOriginalPlayback(for: streamTrack, autoplay: true)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(coordinator.isPlayingVoiceAI)
        XCTAssertFalse(engine.isPlayingVoiceAI)
        XCTAssertGreaterThanOrEqual(engine.position(at: rig.clock.now), 3.5, "切回原曲时应保留当前播放进度")

        // 原曲播放完毕进入 .ended 后，切回 AI 版应重置从 0 开始重播而非卡死在末尾
        let originalSession = try XCTUnwrap(rig.source.sessions.last)
        originalSession.finish()
        await waitUntil("等待原曲自然结束") {
            if case .ended = engine.state { return true }
            return false
        }
        try await manager.switchToVoicePlayback(for: streamTrack, autoplay: true)
        XCTAssertTrue(engine.isPlayingVoiceAI)
        XCTAssertLessThan(engine.position(at: rig.clock.now), 1.0, ".ended 状态下切换版本应从头部 0 秒重新开始播放")
    }

    func testContainerBuilderRetainsVoiceDriverAcrossScopesAndSwitchesPausedTrackToAI() async throws {
        // 使用生产相同的 ContainerBuilder 组装，不在测试栈额外保存 driver 引用：
        // 若容器未强持有 voiceDriver，脱离构造作用域后会立刻悬空成 nil 导致点击“播放 AI 版”完全无响应。
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        let voice = try XCTUnwrap(container.voice)
        defer { voice.shutdown() }
        XCTAssertNotNil(container.voiceDriver, "AppContainer 必须强持有 VoicePlaybackDriver，否则所有 [weak driver] 回调都会失效")

        await voice.attach()
        try await Task.sleep(for: .milliseconds(30))

        for kind in VoiceModelAssetsManager.AssetKind.allCases {
            try Data(repeating: 0x02, count: 2048).write(to: voice.assets.url(for: kind))
        }
        let onnxURL = tempDir.appendingPathComponent("container_singer.onnx")
        try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64)).write(to: onnxURL)
        let pack = try await voice.importPack(weightURL: onnxURL, displayName: "ContainerSinger")
        let version = try XCTUnwrap(pack.selectedVersion)

        let mockSource = try XCTUnwrap(container.sourceRegistry.provider(for: .mock) as? MockPlaybackSource)
        let track = try XCTUnwrap(mockSource.catalog.first)
        let trackKey = TrackIdentity.storageKey(track.identity)

        let aiWavURL = tempDir.appendingPathComponent("container_ai_10s.wav")
        let samples = (0..<(10 * 22_050)).map { i in 0.1 * sin(2 * Float.pi * 440 * Float(i) / 22_050) }
        try VoiceAudioDSP.writeWAV(left: samples, right: nil, sampleRate: 22_050, to: aiWavURL)
        let render = VoiceRender(
            trackKey: trackKey,
            cacheKey: "render-container-\(trackKey)",
            fileURL: aiWavURL,
            duration: 10.0,
            sampleRate: 22_050,
            packID: pack.packID,
            versionID: version.id,
            pipelineVersion: VoiceCacheManager.pipelineVersion
        )
        try voice.cache.writeRenderManifest(render)

        // 先关掉 AI 开关加载原曲并暂停，还原“暂停原曲时点击播放 AI 版”的真机操作序列
        voice.isEnabled = false
        await container.playback.load(track, autoplay: true)
        await waitUntil("等待原曲起播") { container.playback.state.isPlaying }
        await container.playback.pause()
        guard case .paused = container.playback.state else {
            return XCTFail("期望处于暂停态，实际为 \(container.playback.state.debugLabel)")
        }
        XCTAssertFalse(container.playback.isPlayingVoiceAI)

        // 脱离构造栈后调用 switchToVoicePlayback(autoplay: true)：不仅要切出 AI 会话，还必须从暂停态自动起播
        try await voice.switchToVoicePlayback(for: track, autoplay: true)
        XCTAssertTrue(voice.isEnabled)
        XCTAssertTrue(container.playback.isPlayingVoiceAI, "容器保活下的 driver 应将播放器切换为 AI 翻唱会话")
        XCTAssertTrue(container.playback.state.isPlaying, "点击播放 AI 版（autoplay=true）不应被 contextChange 竞态吞掉，应在切完后自动起播")

        // 再在暂停态切回原曲（autoplay=false）：验证 onVoiceContextChanged 触发的后台对齐同样有效且保持暂停
        await container.playback.pause()
        guard case .paused = container.playback.state else {
            return XCTFail("期望处于暂停态，实际为 \(container.playback.state.debugLabel)")
        }
        await voice.switchToOriginalPlayback(for: track, autoplay: false)
        await waitUntil("等待 onVoiceContextChanged 将当前会话切回原曲") {
            guard !container.playback.isPlayingVoiceAI else { return false }
            if case .ready = container.playback.state { return true }
            return false
        }
        XCTAssertFalse(container.playback.state.isPlaying, "autoplay=false 切回原曲时不应自动起播")
        // 从非播放态 (.ready) 再次点击播放 AI 版，验证同样可切换并起播
        try await voice.switchToVoicePlayback(for: track, autoplay: true)
        XCTAssertTrue(container.playback.isPlayingVoiceAI)
        XCTAssertTrue(container.playback.state.isPlaying)
    }

    func testOfflineAICoverPlaysThroughContainerAndDeletingItFallsBackToOriginal() async throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        let voice = try XCTUnwrap(container.voice)
        defer { voice.shutdown() }
        await voice.attach()
        try await Task.sleep(for: .milliseconds(30))

        for kind in VoiceModelAssetsManager.AssetKind.allCases {
            try Data(repeating: 0x02, count: 2048).write(to: voice.assets.url(for: kind))
        }
        let onnxURL = tempDir.appendingPathComponent("offline_cover_singer.onnx")
        try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64)).write(to: onnxURL)
        let coverPack = try await voice.importPack(weightURL: onnxURL, displayName: "CoverSinger")
        _ = try await voice.importPack(weightURL: onnxURL, displayName: "OtherSinger")

        let mockSource = try XCTUnwrap(container.sourceRegistry.provider(for: .mock) as? MockPlaybackSource)
        let track = try XCTUnwrap(mockSource.catalog.first)

        // 成品放在缓存目录里（真实生成的位置），音色是另一个包：常规按当前音色匹配不会命中
        let fixture = try TestAudioFixture.makeM4A(in: tempDir.appendingPathComponent("cover-fixture"),
                                                   name: "cover.m4a", seconds: 10)
        let renderKey = "render-3-offline-cover"
        let renderURL = voice.cache.renderURL(renderKey: renderKey)
        try FileManager.default.copyItem(at: fixture, to: renderURL)
        try voice.cache.writeRenderManifest(
            VoiceRender(trackKey: TrackIdentity.storageKey(track.identity), cacheKey: renderKey,
                        fileURL: renderURL, duration: 10, sampleRate: 44_100, packID: coverPack.packID,
                        versionID: try XCTUnwrap(coverPack.selectedVersion?.id),
                        pipelineVersion: VoiceCacheManager.pipelineVersion),
            metadata: .init(track: track, packName: "CoverSinger")
        )
        voice.reloadStoredCovers()
        let cover = try XCTUnwrap(voice.storedCovers.first)
        XCTAssertEqual(voice.packName(for: cover), "CoverSinger")

        // AI 开关关着，像在离线页那样设队列后点播
        voice.isEnabled = false
        container.playback.setQueue([track], current: track)
        await voice.playStoredCover(cover, track: track, queue: [cover])
        await waitUntil("离线页点播后播放 AI 版") {
            container.playback.isPlayingVoiceAI && container.playback.state.isPlaying
        }
        XCTAssertTrue(voice.isEnabled)
        XCTAssertEqual(voice.renders[cover.trackKey]?.cacheKey, renderKey)

        // 删除正在播的这条：文件没了，播放端要退回原曲而不是继续挂着已删文件
        voice.deleteStoredCovers([cover])
        XCTAssertFalse(FileManager.default.fileExists(atPath: renderURL.path))
        await waitUntil("删除后退回原曲") { !container.playback.isPlayingVoiceAI }
        XCTAssertTrue(voice.storedCovers.isEmpty)
    }

    func testSwitchBackToOriginalFallsBackToCachedMediaWhenOnlineSourceFailsButRespectsRightsError() async throws {
        let sourceID = SourceID("js-bili-fallback")
        let track = Track(
            sourceID: sourceID,
            externalID: "BV1624y1M7rG",
            title: "My Love Fallback",
            artist: "JLRS",
            album: "BV1624y1M7rG",
            duration: 10
        )
        let restrictedTrack = Track(
            sourceID: sourceID,
            externalID: "BV1restricted1",
            title: "VIP Only",
            artist: "JLRS",
            duration: 10
        )

        // 准备真实的原曲 m4a 缓存（写到 MediaAudioCache 中）
        let m4aURL = try TestAudioFixture.makeM4A(in: tempDir)
        let m4aData = try Data(contentsOf: m4aURL)
        let origURL1 = try XCTUnwrap(URL(string: "https://voice-range.test/fallback-orig.m4a"))
        let origURL2 = try XCTUnwrap(URL(string: "https://voice-range.test/restricted-orig.m4a"))
        LocalRangeStubProtocol.setPayload(m4aData, for: origURL1.absoluteString)
        LocalRangeStubProtocol.setPayload(m4aData, for: origURL2.absoluteString)

        let mediaCache = MediaAudioCache(
            directory: tempDir.appendingPathComponent("fallback-cache", isDirectory: true),
            offlineDirectory: tempDir.appendingPathComponent("fallback-offline", isDirectory: true),
            session: LocalRangeStubProtocol.makeSession()
        )
        for (targetTrack, url) in [(track, origURL1), (restrictedTrack, origURL2)] {
            let desc = AudioStreamDescriptor(
                cacheKey: TrackIdentity.storageKey(targetTrack.identity),
                fileExtension: "m4a",
                qualityTier: .high,
                qualityID: 0,
                codec: "AAC",
                bandwidth: 128_000,
                sampleRate: 44_100,
                isLossless: false,
                url: url
            )
            _ = try await mediaCache.localFile(descriptor: desc)
        }

        let offline = OfflineLibraryManager(audioCache: mediaCache, manifestURL: nil)
        let onlineSource = ScriptableFailingSource(sourceID: sourceID)
        let registry = SourceRegistry()
        registry.register(onlineSource)

        let coordinator = PlaybackCoordinator(registry: registry)
        coordinator.isNetworkEnabled = { true }
        coordinator.offlineSessionFactory = { t in
            try await offline.offlineSession(for: t, quality: .auto)
        }
        let clock = SystemPlaybackClock()
        let engine = PlaybackEngine(clock: clock, coordinator: coordinator)

        let setup = makeManager(rootSubpath: "FallbackVoice")
        let voice = setup.manager
        defer { voice.shutdown() }
        await voice.attach()

        for kind in VoiceModelAssetsManager.AssetKind.allCases {
            try Data(repeating: 0x02, count: 2048).write(to: setup.assets.url(for: kind))
        }
        let onnxURL = tempDir.appendingPathComponent("fallback_singer.onnx")
        try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64)).write(to: onnxURL)
        let pack = try await voice.importPack(weightURL: onnxURL, displayName: "FallbackSinger")
        let version = try XCTUnwrap(pack.selectedVersion)

        let aiWavURL = tempDir.appendingPathComponent("fallback_ai_10s.wav")
        let samples = (0..<(10 * 22_050)).map { i in 0.1 * sin(2 * Float.pi * 440 * Float(i) / 22_050) }
        try VoiceAudioDSP.writeWAV(left: samples, right: nil, sampleRate: 22_050, to: aiWavURL)
        let rawCachedOrigURL = await offline.cachedAudioFileURL(for: track)
        let cachedOrigURL = try XCTUnwrap(rawCachedOrigURL)
        let keys = try await voice.cacheKeys(
            for: track,
            pack: pack,
            version: version,
            inputAudioURL: cachedOrigURL
        )
        let trackKey = TrackIdentity.storageKey(track.identity)
        try setup.cache.writeRenderManifest(VoiceRender(
            trackKey: trackKey,
            cacheKey: keys.renderKey,
            fileURL: aiWavURL,
            duration: 10.0,
            sampleRate: 22_050,
            packID: pack.packID,
            versionID: version.id,
            pipelineVersion: VoiceCacheManager.pipelineVersion
        ))

        let inputResolver: @MainActor (Track) async -> URL? = { t in
            await offline.cachedAudioFileURL(for: t)
        }
        voice.inputResolver = inputResolver
        let driver = VoicePlaybackDriver(voice: voice, inputResolver: inputResolver)
        coordinator.voiceRoutingSignature = { [weak driver] t in await driver?.activeRoutingSignature(for: t) }
        coordinator.voiceSessionFactory = { [weak driver] t, isPrewarm in
            try await driver?.makeSessionIfAvailable(for: t, isPrewarm: isPrewarm)
        }
        voice.onVoiceContextChanged = { [weak driver, weak engine, weak coordinator] in
            guard let driver, let engine, let coordinator else { return }
            Task { @MainActor in
                await driver.reconcileActiveTrackRouting(playback: engine, coordinator: coordinator)
            }
        }
        voice.onPlayVersionRequested = { [weak driver, weak engine, weak coordinator] t, autoplay in
            guard let driver, let engine, let coordinator else { return }
            await driver.playRequestedVersion(of: t, playback: engine, coordinator: coordinator, autoplay: autoplay)
        }

        // 先从 AI 版起播
        try await voice.switchToVoicePlayback(for: track, autoplay: true)
        XCTAssertTrue(engine.isPlayingVoiceAI)
        XCTAssertTrue(engine.state.isPlaying)

        // 模拟在线源切回原曲瞬间报错 sourceUnavailable（如接口缺字段或网络抖动）
        // PlaybackCoordinator 应无缝回退到底层已有 MediaAudioCache 缓存继续播原曲
        onlineSource.setError(.sourceUnavailable)
        await voice.switchToOriginalPlayback(for: track, autoplay: true)
        XCTAssertFalse(engine.isPlayingVoiceAI, "应成功切回原曲而不是卡在失败状态")
        XCTAssertTrue(engine.state.isPlaying, "切回原曲兜底后应正常播放本地缓存原曲")
        XCTAssertNil(engine.lastError)

        // 但若音源明确返回 rightsRestricted（如需要账号/权限），即使有缓存也不应静默吞掉权限报错
        onlineSource.setError(.rightsRestricted)
        await engine.load(restrictedTrack, autoplay: true)
        XCTAssertEqual(engine.lastError, .rightsRestricted)
        _ = driver
    }

    // MARK: - 「生成并播放」的自动播放意图

    func testExplicitAutoplayIntentSurvivesCacheMissAndClearsOnSwitchBack() async throws {
        let setup = makeManager(rootSubpath: "ExplicitAutoplay")
        let voice = setup.manager
        defer { voice.shutdown() }
        await voice.attach()

        let track = Track(id: UUID(), sourceID: "bili", externalID: "autoplay-miss", title: "Miss", artist: "A", duration: 30)
        let key = TrackIdentity.storageKey(track.identity)

        // 没有任何成品也没有底座模型：requestRender 会失败，但"生成好就自动播"的意图必须留住。
        _ = try? await voice.switchToVoicePlayback(for: track, autoplay: true)
        XCTAssertTrue(voice.consumePendingAutoplay(for: key), "没命中缓存时不能把自动播放的意图丢掉")
        XCTAssertFalse(voice.consumePendingAutoplay(for: key), "消费一次就该清掉")

        _ = try? await voice.switchToVoicePlayback(for: track, autoplay: true)
        await voice.switchToOriginalPlayback(for: track)
        XCTAssertFalse(voice.consumePendingAutoplay(for: key), "改回原曲后不该再自动播 AI 版")
    }

    func testClearingAllCacheIsRefusedWhileAConversionIsRunning() async throws {
        let setup = makeManager(rootSubpath: "CacheBusy")
        let voice = setup.manager
        defer { voice.shutdown() }
        await voice.attach()

        voice.progressByJob["job-busy"] = VoiceTaskProgress(
            jobID: "job-busy",
            stage: .queued,
            fraction: 0,
            message: "排队中"
        )
        XCTAssertTrue(voice.isConverting)
        XCTAssertThrowsError(try voice.clearAllCache()) { error in
            XCTAssertEqual(error as? VoiceError, .cacheBusy, "有转换在跑时不能整体清缓存")
        }

        voice.progressByJob.removeAll()
        XCTAssertFalse(voice.isConverting)
        XCTAssertNoThrow(try voice.clearAllCache())
    }

    // MARK: - 预热不覆盖当前会话追踪

    func testPrewarmingNextTrackDoesNotOverwriteActiveRenderTracking() async throws {
        let setup = makeManager(rootSubpath: "PrewarmTracking")
        let voice = setup.manager
        defer { voice.shutdown() }
        await voice.attach()

        for kind in VoiceModelAssetsManager.AssetKind.allCases {
            try Data(repeating: 0x02, count: 2048).write(to: setup.assets.url(for: kind))
        }
        let onnxURL = tempDir.appendingPathComponent("prewarm_singer.onnx")
        try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64)).write(to: onnxURL)
        let pack = try await voice.importPack(weightURL: onnxURL, displayName: "PrewarmSinger")
        let version = try XCTUnwrap(pack.selectedVersion)
        voice.isEnabled = true

        func makeOriginal(_ name: String, frequency: Double) throws -> URL {
            let url = tempDir.appendingPathComponent("\(name).wav")
            let samples = (0..<(4 * 22_050)).map { i in
                0.1 * sin(2 * Float.pi * Float(frequency) * Float(i) / 22_050)
            }
            try VoiceAudioDSP.writeWAV(left: samples, right: nil, sampleRate: 22_050, to: url)
            return url
        }
        let originalA = try makeOriginal("prewarm_a", frequency: 440)
        let originalB = try makeOriginal("prewarm_b", frequency: 523)

        let trackA = Track(id: UUID(), sourceID: "bili", externalID: "prewarm-a", title: "A", artist: "A", duration: 4)
        let trackB = Track(id: UUID(), sourceID: "bili", externalID: "prewarm-b", title: "B", artist: "A", duration: 4)

        func writeRender(for track: Track, input: URL) async throws -> String {
            let keys = try await voice.cacheKeys(for: track, pack: pack, version: version, inputAudioURL: input)
            try setup.cache.writeRenderManifest(VoiceRender(
                trackKey: TrackIdentity.storageKey(track.identity),
                cacheKey: keys.renderKey,
                fileURL: input,
                duration: 4,
                sampleRate: 22_050,
                packID: pack.packID,
                versionID: version.id,
                pipelineVersion: VoiceCacheManager.pipelineVersion
            ))
            return keys.renderKey
        }
        let renderKeyA = try await writeRender(for: trackA, input: originalA)
        _ = try await writeRender(for: trackB, input: originalB)

        let inputs: [String: URL] = [
            TrackIdentity.storageKey(trackA.identity): originalA,
            TrackIdentity.storageKey(trackB.identity): originalB
        ]
        let resolver: @MainActor (Track) async -> URL? = { inputs[TrackIdentity.storageKey($0.identity)] }
        voice.inputResolver = resolver
        let driver = VoicePlaybackDriver(voice: voice, inputResolver: resolver)

        _ = try await driver.makeSessionIfAvailable(for: trackA)
        XCTAssertEqual(driver.lastLoadedTrackKey, TrackIdentity.storageKey(trackA.identity))
        XCTAssertEqual(driver.lastLoadedRenderKey, renderKeyA)

        // 预热下一首：不能把正在播的 A 的追踪改成 B，否则删掉 A 的成品后认不出"文件没了"。
        _ = try await driver.makeSessionIfAvailable(for: trackB, isPrewarm: true)
        XCTAssertEqual(driver.lastLoadedTrackKey, TrackIdentity.storageKey(trackA.identity),
                       "预热下一首不能覆盖正在播的追踪")
        XCTAssertEqual(driver.lastLoadedRenderKey, renderKeyA)
    }
}

private final class ScriptableFailingSource: PlaybackSourceProvider, @unchecked Sendable {
    let descriptor: SourceDescriptor
    private let lock = NSLock()
    private var nextError: PlaybackError = .sourceUnavailable

    init(sourceID: SourceID) {
        self.descriptor = SourceDescriptor(
            id: sourceID,
            displayName: "测试故障源",
            kind: .jsPlugin,
            requiresNetwork: true,
            supportsSearch: false,
            supportsLyrics: false
        )
    }

    func setError(_ error: PlaybackError) {
        lock.lock()
        nextError = error
        lock.unlock()
    }

    func search(_ request: SearchRequest) async throws -> [Track] { [] }
    func makeSession(for track: Track) async throws -> any PlaybackSession {
        throw lock.withLock { nextError }
    }
    func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession { throw PlaybackError.sourceUnavailable }
    func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
    func lyrics(for track: Track) async throws -> LyricsDocument? { nil }
    func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
}

private final class LocalRangeStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var payloads: [String: Data] = [:]

    static func setPayload(_ data: Data?, for urlString: String) {
        lock.lock()
        payloads[urlString] = data
        lock.unlock()
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LocalRangeStubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "voice-range.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let fullData = Self.payload(for: url.absoluteString) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        if let rangeHeader, rangeHeader.hasPrefix("bytes=") {
            let spec = String(rangeHeader.dropFirst("bytes=".count))
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(parts.first ?? "") ?? 0
            let endReq = (parts.count > 1 && !parts[1].isEmpty) ? (Int(parts[1]) ?? (fullData.count - 1)) : (fullData.count - 1)
            let clampedStart = max(0, min(start, fullData.count))
            let clampedEnd = max(clampedStart, min(endReq, max(fullData.count - 1, 0)))
            let slice = clampedStart < fullData.count ? fullData[clampedStart...clampedEnd] : Data()
            let headers = [
                "Content-Range": "bytes \(clampedStart)-\(clampedEnd)/\(fullData.count)",
                "Content-Length": "\(slice.count)",
                "Accept-Ranges": "bytes",
            ]
            if let resp = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers) {
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: Data(slice))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let headers = ["Content-Length": "\(fullData.count)", "Accept-Ranges": "bytes"]
        if let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) {
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: fullData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func payload(for urlString: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return payloads[urlString]
    }
}
