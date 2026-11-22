import Foundation
import SwiftData

/// SwiftData 实现。用 `@ModelActor` 把 `ModelContext` 关在 actor 内，
/// 避免 `@Model` 实例跨隔离域流动。
@ModelActor
actor SwiftDataTrackRepository: TrackRepository {
    func save(_ track: Track) async throws {
        try upsert(track)
        try modelContext.save()
    }

    func save(contentsOf tracks: [Track]) async throws {
        guard !tracks.isEmpty else { return }
        for track in tracks { try upsert(track) }
        try modelContext.save()
    }

    private func upsert(_ track: Track) throws {
        let key = TrackRecord.identityKey(track.identity)
        var descriptor = FetchDescriptor<TrackRecord>(
            predicate: #Predicate { $0.identityKey == key }
        )
        descriptor.fetchLimit = 1

        guard let existing = try modelContext.fetch(descriptor).first else {
            modelContext.insert(TrackRecord(track))
            return
        }
        existing.localID = track.id
        // **占位信息不覆盖正式信息**。
        //
        // 歌单/BV 直开的曲目先以"标题 = BV 号、歌手为空、时长 0"入队，补全在后面才回来。
        // 之前这里无条件覆盖：已经存好的「夜曲 / 周杰伦 / 3:46」会被写回成一串 BV 号，
        // 而补全后的那一份又因为"这首已经存过"不再写——收藏、最近播放、恢复的队列全是 BV 号。
        if !track.hasPlaceholderTitle {
            existing.title = track.title
        }
        if !track.artist.isEmpty { existing.artist = track.artist }
        if let album = track.album { existing.album = album }
        if track.duration > 0 { existing.duration = track.duration }
        if let handle = track.persistentIdentifier { existing.persistentIdentifier = handle }
        existing.updatedAt = .now

        // 封面与歌词：**有才覆盖，没有就保留原来的**。
        //
        // 原来的更新分支完全没碰这两个字段，于是"先入库（还没有封面）→
        // 之后拿到封面再保存"时，新封面被静默丢掉，库里永远是空封面。
        // 反过来如果无条件覆盖，一次不带封面的保存又会把已有封面清掉。
        // 两种错都发生过，所以规则是"非空才写"。
        let encoder = JSONEncoder()
        if let artwork = track.artwork, let data = try? encoder.encode(artwork) {
            existing.artworkData = data
        }
        if let lyrics = track.lyrics, let data = try? encoder.encode(lyrics) {
            existing.lyricsData = data
        }
    }

    func all() async throws -> [Track] {
        let descriptor = FetchDescriptor<TrackRecord>(sortBy: [SortDescriptor(\.artist), SortDescriptor(\.title)])
        return try modelContext.fetch(descriptor).map { $0.asTrack() }
    }

    func count() async throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<TrackRecord>())
    }

    func removeAll() async throws {
        try modelContext.delete(model: TrackRecord.self)
        try modelContext.save()
    }
}
