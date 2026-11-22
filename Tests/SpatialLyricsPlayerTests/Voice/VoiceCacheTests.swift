import XCTest
@testable import SpatialLyricsPlayer

/// 三级缓存键稳定性与 manifest 往返。

final class VoiceCacheKeyTests: XCTestCase {

    func testSeparationKeyDeterministic() {
        let a = VoiceCacheManager.separationKey(audioFP: "abcdef0123456789", separationModel: "roformer-karaoke")
        let b = VoiceCacheManager.separationKey(audioFP: "abcdef0123456789", separationModel: "roformer-karaoke")
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("sep-\(VoiceCacheManager.pipelineVersion)-"))
        let c = VoiceCacheManager.separationKey(audioFP: "abcdef0123456789", separationModel: "htdemucs")
        XCTAssertNotEqual(a, c, "分离模型不同必须换键")
    }

    func testConversionKeySensitiveToWeightAndParams() {
        let sep = "sep-1-m-fp"
        let params: [String: VoiceParameterValue] = ["f0_up_key": .int(0)]
        let base = VoiceCacheManager.conversionKey(separationKey: sep, weightFP: "w1",
                                                   indexFP: nil, engineID: "rvc",
                                                   parameters: params, backendID: "cpu")
        let same = VoiceCacheManager.conversionKey(separationKey: sep, weightFP: "w1",
                                                   indexFP: nil, engineID: "rvc",
                                                   parameters: params, backendID: "cpu")
        XCTAssertEqual(base, same)
        let otherWeight = VoiceCacheManager.conversionKey(separationKey: sep, weightFP: "w2",
                                                          indexFP: nil, engineID: "rvc",
                                                          parameters: params, backendID: "cpu")
        XCTAssertNotEqual(base, otherWeight, "换音色必须换键")
        let otherParam = VoiceCacheManager.conversionKey(
            separationKey: sep, weightFP: "w1", indexFP: nil, engineID: "rvc",
            parameters: ["f0_up_key": .int(3)], backendID: "cpu")
        XCTAssertNotEqual(base, otherParam, "参数变化必须换键")
        let otherBackend = VoiceCacheManager.conversionKey(
            separationKey: sep, weightFP: "w1", indexFP: nil, engineID: "rvc",
            parameters: params, backendID: "torch-mps")
        XCTAssertNotEqual(base, otherBackend, "后端不同必须换键（精度路径不同）")
    }

    func testConversionKeyParamOrderIndependent() {
        let a = VoiceCacheManager.conversionKey(separationKey: "s", weightFP: "w",
                                                indexFP: nil, engineID: "rvc",
                                                parameters: ["a": .int(1), "b": .int(2)], backendID: "cpu")
        let b = VoiceCacheManager.conversionKey(separationKey: "s", weightFP: "w",
                                                indexFP: nil, engineID: "rvc",
                                                parameters: ["b": .int(2), "a": .int(1)], backendID: "cpu")
        XCTAssertEqual(a, b, "字典顺序不应影响缓存键")
    }
}

