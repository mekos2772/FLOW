import Foundation

/// 媒体引用：描述"去哪儿取"，不是媒体本体。
///
/// 只有 `embedded` 与 `file` 在离线状态下可解析；
/// `remote` 必须经过 `NetworkPolicyGate`，`opaque` 交给源自行解释。
enum MediaReference: Hashable, Codable, Sendable {
    case embedded(Data)
    case file(URL)
    case remote(URL)
    case opaque(String)

    /// 该引用是否必须在网络可用时才能解析。
    var requiresNetwork: Bool {
        if case .remote = self { return true }
        return false
    }
}

/// 封面引用。独立类型而非 `MediaReference` 别名，防止与歌词引用互换。
struct ArtworkReference: Hashable, Codable, Sendable {
    let media: MediaReference
    init(_ media: MediaReference) { self.media = media }
}

/// 歌词引用。
struct LyricsReference: Hashable, Codable, Sendable {
    let media: MediaReference
    init(_ media: MediaReference) { self.media = media }
}
