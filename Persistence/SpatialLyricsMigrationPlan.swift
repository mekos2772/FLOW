import Foundation
import SwiftData

/// 迁移计划。
///
/// V1 → V2 只新增表，使用 lightweight 迁移；一旦后续出现字段改名/拆分，
/// 就在这里追加自定义 `MigrationStage`，而不是在 App 启动时临时判断版本号。
enum SpatialLyricsMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SpatialLyricsSchemaV1.self, SpatialLyricsSchemaV2.self, SpatialLyricsSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: SpatialLyricsSchemaV1.self,
                toVersion: SpatialLyricsSchemaV2.self
            ),
            .lightweight(
                fromVersion: SpatialLyricsSchemaV2.self,
                toVersion: SpatialLyricsSchemaV3.self
            ),
        ]
    }
}
