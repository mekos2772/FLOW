import Foundation

/// 播放历史与收藏。
///
/// 历史只保留最近 N 条（默认 200），避免数据库无限增长；
/// 收藏是全量的，用户显式点星就不该被自动清理。
protocol LibraryStoring: Sendable {
    func recordPlayed(_ identity: TrackIdentity, at date: Date) async
    func recent(limit: Int) async -> [TrackIdentity]
    func toggleFavorite(_ identity: TrackIdentity) async -> Bool
    func favorites() async -> [TrackIdentity]
    func isFavorite(_ identity: TrackIdentity) async -> Bool
    func clearHistory() async
}
