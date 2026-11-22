import SwiftData
import XCTest
@testable import SpatialLyricsPlayer

@MainActor
final class Phase6Tests: XCTestCase {

    // MARK: - 迁移

    func testMigrationPlanRegistersAllVersions() {
        // V1 → V2（播放日志）→ V3（歌单）：每一跳都必须显式登记，
        // 少登记一跳，老库打开会直接失败。
        XCTAssertEqual(SpatialLyricsMigrationPlan.schemas.count, 3)
        XCTAssertEqual(SpatialLyricsMigrationPlan.stages.count, 2)
        XCTAssertEqual(SpatialLyricsSchemaV2.models.count, SpatialLyricsSchemaV1.models.count + 1)
        XCTAssertEqual(SpatialLyricsSchemaV3.models.count, SpatialLyricsSchemaV2.models.count + 1)
        XCTAssertEqual(SpatialLyricsSchemaV2.versionIdentifier, Schema.Version(2, 0, 0))
        XCTAssertEqual(SpatialLyricsSchemaV3.versionIdentifier, Schema.Version(3, 0, 0))
    }

    func testV2StoreAcceptsJournalRecordsAndKeepsOldData() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = ModelContext(persistence.container)

        context.insert(TrackRecord(MockCatalog.tracks(count: 1)[0]))
        context.insert(PlaybackJournalRecord(trackIdentityKey: "mock::mock-001", secondsPlayed: 42))
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<TrackRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PlaybackJournalRecord>()).count, 1)
    }

    // MARK: - 日志脱敏

    func testLogRedactsQueryStringsAndPaths() {
        let message = "load https://example.com/a/b?sig=deadbeef&token=abc failed at /Users/alice/Music/secret/song.flac"
        let sanitized = RedactingLog.sanitize(message)

        XCTAssertFalse(sanitized.contains("sig=deadbeef"), "查询串必须被抹掉")
        XCTAssertFalse(sanitized.contains("/Users/alice"), "用户目录不得出现在日志里")
        XCTAssertFalse(sanitized.contains("token=abc"))
        XCTAssertTrue(sanitized.contains("<path>"))
    }

    func testLogRedactsLongTokens() {
        let token = String(repeating: "a", count: 40)
        let sanitized = RedactingLog.sanitize("cookie SESSDATA=\(token)")
        XCTAssertFalse(sanitized.contains(token))
        XCTAssertTrue(sanitized.contains("aaaa…"))
    }

    func testLogKeepsHarmlessText() {
        XCTAssertEqual(RedactingLog.sanitize("播放开始"), "播放开始")
    }

    // MARK: - 外观设置

    func testAppearanceClampsToUsableRange() {
        let store = InMemorySettingsStore()
        let appearance = AppearanceSettings(settings: store)

        appearance.setLyricFontSize(100)
        XCTAssertEqual(appearance.lyricFontSize, 30)
        appearance.setLyricFontSize(1)
        XCTAssertEqual(appearance.lyricFontSize, 11)

        appearance.setFloatingOpacity(5)
        XCTAssertEqual(appearance.floatingOpacity, 1)
        appearance.setFloatingOpacity(0)
        XCTAssertEqual(appearance.floatingOpacity, 0.3)
    }

    func testAppearancePersistsThroughStore() async {
        let store = InMemorySettingsStore()
        let appearance = AppearanceSettings(settings: store)
        appearance.setLyricLineSpacing(14)
        try? await Task.sleep(for: .milliseconds(20))

        let reloaded = AppearanceSettings(settings: store)
        XCTAssertEqual(reloaded.lyricLineSpacing, 14, accuracy: 0.001)
    }
}
