import Foundation
import SwiftData

/// 播放历史。只记"什么时候播过哪首"，不记任何媒体内容。
@Model
final class HistoryRecord {
    @Attribute(.unique) var key: String          // identity + 时间戳，保证同一首可多次入库
    var trackIdentityKey: String
    var playedAt: Date

    init(key: String, trackIdentityKey: String, playedAt: Date = .now) {
        self.key = key
        self.trackIdentityKey = trackIdentityKey
        self.playedAt = playedAt
    }
}

/// 收藏。同一首曲目只保留一条。
@Model
final class FavoriteRecord {
    @Attribute(.unique) var trackIdentityKey: String
    var addedAt: Date

    init(trackIdentityKey: String, addedAt: Date = .now) {
        self.trackIdentityKey = trackIdentityKey
        self.addedAt = addedAt
    }
}
