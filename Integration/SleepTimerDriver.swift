import Foundation
import Observation

/// 把 `SleepTimer` 接到真实播放器上：等待到点后暂停播放。
///
/// 等待用 `PlaybackClock.sleep`，因此在测试里换成假时钟就能瞬间"过完"30 分钟，
/// 而不需要在测试里真的睡。同一时刻只允许一个等待任务，重新设定会取消旧的。
@MainActor
@Observable
final class SleepTimerDriver {
    private let playback: any PlaybackControlling
    private let clock: any PlaybackClock
    /// 到点先淡出再暂停；为 nil 时直接暂停（老行为）。
    private let fade: FadeDriver?
    /// 到点淡出时长，0 表示直接暂停。可在运行中修改（设置页会写这里）。
    var fadeOutDuration: Duration
    // `@Observable` 只跟踪存储属性：`task` 用 `@ObservationIgnored` 标掉，
    // `timer` 与 `armedMinutes` 必须参与跟踪，否则设定/取消之后界面不会重绘——
    // 表现就是"点了 30 分，下拉立刻弹回关闭，看起来完全没反应"。
    @ObservationIgnored private var task: Task<Void, Never>?
    private var timer = SleepTimer()

    init(playback: any PlaybackControlling,
         clock: any PlaybackClock = SystemPlaybackClock(),
         fade: FadeDriver? = nil,
         fadeOutDuration: Duration = .milliseconds(600)) {
        self.playback = playback
        self.clock = clock
        self.fade = fade
        self.fadeOutDuration = fadeOutDuration
    }

    var isArmed: Bool {
        if case .armed = timer.state { return true }
        return false
    }

    var remaining: Duration? { timer.remaining(at: clock.now) }

    /// 当前设定的是多少分钟（未设定为 nil）。
    ///
    /// 设置页的下拉需要一个稳定值：用它而不是用 `remaining` 反推，
    /// 否则倒计时每走一秒选中项就跟着变。
    private(set) var armedMinutes: Int?

    /// 设定定时。`duration` 为零或负数等价于取消。
    func start(for duration: Duration) {
        cancel()
        timer.arm(for: duration, now: clock.now)
        guard isArmed, let left = timer.remaining(at: clock.now) else { return }
        armedMinutes = max(1, Int(duration.components.seconds / 60))

        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: left)
            } catch {
                return  // 被取消的任务不需要再暂停
            }
            guard self.timer.evaluate(at: self.clock.now) else { return }
            // 只有真的在出声时才需要淡出；本来就停着的话到点什么都不用做。
            let isAudible = self.playback.state.isPlaying
            if isAudible, let fade = self.fade, self.fadeOutDuration > .zero {
                // 先淡出再暂停，避免"啪"地断掉。
                let finished = await fade.fadeOut(over: self.fadeOutDuration)
                // 淡出的这几百毫秒里用户取消了定时：声音已经还原，不能再暂停。
                guard finished, !Task.isCancelled else { return }
            }
            if isAudible { await self.playback.pause() }
            // 暂停之后把增益还原：淡出只是到点那一下的过渡，不能留到下一次播放。
            self.fade?.restore()
            self.task = nil
            self.armedMinutes = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        armedMinutes = nil
        timer.cancel()
        // 正在淡出时取消：把声音立刻还回来。
        if fade?.isFading == true { fade?.cancel() }
    }
}
