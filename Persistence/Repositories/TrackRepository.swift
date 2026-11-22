import Foundation

/// 持久化对外协议。只进只出值类型，`@Model` 不出这一层。
protocol TrackRepository: Sendable {
    func save(_ track: Track) async throws
    /// 一次存一批（队列里的全部曲目）。默认逐条存；SwiftData 实现会合成一次落盘。
    func save(contentsOf tracks: [Track]) async throws
    func all() async throws -> [Track]
    func count() async throws -> Int
    func removeAll() async throws
}

extension TrackRepository {
    func save(contentsOf tracks: [Track]) async throws {
        for track in tracks { try await save(track) }
    }
}

extension Track {
    /// 标题只是个占位符（空、或者就是源内标识本身）。
    ///
    /// 歌单、粘贴 BV 号直开的曲目在元信息补全之前就是这个样子。
    /// 用它去**覆盖**库里已有的正式歌名，收藏和最近播放里就会出现一串 BV 号。
    var hasPlaceholderTitle: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == externalID
    }
}
