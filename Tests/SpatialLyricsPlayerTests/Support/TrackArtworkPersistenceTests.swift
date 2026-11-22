import XCTest
import SwiftData
@testable import SpatialLyricsPlayer

/// 重复保存同一首时，封面与歌词的更新规则。
///
/// 原来的更新分支完全不碰 `artworkData` / `lyricsData`：
/// "先入库（还没有封面）→ 之后拿到封面再保存"时，新封面被**静默丢掉**，
/// 库里永远是空封面。反过来，无条件覆盖又会让一次不带封面的保存清掉已有封面。
/// 正确规则：**非空才写**。
@MainActor
final class TrackArtworkPersistenceTests: XCTestCase {

    private func makeRepository() throws -> (SwiftDataTrackRepository, ModelContainer) {
        let container = try PersistenceController(inMemory: true).container
        return (SwiftDataTrackRepository(modelContainer: container), container)
    }

    private func track(artwork: ArtworkReference?, lyrics: LyricsReference? = nil) -> Track {
        Track(sourceID: SourceID(rawValue: "bili"),
              externalID: "BV1artwork",
              title: "封面测试",
              artist: "测试",
              album: nil,
              duration: 100,
              artwork: artwork,
              lyrics: lyrics)
    }

    func testArtworkAddedOnLaterSave() async throws {
        let (repo, _) = try makeRepository()
        try await repo.save(track(artwork: nil))
        try await repo.save(track(artwork: ArtworkReference(.remote(URL(string: "https://example.invalid/1.jpg")!))))

        let saved = try await repo.all().first
        XCTAssertEqual(saved?.artwork, ArtworkReference(.remote(URL(string: "https://example.invalid/1.jpg")!)),
                       "后来拿到的封面必须写进去")
    }

    func testArtworkNotWipedByLaterSaveWithoutIt() async throws {
        let (repo, _) = try makeRepository()
        try await repo.save(track(artwork: ArtworkReference(.remote(URL(string: "https://example.invalid/2.jpg")!))))
        try await repo.save(track(artwork: nil))

        let saved = try await repo.all().first
        XCTAssertEqual(saved?.artwork, ArtworkReference(.remote(URL(string: "https://example.invalid/2.jpg")!)),
                       "一次不带封面的保存不能清掉已有封面")
    }
}
