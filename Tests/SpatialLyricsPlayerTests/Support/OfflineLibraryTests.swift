import Foundation
import XCTest
@testable import SpatialLyricsPlayer

private struct OfflineStubSource: PlaybackSourceProvider {
    static let remoteSourceID = SourceID(rawValue: "js-offline-test")

    let id = OfflineStubSource.remoteSourceID
    let audioURL: URL
    let lrclib: LRCLIBSource

    var descriptor: SourceDescriptor {
        SourceDescriptor(id: id, displayName: "Offline Stub", kind: .jsPlugin, requiresNetwork: true)
    }

    func search(_ request: SearchRequest) async throws -> [Track] { [] }
    func makeSession(for track: Track) async throws -> any PlaybackSession { throw PlaybackError.networkDisabled }
    func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession { throw PlaybackError.networkDisabled }
    func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
    func lyrics(for track: Track) async throws -> LyricsDocument? {
        try await ExternalLyricsAggregator(lrclib: lrclib).resolve(for: track, allowNetwork: true)
    }
    func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
}

@MainActor
private struct OfflineStubResolver: OfflineAudioResolving {
    let audioURL: URL
    let lrclib: LRCLIBSource

    func resolveTrackForOffline(_ track: Track) async -> Track { track }
    func resolveOfflineStream(for track: Track, quality: AudioQualityTier) async throws -> AudioStreamDescriptor? {
        AudioStreamDescriptor(
            cacheKey: TrackIdentity.storageKey(track.identity),
            fileExtension: "m4a",
            qualityTier: quality,
            qualityID: 128,
            codec: "AAC",
            bandwidth: 128_000,
            sampleRate: 44_100,
            isLossless: false,
            url: audioURL
        )
    }
    func fetchOfflineArtwork(for track: Track) async -> Data? { nil }
    func prefetchOfflineLyrics(for track: Track) async {
        _ = try? await ExternalLyricsAggregator(lrclib: lrclib).resolve(for: track, allowNetwork: true)
    }
}

/// 源无关的显式离线下载、永久离线目录隔离与关网离线播放回归测试。
@MainActor
final class OfflineLibraryTests: XCTestCase {

    private var directory: URL!
    private static let remoteSourceID = OfflineStubSource.remoteSourceID

