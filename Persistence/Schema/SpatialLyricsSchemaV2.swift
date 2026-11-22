import Foundation
import SwiftData

/// Schema V2：在 V1 基础上新增「播放日志」表。
///
/// 迁移策略是 lightweight：只加表、不改既有字段，SwiftData 可以自动完成，
/// 但**必须在 `SpatialLyricsMigrationPlan` 里显式登记**，否则老库打开会直接失败。
enum SpatialLyricsSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        SpatialLyricsSchemaV1.models + [PlaybackJournalRecord.self]
    }
}

/// 播放日志。V2 引入：记录一次播放的开始时间与时长，用于后续统计与诊断。
/// 与 `HistoryRecord` 的区别：历史是"听过什么"，日志是"听了多久"，两者用途不同。
@Model
final class PlaybackJournalRecord {
    @Attribute(.unique) var id: UUID
    var trackIdentityKey: String
    var startedAt: Date
    var secondsPlayed: Double

    init(id: UUID = UUID(),
         trackIdentityKey: String,
         startedAt: Date = .now,
         secondsPlayed: Double = 0) {
        self.id = id
        self.trackIdentityKey = trackIdentityKey
        self.startedAt = startedAt
        self.secondsPlayed = secondsPlayed
    }
}
