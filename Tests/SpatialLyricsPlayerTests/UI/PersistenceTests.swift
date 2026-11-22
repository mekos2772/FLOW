import SwiftData
import XCTest
@testable import SpatialLyricsPlayer

// 本地存储：schema 版本、曲目库、损坏恢复。

@MainActor
final class PersistenceTests: XCTestCase {

    func testSchemaVersionAndMigrationPlan() {
        XCTAssertEqual(SpatialLyricsSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
        XCTAssertEqual(SpatialLyricsSchemaV1.models.count, 7)
        XCTAssertEqual(SpatialLyricsMigrationPlan.schemas.count, 3, "V1 → V2 → V3 已登记")
        XCTAssertEqual(SpatialLyricsMigrationPlan.stages.count, 2, "每一跳都是 lightweight 迁移")
        XCTAssertEqual(SpatialLyricsSchemaV3.versionIdentifier, Schema.Version(3, 0, 0))
        XCTAssertEqual(SpatialLyricsSchemaV3.models.count,
                       SpatialLyricsSchemaV2.models.count + 1,
                       "V3 只新增歌单表")
    }

    func testContainerBuildsWithMigrationPlan() throws {
        let persistence = try PersistenceController(inMemory: true)
        XCTAssertTrue(persistence.isInMemory)

        let context = ModelContext(persistence.container)
        let track = MockCatalog.tracks(count: 1)[0]
        context.insert(TrackRecord(track))
        try context.save()

        let records = try context.fetch(FetchDescriptor<TrackRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].asTrack(), track)
    }

    func testRepositoryRoundTrip() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let repository = persistence.makeTrackRepository()
        let tracks = MockCatalog.tracks(count: 3)

        for track in tracks { try await repository.save(track) }
        let loaded = try await repository.all()

        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(Set(loaded.map(\.identity)), Set(tracks.map(\.identity)))
        let count = try await repository.count()
        XCTAssertEqual(count, 3)
    }

    func testRepositoryUpsertsByIdentity() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let repository = persistence.makeTrackRepository()

        let original = MockCatalog.tracks(count: 1)[0]
        try await repository.save(original)

        let renamed = Track(
            id: original.id,
            sourceID: original.sourceID,
            externalID: original.externalID,
            title: "改名后",
            artist: original.artist,
            duration: original.duration
        )
        try await repository.save(renamed)

        let loaded = try await repository.all()
        XCTAssertEqual(loaded.count, 1, "同 identity 必须 upsert 而不是插入新行")
        XCTAssertEqual(loaded[0].title, "改名后")
    }

    func testQueueRecordRoundTrip() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = ModelContext(persistence.container)

        let ids = MockCatalog.tracks(count: 2).map(\.id)
        let queue = PlaybackQueue(items: ids, currentID: ids[1], repeatMode: .all, shuffleSeed: 99)
        context.insert(QueueRecord(queue))
        try context.save()

        let records = try context.fetch(FetchDescriptor<QueueRecord>())
        XCTAssertEqual(records.count, 1)

        let restored = records[0].asQueue()
        XCTAssertEqual(restored.items, ids)
        XCTAssertEqual(restored.currentID, ids[1])
        XCTAssertEqual(restored.repeatMode, .all)
        XCTAssertEqual(restored.shuffleSeed, 99)
    }

    func testPlaybackStateRecordOnlyPersistsUserPauses() {
        let userPause = PlaybackStateRecord(trackIdentityKey: "mock::mock-001", position: 12, pauseReason: "user")
        let interruption = PlaybackStateRecord(trackIdentityKey: "mock::mock-001", position: 12, pauseReason: "interruption")

        XCTAssertTrue(userPause.shouldRestorePaused)
        XCTAssertFalse(interruption.shouldRestorePaused, "被动暂停不得跨进程保留")
    }

    func testPlacementRecordExistsInV1() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = ModelContext(persistence.container)
        context.insert(PlacementRecord(scopeKey: "screen-1"))
        try context.save()

        let records = try context.fetch(FetchDescriptor<PlacementRecord>())
        XCTAssertEqual(records.count, 1, "PlacementRecord 必须在 V1 就建表")
    }
}
@MainActor
final class LibraryStoreTests: XCTestCase {

