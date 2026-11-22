import Foundation

/// 歌词偏移的内存实现。
///
/// 与 SwiftData 版语义保持一致：逐曲目独立、毫秒级、没有记录时返回 0。
/// 存在的意义是让 `LyricEngine` 能在测试与预览里被构造出来，
/// 而不必为了验一条偏移逻辑去拉起数据库。
actor InMemoryLyricsOffsetStore: LyricsOffsetStoring {
    private var offsets: [TrackIdentity: TimeInterval]

    init(seed: [TrackIdentity: TimeInterval] = [:]) {
        self.offsets = seed
    }

    func offset(for identity: TrackIdentity) async -> TimeInterval {
        let stored = storedOffset(for: identity)
        return stored.isFinite ? stored : 0
    }

    private func storedOffset(for identity: TrackIdentity) -> TimeInterval {
        offsets[identity] ?? 0
    }

    func save(_ offset: TimeInterval, for identity: TrackIdentity) async {
        guard offset.isFinite else { return }
        offsets[identity] = offset
    }

    func remove(for identity: TrackIdentity) async {
        offsets[identity] = nil
    }

    func all() async -> [TrackIdentity: TimeInterval] {
        offsets
    }
}