final class VoiceCacheManifestTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testManifestRoundTrip() throws {
        let cache = VoiceCacheManager(rootURL: tempRoot)
        let renderURL = cache.renderURL(renderKey: "render-abc")
        FileManager.default.createFile(atPath: renderURL.path, contents: Data([1, 2, 3]))
        let render = VoiceRender(trackKey: "track-1", cacheKey: "render-abc",
                                 fileURL: renderURL, duration: 61.5, sampleRate: 44100,
                                 packID: "p1", versionID: "v1", pipelineVersion: 1)
        try cache.writeRenderManifest(render)
        let loaded = try XCTUnwrap(try cache.render(for: "render-abc"))
        XCTAssertEqual(loaded.trackKey, "track-1")
        XCTAssertEqual(loaded.duration, 61.5, accuracy: 1e-6)
        XCTAssertEqual(loaded.fileURL, renderURL)
    }

    func testStoredRendersCarryMetadataAndReadLegacyManifests() throws {
        let cache = VoiceCacheManager(rootURL: tempRoot)
        let track = Track(sourceID: "js-bilibili", externalID: "BV1", title: "春日影", artist: "MyGO", duration: 230)
        let newURL = cache.renderURL(renderKey: "render-3-new")
        FileManager.default.createFile(atPath: newURL.path, contents: Data(repeating: 1, count: 10))
        try cache.writeRenderManifest(
            VoiceRender(trackKey: "js-bilibili::BV1", cacheKey: "render-3-new", fileURL: newURL,
                        duration: 230, sampleRate: 44_100, packID: "p", versionID: "v1",
                        pipelineVersion: VoiceCacheManager.pipelineVersion),
            metadata: .init(track: track, packName: "高松灯", separationKey: "sep-3-x", conversionKey: "")
        )

        // 早期版本写出的清单：没有曲目、音色名与两级键
        let legacyURL = cache.renderURL(renderKey: "render-3-legacy")
        FileManager.default.createFile(atPath: legacyURL.path, contents: Data(repeating: 2, count: 20))
        let legacyJSON = """
        {"cacheKey":"render-3-legacy","createdAt":1000,"duration":234.7,"filePath":"\(legacyURL.path)",
         "packID":"voice-1","pipelineVersion":\(VoiceCacheManager.pipelineVersion),"sampleRate":44100,
         "trackKey":"js-bilibili::BV2","versionID":"v1"}
        """
        try Data(legacyJSON.utf8).write(to: cache.manifestURL(renderKey: "render-3-legacy"))

        let stored = cache.storedRenders()
        XCTAssertEqual(stored.map(\.id), ["render-3-new", "render-3-legacy"], "新的在前")
        XCTAssertEqual(stored[0].metadata.track?.title, "春日影")
        XCTAssertEqual(stored[0].metadata.packName, "高松灯")
        XCTAssertEqual(stored[0].metadata.separationKey, "sep-3-x")
        XCTAssertNil(stored[0].metadata.conversionKey, "空键不落盘")
        XCTAssertEqual(stored[0].bytes, 10)
        XCTAssertNil(stored[1].metadata.track)
        XCTAssertEqual(stored[1].render.trackKey, "js-bilibili::BV2")
        XCTAssertNotNil(try cache.render(for: "render-3-legacy"), "旧清单照常可播")
    }

    func testRemoveRendersSweepsLegacyIntermediatesOnlyWhenEmptyAndNeverTouchesOutsideFiles() throws {
        let cache = VoiceCacheManager(rootURL: tempRoot)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: outside.path, contents: Data([7]))
        defer { try? FileManager.default.removeItem(at: outside) }

        let insideURL = cache.renderURL(renderKey: "render-3-in")
        FileManager.default.createFile(atPath: insideURL.path, contents: Data([1]))
        for (key, url) in [("render-3-in", insideURL), ("render-3-out", outside)] {
            try cache.writeRenderManifest(VoiceRender(
                trackKey: key, cacheKey: key, fileURL: url, duration: 1, sampleRate: 44_100,
                packID: "p", versionID: "v", pipelineVersion: VoiceCacheManager.pipelineVersion
            ))
        }
        // 无法对应到任何清单的旧中间文件
        FileManager.default.createFile(atPath: cache.vocalsURL(sepKey: "sep-3-orphan").path, contents: Data([1]))
        FileManager.default.createFile(atPath: cache.instURL(sepKey: "sep-3-orphan").path, contents: Data([1]))

        cache.removeRenders(cacheKeys: ["render-3-in"], sweepWhenEmpty: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: insideURL.path))
        XCTAssertTrue(cache.separationExists(sepKey: "sep-3-orphan"), "还有成品时不能扫掉对不上号的中间文件")

        cache.removeRenders(cacheKeys: ["render-3-out"], sweepWhenEmpty: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "清单指向缓存目录以外时只删清单")
        XCTAssertTrue(cache.storedRenders().isEmpty)
        XCTAssertTrue(cache.separationExists(sepKey: "sep-3-orphan"), "有任务在跑（sweepWhenEmpty=false）时不扫")

        cache.removeRenders(cacheKeys: ["render-3-none"], sweepWhenEmpty: true)
        XCTAssertFalse(cache.separationExists(sepKey: "sep-3-orphan"), "全部成品删完后清掉剩余中间文件")
    }

    func testManifestMissingAudioThrowsCacheCorrupted() throws {
        let cache = VoiceCacheManager(rootURL: tempRoot)
        let ghost = VoiceRender(trackKey: "t", cacheKey: "render-ghost",
                                fileURL: cache.renderURL(renderKey: "render-ghost"),
                                duration: 1, sampleRate: 44100,
                                packID: "p", versionID: "v", pipelineVersion: 1)
        try cache.writeRenderManifest(ghost) // manifest 有，音频文件没建
        XCTAssertThrowsError(try cache.render(for: "render-ghost")) { err in
            guard case .cacheCorrupted = err as? VoiceError else {
                return XCTFail("期望 cacheCorrupted，得到 \(err)")
            }
        }
    }

    func testSeparationExistsRequiresBothFiles() throws {
        let cache = VoiceCacheManager(rootURL: tempRoot)
        XCTAssertFalse(cache.separationExists(sepKey: "k"))
        FileManager.default.createFile(atPath: cache.vocalsURL(sepKey: "k").path, contents: Data())
        XCTAssertFalse(cache.separationExists(sepKey: "k"), "只有人声文件不算命中")
        FileManager.default.createFile(atPath: cache.instURL(sepKey: "k").path, contents: Data())
        XCTAssertTrue(cache.separationExists(sepKey: "k"))
    }

    func testEvictRemovesTrackRenders() throws {
        let cache = VoiceCacheManager(rootURL: tempRoot)
        let url = cache.renderURL(renderKey: "render-t9")
        FileManager.default.createFile(atPath: url.path, contents: Data([9]))
        let r = VoiceRender(trackKey: "track-9", cacheKey: "render-t9",
                            fileURL: url, duration: 1, sampleRate: 1,
                            packID: "p", versionID: "v", pipelineVersion: 1)
        try cache.writeRenderManifest(r)
        cache.evict(trackKey: "track-9")
        XCTAssertFalse(cache.renderExists(renderKey: "render-t9"))
        XCTAssertNil(try cache.render(for: "render-t9"))
    }

    func testEnforceCapacityEvictsOldestAcrossAllTiersAndClearsManifests() throws {
        let cache = VoiceCacheManager(rootURL: tempRoot, capacityBytes: 150)

        let sepV = cache.vocalsURL(sepKey: "sep-old")
        try Data(repeating: 1, count: 80).write(to: sepV)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: sepV.path
        )

        let conv = cache.convertedVocalsURL(convKey: "conv-old")
        try Data(repeating: 2, count: 80).write(to: conv)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: conv.path
        )

        let ren = cache.renderURL(renderKey: "ren-new")
        try Data(repeating: 3, count: 80).write(to: ren)
        try cache.writeRenderManifest(VoiceRender(
            trackKey: "t-new", cacheKey: "ren-new",
            fileURL: ren, duration: 2, sampleRate: 44100,
            packID: "p", versionID: "v", pipelineVersion: VoiceCacheManager.pipelineVersion
        ))

        let freed = cache.enforceCapacity()
        XCTAssertGreaterThanOrEqual(freed, 160)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sepV.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: conv.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ren.path))

        cache.removeCorruptedManifest(for: "nonexistent")

        // 中间文件清完仍超限才动成品：成品在离线页列出，比可重建的中间文件更珍贵
        let olderRender = cache.renderURL(renderKey: "ren-older")
        try Data(repeating: 4, count: 100).write(to: olderRender)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 50)],
                                              ofItemAtPath: olderRender.path)
        let freshSep = cache.vocalsURL(sepKey: "sep-fresh")
        try Data(repeating: 5, count: 60).write(to: freshSep)
        cache.enforceCapacity()
        XCTAssertFalse(FileManager.default.fileExists(atPath: freshSep.path), "先回收中间文件，即使它更新")
        XCTAssertFalse(FileManager.default.fileExists(atPath: olderRender.path), "仍超限时回收最旧的成品")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ren.path))

        let allCleared = try cache.clearAll()
        XCTAssertGreaterThan(allCleared, 0)
        XCTAssertEqual(cache.totalCacheBytes(), 0)
    }
}
