import Foundation

/// 歌单里的一个条目：只存身份，不存标题。
///
/// 身份是 `(sourceID, externalID)`——本地文件是路径，在线是 BV 号。
/// 标题、时长每次从曲目库读，避免"歌单里存了旧标题"这种数据腐烂。
struct PlaylistEntry: Hashable, Sendable, Codable {
    var sourceID: SourceID
    var externalID: String

    init(sourceID: SourceID, externalID: String) {
        self.sourceID = sourceID
        self.externalID = externalID
    }

    init?(key: String) {
        let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        self.sourceID = SourceID(rawValue: String(parts[0]))
        self.externalID = String(parts[1])
    }

    var key: String { "\(sourceID.rawValue)|\(externalID)" }
}

/// 歌单快照（值类型，供 UI 与测试）。
struct Playlist: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var entries: [PlaylistEntry]
    var updatedAt: Date

    var count: Int { entries.count }
}

/// 歌单存储。
///
/// 只暴露值类型，`@Model` 不出持久化层——与曲目库/历史库的约定一致。
@MainActor
protocol PlaylistStoring: AnyObject {
    func playlists() -> [Playlist]
    @discardableResult func create(name: String) -> Playlist
    func rename(id: UUID, to name: String)
    func delete(id: UUID)
    /// 追加到末尾；已存在时不重复添加（返回 false）。
    @discardableResult func add(_ entry: PlaylistEntry, to id: UUID) -> Bool
    func remove(_ entry: PlaylistEntry, from id: UUID)
    /// 拖动排序：把 `from` 位置的条目移到 `to` 位置（`to` 是移动后的目标下标）。
    func move(in id: UUID, from: Int, to: Int)
    func entries(in id: UUID) -> [PlaylistEntry]
}