    private func makeStore() throws -> SwiftDataLibraryStore {
        let persistence = try PersistenceController(inMemory: true)
        return SwiftDataLibraryStore(modelContainer: persistence.container)
    }

    private func identity(_ id: String) -> TrackIdentity {
        TrackIdentity(sourceID: SourceID("test"), externalID: id)
    }

    func testHistoryRecordsAndDeduplicatesByTrack() async throws {
        let store = try makeStore()
        await store.recordPlayed(identity("a"), at: .now)
        await store.recordPlayed(identity("a"), at: .now.addingTimeInterval(1))
        await store.recordPlayed(identity("b"), at: .now.addingTimeInterval(2))

        let recent = await store.recent(limit: 10)
        XCTAssertEqual(recent.count, 2, "同一首在最近播放里应去重")
        XCTAssertEqual(recent.first, identity("b"), "最近播放按时间倒序")
    }


    func testFavoritesToggle() async throws {
        let store = try makeStore()
        let isFavorite = await store.toggleFavorite(identity("a"))
        XCTAssertTrue(isFavorite)
        let favourite = await store.isFavorite(identity("a"))
        XCTAssertTrue(favourite)

        let removed = await store.toggleFavorite(identity("a"))
        XCTAssertFalse(removed)
        let stillFavourite = await store.isFavorite(identity("a"))
        XCTAssertFalse(stillFavourite)
    }

    func testClearHistoryKeepsFavorites() async throws {
        let store = try makeStore()
        await store.recordPlayed(identity("a"))
        _ = await store.toggleFavorite(identity("a"))
        await store.clearHistory()

        let recent = await store.recent(limit: 10)
        let favorites = await store.favorites()
        XCTAssertTrue(recent.isEmpty)
        XCTAssertEqual(favorites.count, 1)
    }

    func testHistoryIsTrimmedToLimit() async throws {
        let store = try makeStore()
        for index in 0..<210 {
            await store.recordPlayed(identity("t\(index)"), at: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let all = await store.recent(limit: 1000)
        XCTAssertEqual(all.count, 200, "上限是 200：多出来的旧记录要真的被删掉，而不只是不显示")
        XCTAssertEqual(all.first, identity("t209"), "留下的是最新的那批")
        XCTAssertFalse(all.contains(identity("t0")), "最早的记录应已被裁掉")
    }
}
@MainActor
final class CorruptionRecoveryTests: XCTestCase {

    private func tempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slp-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SpatialLyrics.store")
    }

    func testHealthyStoreDoesNotReportRecovery() throws {
        let url = try tempStoreURL()
        let persistence = try PersistenceController(inMemory: false, storeURL: url)
        XCTAssertFalse(persistence.recoveredFromCorruption)
        XCTAssertNil(persistence.quarantinedFileName)
    }

    func testCorruptStoreIsQuarantinedInsteadOfDeleted() throws {
        let url = try tempStoreURL()
        // 造一个不是 SQLite 的文件，模拟被外部写坏 / 磁盘错误。
        try Data("this is not a database".utf8).write(to: url)

        let persistence = try PersistenceController(inMemory: false, storeURL: url)

        XCTAssertTrue(persistence.recoveredFromCorruption, "损坏库必须走隔离重建")
        let quarantined = try XCTUnwrap(persistence.quarantinedFileName)
        XCTAssertTrue(quarantined.contains("corrupt"), "隔离文件名要带 corrupt 标记")

        let files = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        XCTAssertTrue(files.contains(quarantined), "原始文件必须保留下来，不能直接删")
    }

    func testRebuiltStoreIsUsable() throws {
        let url = try tempStoreURL()
        try Data("broken".utf8).write(to: url)

        let persistence = try PersistenceController(inMemory: false, storeURL: url)
        let context = ModelContext(persistence.container)
        context.insert(PlaybackJournalRecord(trackIdentityKey: "mock::1", secondsPlayed: 1))
        try context.save()

        XCTAssertGreaterThanOrEqual(try context.fetch(FetchDescriptor<PlaybackJournalRecord>()).count, 1)
    }
}
