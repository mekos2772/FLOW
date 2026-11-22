import Foundation

/// 睡眠定时器（P1）：到点后暂停播放。
///
/// 只做时间判定，不持有播放器也不启动任务——这样它能在纯测试里用假时钟推进验证，
/// 而不需要真的等 30 分钟。真正的等待由调用方用 `PlaybackClock.sleep` 完成。
struct SleepTimer: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case off                        // 未启用
        case armed(deadline: Instant)   // 已设定，等待到期
        case fired                      // 已到期，尚未被清理
    }

    private(set) var state: State = .off

    /// 设定一个截止时刻。重复设定会覆盖旧期限，而不是叠加。
    mutating func arm(for duration: Duration, now: Instant) {
        guard duration > .zero else {
            state = .off
            return
        }
        state = .armed(deadline: now + duration)
    }

    mutating func cancel() {
        state = .off
    }

    /// 剩余时间。未启用或已到期时返回 nil。
    func remaining(at now: Instant) -> Duration? {
        guard case let .armed(deadline) = state else { return nil }
        let left = deadline - now
        return left > .zero ? left : nil
    }

    /// 时钟推进后调用。第一次到期返回 true，之后再调用返回 false——
    /// 上层据此只暂停一次，不会反复触发。
    mutating func evaluate(at now: Instant) -> Bool {
        guard case let .armed(deadline) = state, now >= deadline else { return false }
        state = .fired
        return true
    }
}
