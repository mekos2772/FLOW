import Foundation
import XCTest
@testable import SpatialLyricsPlayer

/// 2026-11 代码审查修复的回归测试。
///
/// 这些问题之前全都"测试通过、生产坏掉"：测试给 stub 注入了生产环境根本没有的能力
/// （自定义离线解析器、预先开好的 gapless 开关），于是真实注册路径上的断点一条也测不出来。
/// 这里一律走**生产注册路径**，只把网络换成假传输层。
@MainActor
final class ReviewFixRegressionTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        FakeBiliTransport.reset()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-review-fix-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        FakeBiliTransport.reset()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    // MARK: - 夹具

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "flow.review-fix.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func makeManager(network: @escaping @Sendable () -> Bool = { true },
                             quality: @escaping @Sendable () -> AudioQualityTier? = { nil },
                             defaults: UserDefaults) -> SourceManager {
        SourceManager(
            registry: SourceRegistry(),
            networkEnabledProvider: network,
            preferredQualityProvider: quality,
            defaults: defaults,
            secrets: InMemorySecretStore(),
            importedSourcesDirectory: directory.appendingPathComponent("imported", isDirectory: true),
            session: FakeBiliTransport.makeSession()
        )
    }

    private func makeCache() -> MediaAudioCache {
        MediaAudioCache(
            directory: directory.appendingPathComponent("cache", isDirectory: true),
            offlineDirectory: directory.appendingPathComponent("offline", isDirectory: true),
            session: FakeBiliTransport.makeSession()
        )
    }

    private func fixtureAudio() throws -> Data {
        let url = try TestAudioFixture.makeM4A(in: directory.appendingPathComponent("origin", isDirectory: true))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, MediaAudioCache.minimumUsefulBytes)
        return data
    }

    private func subsonicConfig(_ id: String) -> ServerSourceConfig {
        ServerSourceConfig(id: id, kind: .openSubsonic, displayName: "Home Navidrome",
                           baseURLString: "https://music.example.test", username: "alice")
    }

    // MARK: - 离线下载走生产注册路径

    /// 之前：生产注册从不提供 `offlineResolver`，未缓存曲目点「离线保存」一律失败。
    func testExplicitDownloadOfUncachedServerTrackWorksWithoutCustomResolver() async throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        FakeBiliTransport.routes = [("stream.view", try fixtureAudio())]

        let manager = makeManager(defaults: defaults)
        let config = subsonicConfig("nav-offline")
        try await manager.addServerSource(config, password: "pw", validateConnection: false,
                                          session: FakeBiliTransport.makeSession())
        XCTAssertNil(manager.managedSource(for: config.sourceID)?.offlineResolver,
                     "这条测试必须证明不依赖自定义解析器")

        let offline = OfflineLibraryManager(audioCache: makeCache(), manifestURL: nil,
                                            qualityProvider: { .auto }, networkAllowed: { true })
        let track = Track(sourceID: config.sourceID, externalID: "song-1",
                          title: "Aurora", artist: "Nils", duration: 8)
        let saved = await offline.download(track, using: manager)

        XCTAssertTrue(saved)
        XCTAssertTrue(offline.isOffline(track.identity))
        XCTAssertTrue(FakeBiliTransport.requested.contains { $0.contains("stream.view") && $0.contains("id=song-1") })

        FakeBiliTransport.reset()
        let session = try await offline.offlineSession(for: track, quality: .auto)
        XCTAssertNotNil(session, "离线保存后应能零网络构造会话")
        XCTAssertTrue(FakeBiliTransport.requested.isEmpty)
        await session?.invalidate()
    }

    /// 之前：JS / OpenSubsonic 的缓存键拼了音质后缀，离线查找只认裸键——播完整首也离线不了。
    func testLegacyQualitySuffixedCacheIsPromotedAndPlayableOffline() async throws {
        let audio = try fixtureAudio()
        let cache = makeCache()
        let track = Track(sourceID: SourceID(rawValue: "js-legacy"), externalID: "x1",
                          title: "Legacy", artist: "A", duration: 8)
        let legacy = AudioStreamDescriptor(
            cacheKey: "\(TrackIdentity.storageKey(track.identity))-high",
            fileExtension: "m4a", qualityTier: .high, qualityID: 320, codec: "AAC",
            bandwidth: 320_000, isLossless: false, url: URL(string: "https://cdn.test/x1.m4a")!
        )
        FakeBiliTransport.routes = [("cdn.test/x1.m4a", audio)]
        _ = try await cache.localFile(descriptor: legacy)
        FakeBiliTransport.reset()

        let offline = OfflineLibraryManager(audioCache: cache, manifestURL: nil,
                                            qualityProvider: { .auto }, networkAllowed: { false })
        let saved = await offline.download(track, using: nil)
        XCTAssertTrue(saved, "旧版带音质后缀的临时缓存应能在关网下转存为离线")
        XCTAssertTrue(FakeBiliTransport.requested.isEmpty)

        let session = try await offline.offlineSession(for: track)
        XCTAssertNotNil(session)
        await session?.invalidate()

        await offline.remove(track)
        XCTAssertFalse(offline.isOffline(track.identity))
        let legacyStillOffline = await cache.isOffline(cacheKey: legacy.cacheKey)
        XCTAssertFalse(legacyStillOffline, "移除离线必须连旧键文件一起删")
    }

    /// 旧键补查只对历史上拼过后缀的源生效：别的源 externalID 可能本来就带 `-high`，补查会认错曲目。
    func testLegacyKeyLookupIsScopedToSourcesThatUsedSuffixes() async throws {
        let audio = try fixtureAudio()
        let cache = makeCache()
        let neighbour = AudioStreamDescriptor(
            cacheKey: "json-demo::x1-high", fileExtension: "m4a", qualityTier: .high,
            qualityID: 320, codec: "AAC", bandwidth: 320_000, isLossless: false,
            url: URL(string: "https://cdn.test/neighbour.m4a")!
        )
        FakeBiliTransport.routes = [("cdn.test/neighbour.m4a", audio)]
        _ = try await cache.localFile(descriptor: neighbour)

        let offline = OfflineLibraryManager(audioCache: cache, manifestURL: nil,
                                            qualityProvider: { .auto }, networkAllowed: { false })
        let other = Track(sourceID: SourceID(rawValue: "json-demo"), externalID: "x1",
                          title: "Other", artist: "", duration: 8)
        let session = try await offline.offlineSession(for: other)
        XCTAssertNil(session, "`json-demo::x1` 不能借用另一首 `x1-high` 的缓存")
    }

    /// 本地文件的离线保存直接拷贝原文件，不能被当成远端地址去下载。
    func testSavingLocalFileDescriptorCopiesWithoutNetwork() async throws {
        let audio = try fixtureAudio()
        let file = directory.appendingPathComponent("local-song.m4a")
        try audio.write(to: file)
        let cache = makeCache()
        let descriptor = AudioStreamDescriptor(
            cacheKey: "localFile::\(file.path)", fileExtension: "m4a", qualityTier: .high,
            qualityID: 0, codec: "M4A", bandwidth: 0, isLossless: false, url: file
        )
        let saved = try await cache.saveOffline(descriptor: descriptor)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        XCTAssertNotEqual(saved.standardizedFileURL, file.standardizedFileURL)
        XCTAssertTrue(FakeBiliTransport.requested.isEmpty)
    }

    // MARK: - 直链解析不能吞掉普通搜索

    private enum ResolveBehavior: Sendable {
        case empty
        case failure
        case tracks([Track])
    }

    private struct ClaimingResolver: PlaybackSourceProvider, URLResolvableSourceProvider {
        let descriptor: SourceDescriptor
        let behavior: ResolveBehavior

        func canHandleQuery(_ query: String) -> Bool { true }
        func resolveQuery(_ query: String) async throws -> [Track] {
            switch behavior {
            case .empty: return []
            case .failure: throw PlaybackError.sourceUnavailable
            case .tracks(let tracks): return tracks
            }
        }
        func search(_ request: SearchRequest) async throws -> [Track] { [] }
        func makeSession(for track: Track) async throws -> any PlaybackSession { throw PlaybackError.sourceUnavailable }
        func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession { session }
        func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
        func lyrics(for track: Track) async throws -> LyricsDocument? { nil }
        func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
    }

    private struct KeywordSource: PlaybackSourceProvider {
        let descriptor: SourceDescriptor
        let results: [Track]

        func search(_ request: SearchRequest) async throws -> [Track] { results }
        func makeSession(for track: Track) async throws -> any PlaybackSession { throw PlaybackError.sourceUnavailable }
        func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession { session }
        func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
        func lyrics(for track: Track) async throws -> LyricsDocument? { nil }
        func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
    }

    /// 之前：导入 Bilibili 插件后首次搜「Coldplay」得到空列表——插件粗筛认领了普通关键词。
    func testDeclinedDirectResolutionFallsBackToRegularSearch() async throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        for behavior in [ResolveBehavior.empty, .failure] {
            let manager = makeManager(defaults: defaults)
            let keywordID = SourceID(rawValue: "keyword-\(UUID().uuidString)")
            let hit = Track(sourceID: keywordID, externalID: "yellow", title: "Yellow", artist: "Coldplay", duration: 266)
            manager.registerSource(ClaimingResolver(
                descriptor: SourceDescriptor(id: SourceID(rawValue: "js-claim-\(UUID().uuidString)"),
                                             displayName: "Greedy", kind: .jsPlugin, requiresNetwork: true),
                behavior: behavior
            ))
            manager.registerSource(KeywordSource(
                descriptor: SourceDescriptor(id: keywordID, displayName: "Keyword", kind: .jsonTemplate, requiresNetwork: true),
                results: [hit]
            ))
            manager.aggregateSearchEnabled = true

            let results = try await manager.search(query: "Coldplay")
            XCTAssertEqual(results.map(\.identity), [hit.identity], "解析器 \(behavior) 后应回落到普通搜索")
        }
    }

    /// 前一个插件拒绝后，后一个能处理该链接的插件仍要拿到派发；成功的直链解析照旧直接返回。
    func testLaterResolverStillReceivesLinkAfterEarlierDecline() async throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = makeManager(defaults: defaults)
        let laterID = SourceID(rawValue: "js-later")
        let resolved = Track(sourceID: laterID, externalID: "share-1", title: "Shared", artist: "B", duration: 100)

        manager.registerSource(ClaimingResolver(
            descriptor: SourceDescriptor(id: SourceID(rawValue: "js-earlier"), displayName: "Earlier",
                                         kind: .jsPlugin, requiresNetwork: true),
            behavior: .empty
        ))
        manager.registerSource(ClaimingResolver(
            descriptor: SourceDescriptor(id: laterID, displayName: "Later", kind: .jsPlugin, requiresNetwork: true),
            behavior: .tracks([resolved])
        ))

        let results = try await manager.search(query: "https://share.example.test/s/1")
        XCTAssertEqual(results.map(\.identity), [resolved.identity])
    }

    // MARK: - JSON 直链跨重启

    private func radioDefinition() -> JSONTemplateDefinition {
        JSONTemplateDefinition(
            id: "radio-test",
            name: "Radio Test",
            allowedDomains: ["api.radio.test", "stream.radio.test"],
            search: .init(url: "https://api.radio.test/search?q={{query}}",
                          itemsPath: "items",
                          fields: .init(lyricsUrl: "lrc"))
        )
    }

    /// 之前：直链只存在实例字典里，重启后收藏 / 恢复的队列里的电台全部放不了。
    func testJSONDirectStreamAndLyricsURLsSurviveProviderRecreation() async throws {
        FakeBiliTransport.routes = [
            ("api.radio.test/search", ["items": [[
                "id": "r1", "title": "Night Radio", "artist": "DJ",
                "url": "https://stream.radio.test/r1.mp3",
                "lrc": "https://api.radio.test/r1.lrc",
            ]]]),
            ("api.radio.test/r1.lrc", "[00:01.00]Late night signal"),
        ]
        let first = JSONTemplateSource(definition: radioDefinition(), session: FakeBiliTransport.makeSession())
        let found = try await first.search(SearchRequest(query: "night"))
        let original = try XCTUnwrap(found.first)

        // 模拟持久化：曲目经 Codable 落库再读回，音源实例整个重建。
        let persisted = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(original))
        let restarted = JSONTemplateSource(definition: radioDefinition(), session: FakeBiliTransport.makeSession())
        FakeBiliTransport.requested = []

        let descriptor = try await restarted.offlineStreamDescriptor(for: persisted, quality: .auto)
        XCTAssertEqual(descriptor?.url.absoluteString, "https://stream.radio.test/r1.mp3")
        XCTAssertEqual(descriptor?.cacheKey, TrackIdentity.storageKey(persisted.identity))
        XCTAssertTrue(FakeBiliTransport.requested.isEmpty, "直链应从持久化句柄恢复，不应重新搜索")

        let lyrics = try await restarted.lyrics(for: persisted)
        XCTAssertEqual(lyrics?.lines.first?.text, "Late night signal")
    }

    /// 实机验收发现：离线保存时取到了音源自带的歌词，但没写进离线歌词缓存，关网播放显示"没有找到同步歌词"。
    func testOfflineSaveKeepsProviderLyricsForNetworkOffPlayback() async throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        FakeBiliTransport.routes = [
            ("api.radio.test/search", ["items": [[
                "id": "r2", "title": "Offline Lyric Song", "artist": "DJ",
                "url": "https://stream.radio.test/r2.m4a",
                "lrc": "https://api.radio.test/r2.lrc",
            ]]]),
            ("api.radio.test/r2.lrc", "[00:01.00]First line\n[00:03.50]Second line"),
            ("stream.radio.test/r2.m4a", try fixtureAudio()),
        ]
        let manager = makeManager(defaults: defaults)
        let source = JSONTemplateSource(definition: radioDefinition(), session: FakeBiliTransport.makeSession())
        manager.registerSource(source)
        let found = try await source.search(SearchRequest(query: "offline"))
        let track = try XCTUnwrap(found.first)

        let offline = OfflineLibraryManager(audioCache: makeCache(), manifestURL: nil,
                                            qualityProvider: { .auto }, networkAllowed: { true })
        let saved = await offline.download(track, using: manager)
        XCTAssertTrue(saved)

        FakeBiliTransport.reset()
        let lyrics = await offline.offlineLyrics(for: track)
        XCTAssertEqual(lyrics?.lines.map(\.text), ["First line", "Second line"])
        XCTAssertEqual(lyrics?.lines.last?.start ?? 0, 3.5, accuracy: 0.01)
        XCTAssertTrue(FakeBiliTransport.requested.isEmpty)
    }

    func testLRCSerialisationRoundTripsTimingAndTranslation() throws {
        let identity = TrackIdentity(sourceID: SourceID(rawValue: "json-demo"), externalID: "x")
        let document = LyricsDocument(trackIdentity: identity, lines: [
            LyricLine(start: 0.5, text: "Hello", translation: "你好"),
            LyricLine(start: 65.25, text: "Later"),
        ])
        let lrc = SourceManager.lrcText(from: document)
        XCTAssertEqual(lrc, "[00:00.50]Hello\n[00:00.50]你好\n[01:05.25]Later")
        let parsed = try XCTUnwrap(LRCParser.parse(lrc))
        XCTAssertEqual(parsed.lines.map(\.text), ["Hello", "Later"])
        XCTAssertEqual(parsed.lines.first?.translation, "你好")
        XCTAssertEqual(parsed.lines.last?.start ?? 0, 65.25, accuracy: 0.01)
    }

    /// 持久化句柄来自磁盘，可能被篡改：恢复时必须重新过一遍域名白名单。
    func testTamperedPersistedStreamURLIsRejectedByDomainPolicy() async throws {
        let source = JSONTemplateSource(definition: radioDefinition(), session: FakeBiliTransport.makeSession())
        let tampered = Track(sourceID: radioDefinition().sourceID, externalID: "r1",
                             title: "Night Radio", artist: "DJ", duration: 0,
                             persistentIdentifier: #"{"streamURL":"https://evil.example.test/steal.mp3"}"#)
        do {
            _ = try await source.offlineStreamDescriptor(for: tampered, quality: .auto)
            XCTFail("白名单外的持久化地址不应被采用")
        } catch let error as PlaybackError {
            XCTAssertEqual(error, .sourceUnavailable)
        }
        XCTAssertTrue(FakeBiliTransport.requested.isEmpty)
    }

    // MARK: - 音质偏好

    /// 之前：设置页选了音质只改内存里的控制器，重启后所有音源回到「自动」。
    func testSavedQualityIsAppliedBeforeControllerIsCreatedAndSyncedToAllSources() async throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = makeManager(quality: { .high }, defaults: defaults)
        let config = subsonicConfig("nav-quality")
        try await manager.addServerSource(config, password: "", validateConnection: false,
                                          session: FakeBiliTransport.makeSession())

        let managed = try XCTUnwrap(manager.managedSource(for: config.sourceID))
        let controller = try XCTUnwrap(managed.qualityController)
        let source = try XCTUnwrap(managed.provider as? OpenSubsonicSource)
        XCTAssertEqual(controller.currentQualityTier, .high, "设置页显示的档位必须与实际请求一致")
        XCTAssertEqual(source.currentQuality, .high)

        await manager.applyPreferredQuality(.standard)
        XCTAssertEqual(controller.currentQualityTier, .standard)
        XCTAssertEqual(source.currentQuality, .standard)

        let descriptor = try await source.offlineStreamDescriptor(
            for: Track(sourceID: config.sourceID, externalID: "s1", title: "S", artist: "", duration: 1),
            quality: .standard
        )
        XCTAssertTrue(descriptor?.url.absoluteString.contains("maxBitRate=128") ?? false)
        XCTAssertNil(source.actualQualityDescription, "只解析描述不应冒充「当前实际音质」")
    }

    // MARK: - 关网门控

    /// 之前：关掉「允许联网」后，设置页「测试连接 / 添加服务器」照样发出探测请求。
    func testServerConnectionProbeHonoursNetworkSwitch() async throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = makeManager(network: { false }, defaults: defaults)
        let config = subsonicConfig("nav-offline-probe")

        do {
            try await manager.addServerSource(config, password: "pw", validateConnection: true,
                                              session: FakeBiliTransport.makeSession())
            XCTFail("关网时不应发起连接探测")
        } catch let error as PlaybackError {
            XCTAssertEqual(error, .networkDisabled)
        }
        XCTAssertTrue(FakeBiliTransport.requested.isEmpty)
        XCTAssertNil(manager.managedSource(for: config.sourceID))
    }

    // MARK: - JS 插件

    /// JS 插件离线描述用稳定缓存键、不上报实际音质，且已启用 gapless 预热。
    func testJSPluginOfflineDescriptorUsesStableKeyWithoutReportingQuality() async throws {
        let script = #"""
        module.exports = {
          id: "offline-js",
          platform: "Offline JS",
          version: "1.0.0",
          allowedDomains: ["cdn.offline.test"],
          supportedQualities: ["standard", "high"],
          async search(query) { return { data: [{ id: "j1", title: "J", artist: "A", duration: 8 }] }; },
          async getMediaSource(item, quality) {
            return { url: "https://cdn.offline.test/" + item.id + "-" + quality + ".m4a", codec: "AAC", bitrate: 256000 };
          }
        };
        """#
        let source = try JSPluginSource(scriptSource: script, fallbackID: "offline-js",
                                        session: FakeBiliTransport.makeSession(),
                                        secrets: InMemorySecretStore(),
                                        audioCache: makeCache())
        defer { source.runtime.invalidate() }
        XCTAssertTrue(source.supportsGaplessPrewarm)

        let track = Track(sourceID: source.manifest.sourceID, externalID: "j1", title: "J", artist: "A", duration: 8)
        let descriptor = try await source.offlineStreamDescriptor(for: track, quality: .standard)
        XCTAssertEqual(descriptor?.url.absoluteString, "https://cdn.offline.test/j1-standard.m4a")
        XCTAssertEqual(descriptor?.cacheKey, TrackIdentity.storageKey(track.identity))
        XCTAssertNil(source.actualQualityDescription)
    }
}
