import AppKit
import Foundation
import SwiftData
import XCTest
@testable import SpatialLyricsPlayer

/// 发布前 P1 代码审计问题与安全性回归测试集。
final class ReleaseAuditRegressionTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    private final class StubHTTPProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let result = Self.handler?(request) ?? (404, [:], Data())
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://invalid.local")!,
                statusCode: result.0,
                httpVersion: "HTTP/1.1",
                headerFields: result.1
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.2)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    override func setUpWithError() throws {
        StubHTTPProtocol.handler = nil
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-release-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubHTTPProtocol.handler = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeMockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubHTTPProtocol.self]
        return URLSession(configuration: cfg)
    }

    // MARK: - P1-2: MediaAudioCache 无损防碰撞

    func testMediaAudioCachePreventsNonASCIIAndPunctuationCollisions() async throws {
        let dir = tempDir.appendingPathComponent("cache", isDirectory: true)
        let offlineDir = tempDir.appendingPathComponent("offline", isDirectory: true)
        let cache = MediaAudioCache(directory: dir, offlineDirectory: offlineDir)

        let keys = [
            "js-demo::a-b",
            "js-demo::a_b",
            "js-demo::a/b",
            "/Music/歌曲一.flac",
            "/Music/歌曲二.flac",
        ]
        let paths = keys.map { key -> String in
            let d = AudioStreamDescriptor(
                cacheKey: key,
                fileExtension: "flac",
                qualityTier: .lossless,
                qualityID: 995,
                codec: "FLAC",
                bandwidth: 900_000,
                isLossless: true,
                url: URL(string: "https://example.invalid/audio.flac")!
            )
            return cache.location(for: d).lastPathComponent
        }
        XCTAssertEqual(Set(paths).count, keys.count, "相近标点或等长中文曲名不得撞键")

        // 写入第 1 首歌缓存后，第 2 首歌检索不得命中，清理第 2 首歌也不能误删第 1 首歌
        let d1 = AudioStreamDescriptor(
            cacheKey: keys[0], fileExtension: "m4a", qualityTier: .high, qualityID: 320,
            codec: "AAC", bandwidth: 320_000, isLossless: false,
            url: URL(string: "https://example.invalid/1.m4a")!
        )
        let file1 = cache.location(for: d1)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: MediaAudioCache.minimumUsefulBytes + 512).write(to: file1)

        let hit0 = await cache.cachedAudio(cacheKey: keys[0], matching: nil)
        let hit1 = await cache.cachedAudio(cacheKey: keys[1], matching: nil)
        XCTAssertNotNil(hit0)
        XCTAssertNil(hit1)

        await cache.evict(cacheKey: keys[1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file1.path), "清理相近键不能误删另一首歌")
    }

    // MARK: - P1-3: setTimeout(Infinity) 防宿主崩溃

    func testJSPluginSetTimeoutInfinityAndNaNDoNotTrapHost() async throws {
        let script = """
        module.exports = {
            id: "timer-edge",
            platform: "TimerEdge",
            version: "1.0.0",
            allowedDomains: ["api.example.com"],
            async search(q) {
                setTimeout(() => {}, Infinity);
                setTimeout(() => {}, NaN);
                setTimeout(() => {}, 1e999);
                return { data: [{ id: "1", title: "Safe", artist: "Host", duration: 10 }] };
            },
            async getMediaSource() {
                return null;
            }
        };
        """
        let source = try JSPluginSource(
            scriptSource: script,
            session: makeMockSession(),
            secrets: InMemorySecretStore()
        )
        defer { source.runtime.invalidate() }
        let results = try await source.search(SearchRequest(query: "test"))
        XCTAssertEqual(results.count, 1)
    }

    // MARK: - P1-4: OpenSubsonic 高音质缓存槽分离

    func testOpenSubsonicDistinctQualityIDsForRawTiers() async throws {
        let secrets = InMemorySecretStore()
        let config = ServerSourceConfig(
            id: "sub-p1", kind: .openSubsonic, displayName: "Sub",
            baseURLString: "https://sub.example.local", username: "u"
        )
        let source = OpenSubsonicSource(config: config, secrets: secrets, session: makeMockSession())
        let track = Track(sourceID: config.sourceID, externalID: "song-1", title: "T", artist: "A", duration: 10)

        let autoDesc = try await source.offlineStreamDescriptor(for: track, quality: .auto)
        let losslessDesc = try await source.offlineStreamDescriptor(for: track, quality: .lossless)
        let hiResDesc = try await source.offlineStreamDescriptor(for: track, quality: .hiRes)

        XCTAssertNotEqual(autoDesc?.qualityID, losslessDesc?.qualityID)
        XCTAssertNotEqual(losslessDesc?.qualityID, hiResDesc?.qualityID)
        XCTAssertNotEqual(losslessDesc?.fileExtension, "mp3", "raw 无损流不应固定声明为 .mp3")
    }

    // MARK: - P1-5 & P1-1: WebDAV 同源限制与重定向剥头 / 禁内网 SSRF

    func testWebDAVRejectsCrossOriginHrefAndDirectExternalTrackID() async throws {
        let secrets = InMemorySecretStore()
        try secrets.save("pw123", account: "webdav.pw.test")
        let config = ServerSourceConfig(
            id: "dav-p1", kind: .webDAV, displayName: "DAV",
            baseURLString: "https://dav.example.local:8443/music/",
            username: "alice"
        )
        StubHTTPProtocol.handler = { _ in
            let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">
              <D:response>
                <D:href>/music/valid.flac</D:href>
                <D:propstat><D:prop><D:displayname>valid.flac</D:displayname></D:prop></D:propstat>
              </D:response>
              <D:response>
                <D:href>https://evil.attacker.example/steal.flac</D:href>
                <D:propstat><D:prop><D:displayname>steal.flac</D:displayname></D:prop></D:propstat>
              </D:response>
              <D:response>
                <D:href>http://127.0.0.1:8080/internal.mp3</D:href>
                <D:propstat><D:prop><D:displayname>internal.mp3</D:displayname></D:prop></D:propstat>
              </D:response>
            </D:multistatus>
            """
            return (207, ["Content-Type": "application/xml"], Data(xml.utf8))
        }
        let source = WebDAVSource(config: config, secrets: secrets, session: makeMockSession())
        let tracks = try await source.discoverTracks(limit: 20, progress: nil)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertTrue(tracks[0].externalID.contains("dav.example.local"))

        let forgedTrack = Track(
            sourceID: config.sourceID,
            externalID: "https://attacker.example/evil.mp3",
            title: "Forged", artist: "", duration: 10
        )
        do {
            _ = try await source.makeSession(for: forgedTrack)
            XCTFail("必须拒绝外部主机作为 WebDAV 音频直链")
        } catch let err as PlaybackError {
            XCTAssertEqual(err, .sourceUnavailable)
        }
    }

    func testPluginRedirectValidatorBlocksLoopbackSSRFAndStripsCrossOriginAuth() async {
        let origin = URL(string: "https://api.example.com/v1/stream")!
        let validator = PluginHTTPClient.RedirectValidator(
            allowedDomains: ["api.example.com", "cdn.other.com"],
            originURL: origin,
            networkAllowed: { true }
        )
        let task = URLSession.shared.dataTask(with: origin)
        let r302 = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!

        // 1) 跨源到白名单外（或回环 SSRF）：直接拦截
        let ssrfURL = URL(string: "http://127.0.0.1:8080/admin")!
        let blocked = await withCheckedContinuation { (cont: CheckedContinuation<URLRequest?, Never>) in
            validator.urlSession(.shared, task: task, willPerformHTTPRedirection: r302, newRequest: URLRequest(url: ssrfURL)) {
                cont.resume(returning: $0)
            }
        }
        XCTAssertNil(blocked)
        XCTAssertNotNil(validator.violation)

        // 2) 白名单内但跨主机：允许跳但剥离 Authorization / Cookie 等敏感头
        let crossOriginValidator = PluginHTTPClient.RedirectValidator(
            allowedDomains: ["*.example.com", "cdn.other.com"],
            originURL: origin,
            networkAllowed: { true }
        )
        var cdnReq = URLRequest(url: URL(string: "https://cdn.other.com/file.m4a")!)
        cdnReq.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        cdnReq.setValue("sid=abc", forHTTPHeaderField: "Cookie")
        let sanitized = await withCheckedContinuation { (cont: CheckedContinuation<URLRequest?, Never>) in
            crossOriginValidator.urlSession(.shared, task: task, willPerformHTTPRedirection: r302, newRequest: cdnReq) {
                cont.resume(returning: $0)
            }
        }
        XCTAssertNotNil(sanitized)
        XCTAssertNil(sanitized?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(sanitized?.value(forHTTPHeaderField: "Cookie"))
    }

    // MARK: - P1-6 & P1-7: 多份备份回退与恢复前保存门控

    @MainActor
    func testPersistenceSkipsCorruptLatestBackupAndRestoresEarlierHealthyBackup() async throws {
        let storeURL = tempDir.appendingPathComponent("SpatialLyrics.store")
        let healthy = try PersistenceController(inMemory: false, storeURL: storeURL)
        try await healthy.makeTrackRepository().save(
            Track(sourceID: "local", externalID: "/tmp/keep.mp3", title: "KeepMe", artist: "Artist", duration: 100)
        )
        try healthy.container.mainContext.save()
        let baseEpoch = Int(Date().timeIntervalSince1970)
        let olderDate = Date(timeIntervalSince1970: TimeInterval(baseEpoch + 10))
        PersistenceController.writeBackup(of: storeURL, at: olderDate)

        // 写入一份更新但已损坏的备份
        let newerBadURL = PersistenceController.backupDirectory(for: storeURL)
            .appendingPathComponent("SpatialLyrics-\(baseEpoch + 20).store")
        try Data("NOT A SQLITE DATABASE HEADER CORRUPT".utf8).write(to: newerBadURL)
        // 破坏主库文件头
        try Data(repeating: 0x00, count: 1024).write(to: storeURL)

        let recovered = try PersistenceController(inMemory: false, storeURL: storeURL)
        XCTAssertTrue(recovered.recoveredFromCorruption)
        XCTAssertTrue(recovered.restoredFromBackup)
        let saved = try await recovered.makeTrackRepository().all()
        XCTAssertEqual(saved.first?.title, "KeepMe", "最新备份同坏时应自动回退恢复次新可用备份")
    }

    @MainActor
    func testSessionPersistenceSaveNowIgnoredWhileInitialRestorePending() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let repo = persistence.makeTrackRepository()
        let clock = TestPlaybackClock()
        let coord = PlaybackCoordinator(registry: SourceRegistry())

        let engineA = PlaybackEngine(clock: clock, coordinator: coord)
        let track = Track(sourceID: "local", externalID: "/tmp/saved.mp3", title: "Saved", artist: "A", duration: 120)
        try await repo.save(track)
        engineA.setQueue([track], current: track)
        PlaybackSessionPersistence(engine: engineA, persistence: persistence, tracks: repo).saveNow()

        let emptyEngine = PlaybackEngine(clock: clock, coordinator: coord)
        let guardSession = PlaybackSessionPersistence(engine: emptyEngine, persistence: persistence, tracks: repo)
        guardSession.beginInitialRestore()
        guardSession.saveNow() // 模拟冷启动恢复前失焦或 1s 定时器先跑

        let restored = await guardSession.restore()
        XCTAssertTrue(restored, "恢复前门控必须阻止空队列把旧现场覆写为空")
        XCTAssertEqual(emptyEngine.currentTrack?.identity, track.identity)
    }

    // MARK: - P1-8: 无 .lrc 本地曲目不将音频当歌词加载

    func testFileLyricsLoaderIgnoresAudioFileLyricsRefWithoutLrcSidecar() async throws {
        let audioDir = tempDir.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let mp3URL = audioDir.appendingPathComponent("NoSidecar.mp3")
        try Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00]).write(to: mp3URL)

        let source = LocalLibrarySource(defaults: UserDefaults(suiteName: "flow.nolrc.\(UUID().uuidString)")!)
        _ = await source.addFiles([mp3URL])
        let discovered = try await source.discoverTracks(limit: 10, progress: nil)
        XCTAssertEqual(discovered.count, 1)
        XCTAssertNil(discovered[0].lyrics, "无 .lrc 时不得把音频文件本身作为 LyricsReference(.file)")

        let forgedTrack = Track(
            sourceID: "local",
            externalID: mp3URL.path,
            title: "NoSidecar",
            artist: "",
            duration: 10,
            lyrics: LyricsReference(.file(mp3URL))
        )
        let doc = await FileLyricsLoader().loadLyrics(for: forgedTrack)
        XCTAssertNil(doc, "FileLyricsLoader 不得把 .mp3 音频当作文本侧车解析")
    }

    // MARK: - P1-9 & P1-10: 主窗口不受悬浮透明度污染且重置状态一致

    @MainActor
    func testMorphExpandedKeepsOpaqueAlphaAndResetPlacementSyncsMorphology() async throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.expanded)
        controller.applyFloatingOpacity(0.32)
        XCTAssertEqual(controller.debugPanel.alphaValue, 1.0, accuracy: 0.001, "完整播放器必须始终保持不透明")

        await controller.resetPlacementMemory()
        XCTAssertEqual(controller.morphology, .expanded)
        XCTAssertEqual(controller.debugPanel.alphaValue, 1.0, accuracy: 0.001)
    }

    // MARK: - ORTEnvironment 不再使用 fatalError

    func testORTEnvironmentAcquiresWithoutFatalCrash() throws {
        let env = try ORTEnvironment.acquire()
        XCTAssertFalse(ORTEnvironment.runtimeVersion.isEmpty)
        _ = env.cpuMemoryInfo
    }
}
