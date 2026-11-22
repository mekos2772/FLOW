import Foundation
import SwiftData

/// 冷启动恢复所需的播放现场。只记录用户意图，不记录被动暂停。
@Model
final class PlaybackStateRecord {
    @Attribute(.unique) var slot: String
    var trackIdentityKey: String?
    var position: Double
    var pauseReason: String?
    var updatedAt: Date

    init(slot: String = "main",
         trackIdentityKey: String?,
         position: Double,
         pauseReason: String?,
         updatedAt: Date = .now) {
        self.slot = slot
        self.trackIdentityKey = trackIdentityKey
        self.position = position
        self.pauseReason = pauseReason
        self.updatedAt = updatedAt
    }
}

extension PlaybackStateRecord {
    /// 只有用户可感知的暂停才值得跨进程保留。
    var shouldRestorePaused: Bool {
        guard let pauseReason, let reason = PauseReason(rawValue: pauseReason) else { return false }
        return reason.shouldPersist
    }
}
