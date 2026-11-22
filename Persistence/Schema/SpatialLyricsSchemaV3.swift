import Foundation
import SwiftData

/// Schema V3：在 V2 基础上新增「歌单」表。
///
/// 同样是 lightweight（只加表），但必须在这里与迁移计划里都登记，
/// 否则老库打开会直接失败——V2 已经踩过一次这个规则。
enum SpatialLyricsSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        SpatialLyricsSchemaV2.models + [PlaylistRecord.self]
    }
}
