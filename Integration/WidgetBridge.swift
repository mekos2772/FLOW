import Foundation
import WidgetKit

/// 主 App 与小组件之间的桥。
///
/// 两个方向：
/// - 向外：播放状态变化时写共享快照 + 请求 WidgetKit 重载时间线（不做高频轮询）；
/// - 向内：读取小组件按钮留下的命令，交给真正的播放引擎执行。
@MainActor
final class WidgetBridge {
    private let playback: PlaybackEngine
    private let lyricEngine: LyricEngine
    private let privacy: PrivacyState
    private var task: Task<Void, Never>?
    private var lastWrittenSignature: String = ""
    private var reloadThrottle = WidgetReloadThrottle()
    /// 注入时钟，方便测试节流。
    private let now: () -> Date

    /// 两次 `reloadAllTimelines` 的最小间隔。
    ///
    /// WidgetKit 对重载有预算限制（官方建议"不要频繁重载"）。
    /// 之前签名里带秒级进度，**播放时每秒都会重载一次**——正是会被系统限流的用法，
    /// 严重时限流后小组件直接不再更新。
    /// 现在：快照照常每秒写（写盘很便宜），但重载最多每 30 秒一次；
    /// 曲目/播放状态变化时立刻重载，保证"换歌"能马上反映。
    static let minimumReloadInterval: TimeInterval = 30

    init(playback: PlaybackEngine,
         lyricEngine: LyricEngine,
         privacy: PrivacyState,
         now: @escaping () -> Date = Date.init) {
        self.playback = playback
        self.lyricEngine = lyricEngine
        self.privacy = privacy
        self.now = now
    }

    func start() {
        task = Task { [weak self] in
            guard let self else { return }
            for await _ in self.playback.stateUpdates() {
                self.publishIfNeeded()
            }
        }
        publishIfNeeded(force: true)
    }

    func stop() {
        task?.cancel()
    }

    /// 遮罩变化等"内容该变但播放状态没变"的时刻，立刻重写一次并让小组件重载。
    func republish() { publishIfNeeded(force: true) }

    /// 进程退出前发布"已停止"。
    ///
    /// 不做这件事的后果：小组件时间线是 `.never`，App 退出后它会一直停在
    /// "正在播放 + 冻结的进度"，直到下次启动。
    func publishStoppedState() {
        let snapshot = makeSnapshot().stopped()
        SharedStateStore.write(privacy.isMasking ? snapshot.redacting() : snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 应用激活/启动时调用，处理小组件点过的按钮。
    func drainCommands() {
        let commands = SharedStateStore.drainCommands()
        guard !commands.isEmpty else { return }
        Task { [playback] in
            for command in commands {
                switch command {
                case .play: await playback.play()
                case .pause: await playback.pause()
                case .toggle: await playback.togglePlayback()
                case .next: await playback.skip(.next)
                case .previous: await playback.skip(.previous)
                }
            }
        }
    }

    private func publishIfNeeded(force: Bool = false) {
        let snapshot = makeSnapshot()
        // 写盘签名带秒级进度：同一秒内的重复变化不重复写。
        let signature = "\(snapshot.title ?? "")|\(snapshot.availability.rawValue)|\(Int(snapshot.position))|\(snapshot.upNext.count)"
        guard force || signature != lastWrittenSignature else { return }
        lastWrittenSignature = signature

        SharedStateStore.write(privacy.isMasking ? snapshot.redacting() : snapshot)

        // 重载与写盘分开节流：换歌/换状态要立刻反映，纯进度推进最多 30 秒一次。
        let identity = "\(snapshot.title ?? "")|\(snapshot.availability.rawValue)|\(snapshot.upNext.count)"
        guard reloadThrottle.shouldReload(identity: identity, now: now(), force: force) else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func makeSnapshot() -> PlaybackSnapshot {
        let track = playback.currentTrack
        let state = playback.state
        let lyricLine = track == nil ? nil : lyricEngine.snapshot(at: playback.currentPosition).current?.text
        let queue = playback.queueSnapshot

        // "接下来"三首：按真实播放顺序取展示标题。
        let upNext: [String] = UpNextPlanner.upcoming(queue: queue, currentID: queue.currentID, limit: 3)
            .compactMap { playback.track(for: $0) }
            .map { MorphPresentationModel.display($0).title }

        let availability: PlaybackSnapshot.Availability
        if track == nil {
            availability = .idle
        } else if state.isPlaying {
            availability = .playing
        } else {
            availability = .paused
        }

        return PlaybackSnapshot(
            availability: availability,
            title: track.map { MorphPresentationModel.display($0).title },
            artist: track.flatMap { MorphPresentationModel.display($0).artist },
            duration: playback.duration,
            position: playback.currentPosition,
            lyricLine: lyricLine,
            upNext: upNext,
            updatedAt: .now
        )
    }
}
