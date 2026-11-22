import Foundation

/// 每首歌独立的歌词偏移。
///
/// 键用 `(sourceID, externalID)` 而不是歌名：同名不同版本、同版本不同源的偏移不该互相污染。
protocol LyricsOffsetStoring: Sendable {
    func offset(for identity: TrackIdentity) async -> TimeInterval
    func save(_ offset: TimeInterval, for identity: TrackIdentity) async
    func remove(for identity: TrackIdentity) async
    func all() async -> [TrackIdentity: TimeInterval]
}
