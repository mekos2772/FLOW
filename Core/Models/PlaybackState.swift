import Foundation

/// 九态播放状态机。整个应用只有一个事实来源，所有界面读它。
///
/// 之所以不用 isPlaying/isLoading/isBuffering 几个布尔量组合：
/// 布尔量允许出现"既在加载又在播放""失败但仍显示播放中"等非法组合，
/// 而枚举天然互斥，非法组合在类型层面就不存在。
enum PlaybackState: Equatable, Sendable {
    case idle
    case preparing(PlaybackContext)
    case ready(PlaybackContext)
    case playing(PlaybackContext)
    case paused(PlaybackContext, PauseReason)
    case buffering(PlaybackContext)
    case seeking(PlaybackContext, SeekTarget)
    case ended(PlaybackContext)
    case failed(PlaybackContext?, PlaybackError)

    var context: PlaybackContext? {
        switch self {
        case .idle: return nil
        case let .preparing(ctx), let .ready(ctx), let .playing(ctx),
             let .buffering(ctx), let .ended(ctx):
            return ctx
        case let .paused(ctx, _): return ctx
        case let .seeking(ctx, _): return ctx
        case let .failed(ctx, _): return ctx
        }
    }

    var trackID: Track.ID? { context?.trackID }

    var isIdle: Bool { if case .idle = self { return true }; return false }
    var isPlaying: Bool { if case .playing = self { return true }; return false }
    var isActive: Bool { !isIdle }  // 已装载曲目

    var pauseReason: PauseReason? {
        if case let .paused(_, reason) = self { return reason }
        return nil
    }

    var error: PlaybackError? {
        if case let .failed(_, error) = self { return error }
        return nil
    }

    /// 供日志、测试与调试面板使用的稳定标签。
    var debugLabel: String {
        switch self {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .playing: return "playing"
        case let .paused(_, reason): return "paused(\(reason.rawValue))"
        case .buffering: return "buffering"
        case .seeking: return "seeking"
        case .ended: return "ended"
        case .failed(_, let error): return "failed(\(error))"
        }
    }
}
