import Foundation

/// 把 `FadeRamp` 应用到真实播放器上。
///
/// 淡变走的是引擎的**临时输出增益**（`setOutputGain`），不是用户音量：
/// - 用户音量、静音状态、界面上的滑杆全程不动；
/// - 淡完之后把增益还原成 1 即可，不存在"还原到多少"的问题。
///
/// 旧实现直接改 `volume`：到点淡出把音量一路写到 0 之后就没人管了——
/// 第二天按播放没有声音，喇叭图标是静音，取消静音回来的是 8%（淡出的最后一步），
/// 而且静音着听歌的人会在淡出开始的那一刻突然被取消静音。
///
/// 每个间隔写一次增益，因此步数不能太大——600ms / 60ms = 10 步，
/// 每一步只是一次属性写入，不会让主线程掉帧。
@MainActor
final class FadeDriver {
    private let playback: any PlaybackControlling
    private let clock: any PlaybackClock
    private var task: Task<Void, Never>?

    init(playback: any PlaybackControlling, clock: any PlaybackClock = SystemPlaybackClock()) {
        self.playback = playback
        self.clock = clock
    }

    /// 是否有一条淡变正在进行。
    var isFading: Bool { task != nil }

    /// 把输出淡到无声。结束后增益停在 0，调用方暂停之后要 `restore()`。
    /// 返回 false 表示中途被取消（调用方不应继续做"淡完之后"的事）。
    @discardableResult
    func fadeOut(over duration: Duration, interval: Duration = .milliseconds(60)) async -> Bool {
        await perform(from: playback.outputGain, to: 0, over: duration, interval: interval)
    }

    /// 把输出从当前增益淡回原声。
    @discardableResult
    func fadeIn(over duration: Duration, interval: Duration = .milliseconds(60)) async -> Bool {
        await perform(from: playback.outputGain, to: 1, over: duration, interval: interval)
    }

    /// 立刻还原成原声（淡出完成并暂停之后调用；此时没有声音，听不出跳变）。
    func restore() {
        task?.cancel()
        task = nil
        playback.setOutputGain(1)
    }

    /// 取消正在进行的淡变，并立刻还原成原声。
    func cancel() { restore() }

    private func perform(from: Float, to: Float, over duration: Duration, interval: Duration) async -> Bool {
        task?.cancel()
        let gains = FadeRamp.volumes(from: from, to: to,
                                     steps: FadeRamp.stepCount(duration: duration, interval: interval))
        let wait = duration / max(1, gains.count - 1)
        let work = Task { [weak self] in
            guard let self else { return }
            for (index, gain) in gains.enumerated() {
                if Task.isCancelled { return }
                self.playback.setOutputGain(gain)
                if index < gains.count - 1 {
                    try? await self.clock.sleep(for: wait)
                }
            }
        }
        task = work
        await work.value
        let finished = !work.isCancelled
        if task == work { task = nil }
        return finished
    }
}
