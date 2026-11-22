import Foundation
import SwiftData

/// 歌单。FLOW 自己的歌单，与 B 站收藏夹是两回事。
///
/// 为什么不做"往 B 站收藏夹写"：写接口要 `csrf`（`bili_jct`）签名，
/// 触发风控的概率明显高于读接口，而用户的真实需求是"在播放器里组织我想听的顺序"——
/// 这件事本地做更好：可以混放本地文件与在线曲目，也不依赖账号。
@Model
final class PlaylistRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    /// 有序的曲目身份键（`sourceID|externalID`），顺序即播放顺序。
    var itemKeys: [String]

    init(id: UUID = UUID(),
         name: String,
         createdAt: Date = .now,
         updatedAt: Date = .now,
         itemKeys: [String] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.itemKeys = itemKeys
    }
}
