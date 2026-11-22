import Foundation

/// 曲目。模型层第一公民。
///
/// 身份约定：`(sourceID, externalID)` 唯一确定一首曲目；
/// `id` 是本地存储主键，会随库重建而变化，不用于跨会话比对。
/// 文件路径只可能出现在 `artwork` / `lyrics` 引用里，永远不是身份的一部分。
struct Track: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let sourceID: SourceID
    let externalID: String
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval
    let artwork: ArtworkReference?
    let lyrics: LyricsReference?
    /// 源的持久化句柄。对本地文件是 security-scoped bookmark 的 base64，
    /// 不是路径字符串——沙盒重启后靠它恢复访问权限。
    let persistentIdentifier: String?

    /// 元信息补全后重建一份轨道记录（Track 是不可变值类型，字段一律 let）。

    init(
        id: UUID = UUID(),
        sourceID: SourceID,
        externalID: String,
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval,
        artwork: ArtworkReference? = nil,
        lyrics: LyricsReference? = nil,
        persistentIdentifier: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.externalID = externalID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artwork = artwork
        self.lyrics = lyrics
        self.persistentIdentifier = persistentIdentifier
    }

    /// 元信息更新或重复搜索结果沿用队列已有的本地主键。
    func withID(_ id: UUID) -> Track {
        Track(id: id, sourceID: sourceID, externalID: externalID, title: title, artist: artist,
              album: album, duration: duration, artwork: artwork, lyrics: lyrics,
              persistentIdentifier: persistentIdentifier)
    }

    /// 稳定身份：源 + 源内标识。
    var identity: TrackIdentity { TrackIdentity(sourceID: sourceID, externalID: externalID) }

    static func == (lhs: Track, rhs: Track) -> Bool { lhs.identity == rhs.identity }

    func hash(into hasher: inout Hasher) { hasher.combine(identity) }
}

/// 可比较、可持久化的曲目身份。
struct TrackIdentity: Hashable, Codable, Sendable {
    let sourceID: SourceID
    let externalID: String

    /// 存储用的复合键。**全工程唯一实现**。
    ///
    /// 之前同样的编码/解码在三个仓储里各写了一遍（会话恢复、歌词偏移、资料库历史），
    /// 只要有一处忘了同步，同一条曲目在不同表里就会被当成两条。
    static func storageKey(_ identity: TrackIdentity) -> String {
        "\(identity.sourceID.rawValue)::\(identity.externalID)"
    }

    /// 从复合键还原。
    ///
    /// 只在**第一个** `::` 处切分：`externalID` 本身可能含 `::`
    /// （本地文件路径、带协议前缀的 ID）。旧实现用 `components(separatedBy:).count == 2`，
    /// 遇到这种 ID 会直接返回 nil，表现为"数据莫名其妙读不回来"。
    static func fromStorageKey(_ key: String) -> TrackIdentity? {
        guard let range = key.range(of: "::") else { return nil }
        let source = String(key[key.startIndex..<range.lowerBound])
        let external = String(key[range.upperBound...])
        guard !source.isEmpty, !external.isEmpty else { return nil }
        return TrackIdentity(sourceID: SourceID(source), externalID: external)
    }
}
