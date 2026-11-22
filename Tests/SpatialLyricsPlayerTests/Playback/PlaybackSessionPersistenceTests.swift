import XCTest
import SwiftData
@testable import SpatialLyricsPlayer

@MainActor
final class PlaybackSessionPersistenceTests: XCTestCase {

    private func makeEngine(_ clock: TestPlaybackClock) -> PlaybackEngine {
        let registry = SourceRegistry()
        registry.register(MockPlaybackSource(behavior: .healthy, clock: clock))
        return PlaybackEngine(clock: clock, coordinator: PlaybackCoordinator(registry: registry))
    }

    func testRestoreRebuildsQueueTrackAndPosition() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let repository = persistence.makeTrackRepository()
        let tracks = MockCatalog.tracks(count: 3)
        for track in tracks { try await repository.save(track) }

        let clock = TestPlaybackClock()
        let engine = makeEngine(clock)
        engine.setQueue(tracks, current: tracks[0])
        await engine.load(tracks[0], autoplay: true)
        clock.advance(by: .seconds(42))

        PlaybackSessionPersistence(engine: engine, persistence: persistence, tracks: repository).saveNow()

        let restoredEngine = makeEngine(clock)
        let restorer = PlaybackSessionPersistence(engine: restoredEngine, persistence: persistence, tracks: repository)
        let restored = await restorer.restore()

        XCTAssertTrue(restored)
        XCTAssertEqual(restoredEngine.currentTrack?.identity, tracks[0].identity)
        XCTAssertEqual(restoredEngine.position(at: clock.now), 42, accuracy: 0.5)
        XCTAssertEqual(restoredEngine.queueSnapshot.items.count, 3)
    }

    func testRestoreDoesNotAutoPlay() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let repository = persistence.makeTrackRepository()
        let tracks = MockCatalog.tracks(count: 1)
        try await repository.save(tracks[0])

        let clock = TestPlaybackClock()
        let engine = makeEngine(clock)
        engine.setQueue(tracks, current: tracks[0])
        await engine.load(tracks[0], autoplay: true)
        PlaybackSessionPersistence(engine: engine, persistence: persistence, tracks: repository).saveNow()

        let restoredEngine = makeEngine(clock)
        await PlaybackSessionPersistence(engine: restoredEngine, persistence: persistence, tracks: repository).restore()

        XCTAssertFalse(restoredEngine.state.isPlaying, "冷启动恢复不得自动播放")
    }

    func testRestoreReturnsFalseWithEmptyStore() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let clock = TestPlaybackClock()
        let engine = makeEngine(clock)
        let restorer = PlaybackSessionPersistence(
            engine: engine,
            persistence: persistence,
            tracks: persistence.makeTrackRepository()
        )
        let restored = await restorer.restore()
        XCTAssertFalse(restored)
    }

    /// 队列必须按**身份**恢复，不能只靠本地主键。
    ///
    /// `Track.ID` 是 SwiftData 的本地主键，曲目库重建/元信息补全后会换值；
    /// 只按它对，重启后队列只剩能对上的两条（实测 23 首 → 2 首）。
    func testRestoreUsesIdentitiesWhenLocalIDsNoLongerMatch() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let repository = persistence.makeTrackRepository()
        let tracks = MockCatalog.tracks(count: 5)
        for track in tracks { try await repository.save(track) }

        let clock = TestPlaybackClock()
        let engine = makeEngine(clock)
        engine.setQueue(tracks, current: tracks[2])
        await engine.load(tracks[2], autoplay: true)
        PlaybackSessionPersistence(engine: engine, persistence: persistence, tracks: repository).saveNow()

        // 把 payload 里每条的本地主键都换成"另一个会话的主键"，身份表原样保留。
        let context = ModelContext(persistence.container)
        let record = try XCTUnwrap(try context.fetch(FetchDescriptor<QueueRecord>()).first)
        let wrapper = try XCTUnwrap(try JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
        var queueObject = try XCTUnwrap(wrapper["queue"] as? [String: Any])
        let bogus = (0..<5).map { _ in UUID().uuidString.lowercased() }
        queueObject["items"] = bogus
        queueObject["currentID"] = bogus[2]
        var rebuilt = wrapper
        rebuilt["queue"] = queueObject
        record.payload = try JSONSerialization.data(withJSONObject: rebuilt)
        try context.save()

        let restoredEngine = makeEngine(clock)
        let restorer = PlaybackSessionPersistence(engine: restoredEngine, persistence: persistence, tracks: repository)
        let restored = await restorer.restore()

        XCTAssertTrue(restored)
        XCTAssertEqual(restoredEngine.queueSnapshot.items.count, 5,
                       "身份列在，就不该因为本地主键对不上而丢条目")
        XCTAssertEqual(restoredEngine.currentTrack?.identity, tracks[2].identity,
                       "当前曲目也要按身份恢复，而不是回落到第一首")
    }

    func testQueueRecordStoresIdentityForEveryItem() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let repository = persistence.makeTrackRepository()
        let tracks = MockCatalog.tracks(count: 3)
        for track in tracks { try await repository.save(track) }

        let clock = TestPlaybackClock()
        let engine = makeEngine(clock)
        engine.setQueue(tracks, current: tracks[1])
        await engine.load(tracks[1], autoplay: true)
        PlaybackSessionPersistence(engine: engine, persistence: persistence, tracks: repository).saveNow()

        let context = ModelContext(persistence.container)
        let record = try XCTUnwrap(try context.fetch(FetchDescriptor<QueueRecord>()).first)
        let wrapper = try XCTUnwrap(try JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
        let decoded = try XCTUnwrap(wrapper["identities"] as? [String])

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[1], PlaybackSessionPersistence.key(tracks[1].identity))
        XCTAssertEqual(wrapper["currentIdentity"] as? String,
                       PlaybackSessionPersistence.key(tracks[1].identity))
    }
}

