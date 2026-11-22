import Foundation
import SwiftData

/// 版本化 schema。第一天就上版本，避免后期补迁移时被迫处理"空库 / 老库"双分支。
enum SpatialLyricsSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            TrackRecord.self,
            QueueRecord.self,
            PlaybackStateRecord.self,
            LyricsOffsetRecord.self,
            PlacementRecord.self,
            HistoryRecord.self,
            FavoriteRecord.self,
        ]
    }
}
