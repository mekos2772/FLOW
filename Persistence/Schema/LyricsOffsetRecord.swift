import Foundation
import SwiftData

/// 每首曲目的歌词偏移记忆。Phase 2 使用，Phase 0 先建表以验证迁移链路。
@Model
final class LyricsOffsetRecord {
    @Attribute(.unique) var trackIdentityKey: String
    var offset: Double
    var updatedAt: Date

    init(trackIdentityKey: String, offset: Double, updatedAt: Date = .now) {
        self.trackIdentityKey = trackIdentityKey
        self.offset = offset
        self.updatedAt = updatedAt
    }
}