/// 恢复现场的几条回归。
@MainActor
final class PlaybackSessionRestoreRegressionTests: XCTestCase {

    private func makeEngine(_ clock: TestPlaybackClock, behavior: MockBehavior = .healthy) -> PlaybackEngine {
        let registry = SourceRegistry()
        registry.register(MockPlaybackSource(behavior: behavior, clock: clock))
        return PlaybackEngine(clock: clock, coordinator: PlaybackCoordinator(registry: registry))
    }

    /// 排了一整张列表、只听了其中一首就退出：重启后队列必须还是那一整张。
    ///
    /// 旧实现只有"正在播的那一首"会进曲目库，其余条目重启后查不到，
    /// 队列从 23 首缩成 2 首——而且缩水后的队列随后又被存回去，原来那份也没了。
    func testWholeQueueSurvivesRestartEvenIfOnlyOneTrackWasPlayed() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let repository = persistence.makeTrackRepository()
        let tracks = MockCatalog.tracks(count: 8)
        let clock = TestPlaybackClock()

        let engine = makeEngine(clock)
        engine.setQueue(tracks, current: tracks[0])
        await engine.load(tracks[0], autoplay: true)
        engine.enqueueNext(tracks[5])
        engine.setRepeatMode(.all)
        let saver = PlaybackSessionPersistence(engine: engine, persistence: persistence, tracks: repository)
        saver.saveNow()
        await saver.flushTracks()

        let restoredEngine = makeEngine(clock)
        let restorer = PlaybackSessionPersistence(engine: restoredEngine, persistence: persistence, tracks: repository)
        let restored = await restorer.restore()

        XCTAssertTrue(restored)
        XCTAssertEqual(restoredEngine.queueSnapshot.items.count, 8, "没播过的曲目也要恢复回来")
        XCTAssertEqual(restoredEngine.queueSnapshot.nextUp.count, 1, "手动排的「下一首播放」重启后还在")
        XCTAssertEqual(restoredEngine.queueSnapshot.repeatMode, .all)
        XCTAssertEqual(restoredEngine.currentTrack?.identity, tracks[0].identity)
        XCTAssertEqual(restoredEngine.track(for: restoredEngine.queueSnapshot.items[7])?.title, tracks[7].title,
                       "恢复出来的条目要带着歌名，而不是一行「未知曲目」")
    }

    /// 恢复时音频没能装载（离线启动）：上次的进度不能被 0 覆盖。
    func testFailedRestoreDoesNotWipeTheSavedPosition() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let repository = persistence.makeTrackRepository()
        let tracks = MockCatalog.tracks(count: 2)
        let clock = TestPlaybackClock()

        let engine = makeEngine(clock)
        engine.setQueue(tracks, current: tracks[0])
        await engine.load(tracks[0], autoplay: true)
        clock.advance(by: .seconds(42))
        let saver = PlaybackSessionPersistence(engine: engine, persistence: persistence, tracks: repository)
        saver.saveNow()
        await saver.flushTracks()

        // 第二次启动：装载必败（没网）。
        let offline = makeEngine(clock, behavior: .failing(.networkUnavailable))
        let offlineSession = PlaybackSessionPersistence(engine: offline, persistence: persistence, tracks: repository)
        _ = await offlineSession.restore()
        XCTAssertNotNil(offline.state.error)
        offlineSession.saveNow()          // 状态变化触发的例行保存

        // 第三次启动：网络好了。
        let online = makeEngine(clock)
        _ = await PlaybackSessionPersistence(engine: online, persistence: persistence, tracks: repository).restore()
        XCTAssertEqual(online.position(at: clock.now), 42, accuracy: 0.5,
                       "一次离线启动就把上次的进度清零了")
    }

    /// 占位信息不能覆盖库里已有的正式歌名。
    func testPlaceholderMetadataDoesNotOverwriteAGoodRecord() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let repository = persistence.makeTrackRepository()
        let remote = SourceID(rawValue: "remote")
        let good = Track(sourceID: remote, externalID: "keepgood1",
                         title: "夜曲", artist: "周杰伦", album: nil, duration: 226,
                         artwork: ArtworkReference(.remote(URL(string: "https://example.com/x.jpg")!)))
        try await repository.save(good)
        let placeholder = Track(sourceID: remote, externalID: "keepgood1",
                                title: "keepgood1", artist: "", album: nil, duration: 0)
        try await repository.save(placeholder)

        let all = try await repository.all()
        let stored = try XCTUnwrap(all.first)
        XCTAssertEqual(stored.title, "夜曲")
        XCTAssertEqual(stored.artist, "周杰伦")
        XCTAssertEqual(stored.duration, 226)
        XCTAssertNotNil(stored.artwork)
        XCTAssertEqual(stored.id, placeholder.id, "本地 ID 跟着最新的那一份走")
    }

    /// 没播过的歌也能收藏，而且收藏之后查得到它的歌名。
    func testFavouritingAnUnplayedTrackKeepsItsMetadata() async throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        let track = Track(sourceID: SourceID(rawValue: "remote"), externalID: "favourite-1",
                          title: "稻香", artist: "周杰伦", album: nil, duration: 223)

        let isFavourite = await container.toggleFavorite(track)

        XCTAssertTrue(isFavourite)
        let favourites = await container.library.favorites()
        XCTAssertEqual(favourites, [track.identity])
        let stored = try await container.tracks.all().first { $0.identity == track.identity }
        XCTAssertEqual(stored?.title, "稻香", "收藏表只存身份：曲目库里必须有这首歌，抽屉才列得出来")
    }
}
