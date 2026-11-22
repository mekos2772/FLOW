import Foundation

/// 播放位置锚点。
///
/// 进度不存变量、不靠定时器累加，而由 (锚点, 当前时刻, 速率) 现算：
/// 暂停即把速率归零并重锚，恢复即以当前时刻重锚。这样状态机不需要周期性事件，
/// 主窗口、悬浮歌词、菜单栏共享同一个时钟推导结果，不会互相漂移。
struct PositionAnchor: Equatable, Sendable {
    var position: TimeInterval
    var hostTime: Instant
    var rate: Double

    static func anchored(at position: TimeInterval, now: Instant, rate: Double) -> PositionAnchor {
        PositionAnchor(position: position, hostTime: now, rate: rate)
    }

    func position(at now: Instant) -> TimeInterval {
        guard rate != 0 else { return position }
        return position + (now - hostTime).timeInterval * rate
    }

    /// 以当前时刻重新锚定，可同时改写位置与速率。
    func rebased(at now: Instant,
                 position newPosition: TimeInterval? = nil,
                 rate newRate: Double? = nil) -> PositionAnchor {
        PositionAnchor(
            position: newPosition ?? position(at: now),
            hostTime: now,
            rate: newRate ?? rate
        )
    }
}

/// 暂停原因。决定"条件恢复时该不该自动续播"，是冷启动语义的关键。
enum PauseReason: String, Codable, Sendable, CaseIterable {
    case user               // 用户主动暂停
    case interruption       // 系统音频中断
    case routeChanged       // 输出设备切换
    case headphonesUnplugged
    case system             // 睡眠、锁屏等系统事件
    case sleepTimer         // 睡眠定时器到点
    case preparing          // 加载完成但调用方要求不自动播放

    /// 被动暂停：条件恢复后应当自动续播。
    var isAutoResumable: Bool {
        switch self {
        case .interruption, .routeChanged, .headphonesUnplugged, .system: return true
        case .user, .sleepTimer, .preparing: return false
        }
    }

    /// 只有用户可感知的意图才值得跨进程保留。
    var shouldPersist: Bool { self == .user || self == .sleepTimer }
}

/// 跳转方向。
enum SkipDirection: String, Codable, Sendable, Equatable {
    case next
    case previous
    var opposite: SkipDirection { self == .next ? .previous : .next }
}

/// seek 完成后应回到哪个状态。
enum SeekReturn: String, Equatable, Sendable {
    case playing
    case paused
    case ready
}

/// seek 在途状态需要记住"从哪来、到哪去、回哪去"。
struct SeekTarget: Equatable, Sendable {
    var origin: TimeInterval
    var destination: TimeInterval
    var returnsTo: SeekReturn
}

/// 播放上下文。所有非 idle 状态共享的可变载荷。
struct PlaybackContext: Equatable, Sendable {
    var trackID: Track.ID?
    var duration: TimeInterval
    var anchor: PositionAnchor
    var retryCount: Int
    var pauseReason: PauseReason?
    /// 资源加载完成后是否自动开始播放（autoplay 语义在 preparing 期间暂存）。
    var pendingAutoplay: Bool

    static func empty(now: Instant) -> PlaybackContext {
        PlaybackContext(
            trackID: nil,
            duration: 0,
            anchor: .anchored(at: 0, now: now, rate: 0),
            retryCount: 0,
            pauseReason: nil,
            pendingAutoplay: false
        )
    }

    func clampedPosition(at now: Instant) -> TimeInterval {
        let raw = max(0, anchor.position(at: now))
        return duration > 0 ? min(raw, duration) : raw
    }
}