    override func setUp() {
        super.setUp()
        FakeBiliTransport.reset()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-offline-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        FakeBiliTransport.reset()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    private func installOnlineAudioRoutes(trackID: String = "track-offline-1") throws -> Data {
        let audio = try Data(contentsOf: TestAudioFixture.makeM4A(in: directory.appendingPathComponent("origin")))
        XCTAssertGreaterThan(audio.count, MediaAudioCache.minimumUsefulBytes)
        FakeBiliTransport.routes = [
            ("cdn.test/\(trackID).m4a", audio),
            ("lrclib.net/api/search", [[
                "id": 999,
                "trackName": "夜曲",
                "artistName": "周杰伦",
                "albumName": "十一月的萧邦",
                "duration": 8.0,
                "syncedLyrics": "[00:01.00]為妳彈奏蕭邦的夜曲",
            ]]),
        ]
        return audio
    }

    private func makeCache() -> MediaAudioCache {
        MediaAudioCache(
            directory: directory.appendingPathComponent("cache"),
            offlineDirectory: directory.appendingPathComponent("offline"),
            session: FakeBiliTransport.makeSession()
        )
    }

    func testOfflineAudioSurvivesTempCacheTrimAndClear() async throws {
        _ = try installOnlineAudioRoutes(trackID: "keep-1")
        let cache = makeCache()
        let key = "\(Self.remoteSourceID.rawValue)::keep-1"
        let stream = AudioStreamDescriptor(
            cacheKey: key,
            fileExtension: "m4a",
            qualityTier: .standard,
            qualityID: 128,
            codec: "AAC",
            bandwidth: 128_000,
            sampleRate: 44_100,
            isLossless: false,
            url: URL(string: "https://cdn.test/keep-1.m4a")!
        )

        _ = try await cache.saveOffline(descriptor: stream)
        let savedOffline = await cache.isOffline(cacheKey: key)
        let initialOfflineSize = await cache.offlineSize()
        XCTAssertTrue(savedOffline)
        XCTAssertGreaterThan(initialOfflineSize, 0)

        _ = await cache.trimIfNeeded(maxBytes: 1, targetRatio: 0.1)
        await cache.clear()

        let tempTotal = await cache.totalSize()
        let stillOffline = await cache.isOffline(cacheKey: key)
        let cachedEntry = await cache.cachedAudio(cacheKey: key, matching: .standard)
        XCTAssertEqual(tempTotal, 0)
        XCTAssertTrue(stillOffline)
        XCTAssertNotNil(cachedEntry)

        await cache.removeOffline(cacheKey: key)
        let remainingOffline = await cache.isOffline(cacheKey: key)
        let finalOfflineSize = await cache.offlineSize()
        XCTAssertFalse(remainingOffline)
        XCTAssertEqual(finalOfflineSize, 0)
    }

    func testPromoteTempCacheToOfflineWorksWithoutNetworkAndPersistsManifest() async throws {
        let audio = try installOnlineAudioRoutes(trackID: "promote-1")
        let cache = makeCache()
        let track = Track(sourceID: Self.remoteSourceID, externalID: "promote-1",
                          title: "夜曲", artist: "周杰伦", duration: 8)
        let stream = AudioStreamDescriptor(
            cacheKey: TrackIdentity.storageKey(track.identity),
            fileExtension: "m4a",
            qualityTier: .standard,
            qualityID: 128,
            codec: "AAC",
            bandwidth: 128_000,
            sampleRate: 44_100,
            isLossless: false,
            url: URL(string: "https://cdn.test/promote-1.m4a")!
        )
        let tempURL = await cache.location(for: stream)
        try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try audio.write(to: tempURL)

        FakeBiliTransport.reset()
        let manifestURL = directory.appendingPathComponent("offline/manifest.json")
        let manager = OfflineLibraryManager(
            audioCache: cache,
            manifestURL: manifestURL,
            qualityProvider: { .standard },
            networkAllowed: { false }
        )
        let saved = await manager.download(track, using: nil)
        XCTAssertTrue(saved)
        XCTAssertTrue(manager.isOffline(track.identity))
        XCTAssertTrue(FakeBiliTransport.requested.isEmpty)

        let reloaded = OfflineLibraryManager(
            audioCache: cache,
            manifestURL: manifestURL,
            qualityProvider: { .standard },
            networkAllowed: { false }
        )
        let listed = await reloaded.refresh()
        XCTAssertEqual(listed.map(\.identity), [track.identity])
        XCTAssertEqual(reloaded.savedTrack(for: track.identity)?.title, "夜曲")
    }

    func testOfflinePlaybackAndLyricsWorkEvenWhenNetworkDisabledUnregistersSource() async throws {
        _ = try installOnlineAudioRoutes(trackID: "air-1")
        let app = try ContainerBuilder.make(.testing(inMemory: true))
        await app.settings.setEnableNetwork(true)

        let stub = OfflineStubSource(
            audioURL: URL(string: "https://cdn.test/air-1.m4a")!,
            lrclib: LRCLIBSource(session: FakeBiliTransport.makeSession())
        )
        let resolver = OfflineStubResolver(audioURL: stub.audioURL, lrclib: stub.lrclib)
        app.offline.attachAudioCache(makeCache())
        app.sourceManager.registerSource(stub, offlineResolver: resolver)

        let track = Track(sourceID: Self.remoteSourceID, externalID: "air-1",
                          title: "夜曲", artist: "周杰伦", duration: 8)
        let downloaded = await app.downloadOffline(track)
        XCTAssertTrue(downloaded)
        XCTAssertTrue(app.offline.isOffline(track.identity))

        await app.setEnableNetwork(false)
        XCTAssertNil(app.sourceRegistry.provider(for: Self.remoteSourceID))

        FakeBiliTransport.reset()
        await app.playback.load(track, autoplay: false)
        for _ in 0..<80 {
            if case .ready = app.playback.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .ready = app.playback.state else {
            return XCTFail("关网注销在线源后仍应通过离线直连加载已下载曲目，实际状态：\(app.playback.state)")
        }
        XCTAssertTrue(FakeBiliTransport.requested.isEmpty)
        await app.playback.stop()

        let uncached = Track(sourceID: Self.remoteSourceID, externalID: "missing",
                             title: "未缓存曲目", artist: "", duration: 10)
        await app.playback.load(uncached, autoplay: false)
        for _ in 0..<40 {
            if case .failed = app.playback.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case let .failed(_, error) = app.playback.state else {
            return XCTFail("未缓存曲目在关网下应进入失败态")
        }
        XCTAssertEqual(error, .networkDisabled)
        await app.playback.stop()

        let playlist = app.playlists.create(name: "离线歌单")
        app.playlists.add(PlaylistEntry(sourceID: track.sourceID, externalID: track.externalID), to: playlist.id)
        let page = PlaylistPageState()
        page.reload(app: app)
        await page.loadSongs(app: app)
        XCTAssertEqual(page.visibleEntries.map(\.track.identity), [track.identity])

        let home = OnlineHomeState()
        home.loadOffline(app: app)
        for _ in 0..<60 {
            if !home.list.isLoading, !home.list.tracks.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(home.list.tracks.map(\.identity), [track.identity])
        await app.removeOffline(track)
        XCTAssertFalse(app.offline.isOffline(track.identity))
    }
}
