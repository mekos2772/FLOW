import Foundation
import XCTest
@testable import SpatialLyricsPlayer

/// 验证第一阶段拆解下沉的源无关基础设施（`MediaAudioCache`、`HTTPStreamPlayerSession`、
/// `OfflineLibraryManager`、`ExternalLyricsAggregator`、`LyricQueryNormalizer` 与通用音质备份）。
final class Phase1FoundationTests: XCTestCase {

    private final class MockHTTPProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let result = Self.handler?(request) ?? (404, Data())
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://invalid.local")!,
                statusCode: result.0,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPProtocol.self]
        return URLSession(configuration: config)
    }

    private var directory: URL!

    override func setUpWithError() throws {
        MockHTTPProtocol.handler = nil
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-phase1-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        MockHTTPProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private struct GenericResolverStub: OfflineAudioResolving {
        let resolvedTrack: Track
        let stream: AudioStreamDescriptor
        let artworkData: Data

        func resolveTrackForOffline(_ track: Track) async -> Track { resolvedTrack }
        func resolveOfflineStream(for track: Track, quality: AudioQualityTier) async throws -> AudioStreamDescriptor? {
            stream
        }
        func fetchOfflineArtwork(for track: Track) async -> Data? { artworkData }
        func prefetchOfflineLyrics(for track: Track) async {}
    }

    private struct EmptyNativeProvider: PlaybackSourceProvider {
        let id: SourceID
        var descriptor: SourceDescriptor {
            SourceDescriptor(id: id, displayName: "Generic", requiresNetwork: true, supportsSearch: true, supportsLyrics: false)
        }
        func search(_ request: SearchRequest) async throws -> [Track] { [] }
        func makeSession(for track: Track) async throws -> any PlaybackSession { throw PlaybackError.sourceUnavailable }
        func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession { throw PlaybackError.sourceUnavailable }
        func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
        func lyrics(for track: Track) async throws -> LyricsDocument? { nil }
        func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
    }

    func testMediaAudioCacheSupportsGenericExtensionsAndOfflinePersistence() async throws {
        var audio = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        audio.append(Data(repeating: 0xAA, count: MediaAudioCache.minimumUsefulBytes + 1024))
        XCTAssertGreaterThan(audio.count, MediaAudioCache.minimumUsefulBytes)

        var capturedAuth: String?
        MockHTTPProtocol.handler = { request in
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            return (200, audio)
        }

        let cache = MediaAudioCache(
            directory: directory.appendingPathComponent("cache"),
            offlineDirectory: directory.appendingPathComponent("offline"),
            session: makeMockSession()
        )
        let descriptor = AudioStreamDescriptor(
            cacheKey: "subsonic::track-42",
            fileExtension: "mp3",
            qualityTier: .high,
            qualityID: 320,
            codec: "MP3",
            bandwidth: 320_000,
            sampleRate: 44_100,
            isLossless: false,
            url: URL(string: "https://cdn.subsonic.test/track-42.mp3")!,
            headers: ["Authorization": "Bearer test-token"]
        )

        let offlineURL = try await cache.saveOffline(descriptor: descriptor)
        XCTAssertEqual(offlineURL.pathExtension, "mp3")
        let isOffline = await cache.isOffline(cacheKey: "subsonic::track-42")
        XCTAssertTrue(isOffline)
        XCTAssertEqual(capturedAuth, "Bearer test-token")

        let hit = await cache.cachedAudio(cacheKey: "subsonic::track-42", matching: .high)
        XCTAssertEqual(hit?.url.resolvingSymlinksInPath(), offlineURL.resolvingSymlinksInPath())
        XCTAssertEqual(hit?.stream.codec, "MP3")
    }

    @MainActor
    func testHTTPStreamPlayerSessionLifecycleWithGenericDescriptor() async throws {
        let m4a = try TestAudioFixture.makeM4A(in: directory, name: "generic-session.m4a", seconds: 2)
        let descriptor = AudioStreamDescriptor(
            cacheKey: "generic::item-1",
            fileExtension: "m4a",
            qualityTier: .standard,
            qualityID: 128,
            codec: "AAC",
            bandwidth: 128_000,
            sampleRate: 44_100,
            isLossless: false,
            url: m4a
        )
        let session = try HTTPStreamPlayerSession(stream: descriptor, localURL: m4a, title: "Generic Song")
        try await session.prepare()
        XCTAssertGreaterThan(session.duration, 0)
        await session.markGaplessNext()
        try await session.play()
        try await session.seek(to: 0.5)
        await session.pause()
        await session.invalidate()
    }

    @MainActor
    func testOfflineLibraryManagerDownloadsNonBilibiliTrackAndOpensHTTPStreamSession() async throws {
        let audio = try Data(contentsOf: TestAudioFixture.makeM4A(in: directory.appendingPathComponent("origin")))
        MockHTTPProtocol.handler = { _ in (200, audio) }

        let cache = MediaAudioCache(
            directory: directory.appendingPathComponent("cache"),
            offlineDirectory: directory.appendingPathComponent("offline"),
            session: makeMockSession()
        )
        let manifestURL = directory.appendingPathComponent("offline/manifest.json")
        let manager = OfflineLibraryManager(
            audioCache: cache,
            manifestURL: manifestURL,
            qualityProvider: { .lossless },
            networkAllowed: { true }
        )

        let sourceID = SourceID("opensubsonic")
        let track = Track(sourceID: sourceID, externalID: "song-99", title: "青花瓷", artist: "周杰伦", duration: 8)
        let descriptor = AudioStreamDescriptor(
            cacheKey: TrackIdentity.storageKey(track.identity),
            fileExtension: "flac",
            qualityTier: .lossless,
            qualityID: 1000,
            codec: "FLAC",
            bandwidth: 900_000,
            sampleRate: 44_100,
            isLossless: true,
            url: URL(string: "https://nas.local/rest/stream?id=song-99")!
        )
        let resolver = GenericResolverStub(resolvedTrack: track, stream: descriptor, artworkData: Data([1, 2, 3, 4]))

        let saved = await manager.download(track, using: resolver)
        XCTAssertTrue(saved)
        XCTAssertTrue(manager.isOffline(track.identity))

        let session = try await manager.offlineSession(for: track, quality: .lossless)
        XCTAssertTrue(session is HTTPStreamPlayerSession)
        await session?.invalidate()
    }

    func testSourceAwareLyricsLoaderAggregatesLRCLIBForGenericOnlineSource() async throws {
        let json = try JSONSerialization.data(withJSONObject: [[
            "id": 321,
            "trackName": "稻香",
            "artistName": "周杰伦",
            "albumName": "魔杰座",
            "duration": 223.0,
            "syncedLyrics": "[00:10.00]對這個世界如果你有太多的抱怨",
        ]])
        MockHTTPProtocol.handler = { _ in (200, json) }

        let id = SourceID("opensubsonic-test")
        let registry = SourceRegistry()
        registry.register(EmptyNativeProvider(id: id))

        let lrcCache = LyricDocumentCache(directory: directory.appendingPathComponent("lyrics"))
        let aggregator = ExternalLyricsAggregator(
            cache: lrcCache,
            wordLevelLyrics: nil,
            lrclib: LRCLIBSource(session: makeMockSession())
        )
        let loader = SourceAwareLyricsLoader(
            registry: registry,
            externalAggregator: aggregator,
            networkAllowed: { true }
        )

        let track = Track(sourceID: id, externalID: "track-1", title: "【Live】周杰伦 - 稻香", artist: "周杰伦", duration: 223)
        let doc = await loader.loadLyrics(for: track)
        XCTAssertEqual(doc?.lines.first?.text, "对这个世界如果你有太多的抱怨")
        XCTAssertEqual(LyricQueryNormalizer.parseTitle(track.title).title, "稻香")
    }

    @MainActor
    func testSettingsBackupPrefersGenericQualityAndIgnoresInvalidPreferredQuality() async throws {
        let store = InMemorySettingsStore()
        await store.setPreferredQualityRaw(AudioQualityTier.lossless.rawValue)
        var backup = SettingsBackup.snapshot(from: store)
        XCTAssertEqual(backup.preferredQualityRaw, AudioQualityTier.lossless.rawValue)

        let decoded = try SettingsBackup.decode(try SettingsBackup.encode(backup))
        XCTAssertEqual(decoded.preferredQualityRaw, AudioQualityTier.lossless.rawValue)

        backup.preferredQualityRaw = "ultra999"
        let target = InMemorySettingsStore()
        await target.setPreferredQualityRaw(AudioQualityTier.high.rawValue)
        await backup.apply(to: target)
        XCTAssertEqual(target.preferredQualityRaw, AudioQualityTier.high.rawValue)
    }
}
