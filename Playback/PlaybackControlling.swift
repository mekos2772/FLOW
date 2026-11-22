import Foundation

/// 表现层对播放内核的唯一依赖。
///
/// 主窗口、悬浮歌词、菜单栏、小组件快照、系统媒体桥接都只认这个协议，
/// 拿不到源实现、拿不到 session、也拿不到任何具体播放器实例。
@MainActor
protocol PlaybackControlling: AnyObject {
    var state: PlaybackState { get }
    var currentTrack: Track? { get }
    var isPlayingVoiceAI: Bool { get }
    var lastError: PlaybackError? { get }
    var duration: TimeInterval { get }
    /// 用引擎自己的时钟换算的当前位置。外部不要自己拿 `ContinuousClock().now` 去套。
    var currentPosition: TimeInterval { get }

    /// 由锚点现算的当前位置，调用方传入时刻以便测试注入。
    func position(at now: Instant) -> TimeInterval

    func load(_ track: Track, autoplay: Bool) async
    func play() async
    func pause() async
    func seek(to position: TimeInterval) async
    func skip(_ direction: SkipDirection) async
    func stop() async

    /// 播放状态流。订阅时先收到当前值，之后每次状态变化推送一次。
    /// 悬浮歌词、菜单栏、小组件快照共用这一条流，避免各自轮询。
    func stateUpdates() -> AsyncStream<PlaybackState>

    var volume: Float { get }
    var isMuted: Bool { get }
    func setVolume(_ value: Float)
    func toggleMute()
    /// 临时输出增益（0…1），乘在用户音量上。
    ///
    /// 给"到点淡出"这类**暂时性**的音量变化用：它不改 `volume` / `isMuted`，
    /// 所以淡完之后用户的音量设置原封不动，界面上的滑杆也不会跟着跳。
    var outputGain: Float { get }
    func setOutputGain(_ gain: Float)
    func cycleRepeatMode()
    func toggleShuffle()
    /// 直接设定循环模式（设置页的下拉用它；`cycleRepeatMode` 只适合按钮轮转）。
    func setRepeatMode(_ mode: RepeatMode)
    /// 直接设定随机开关。
    func setShuffling(_ on: Bool)
    /// 从队列里删掉一项。当前曲目不允许删（先跳到下一首再删）。
    @discardableResult
    func removeQueueItem(at index: Int) -> Bool

    /// 整体替换队列（收藏夹"播放全部"、搜索列表连播用）。
    /// `current` 为 nil 时只替换列表、不动当前曲目。
    func setQueue(_ tracks: [Track], current: Track?)

    /// 队列快照（只读）。队列界面据此渲染，不自己维护一份列表。
    var queueSnapshot: PlaybackQueue { get }
    /// 队列里某个 ID 对应的曲目快照（内存里已知的那一份）。
    ///
    /// 队列只存 `Track.ID`；持久库可能还没有这条记录（刚搜出来就播、还没落库），
    /// 这时抽屉应当用这份快照，而不是显示「未知曲目」。
    func track(for id: Track.ID) -> Track?
    func moveQueueItem(from source: Int, to destination: Int)
    /// 下一首播放（后进先出）。
    func enqueueNext(_ track: Track)
    /// 稍后播放（先进先出，排在"下一首播放"之后）。
    func enqueueLater(_ track: Track)
    func clearLater()
    /// 把一首从"下一首播放 / 稍后播放"里撤掉。返回是否真的撤了。
    @discardableResult
    func removePendingItem(_ id: Track.ID) -> Bool
    /// 清空当前曲目之后的所有排队条目（"清空待播"）。返回是否发生了变化。
    @discardableResult
    func clearUpNext() -> Bool

    /// 系统层与源回报事件的统一入口。
    func dispatch(_ event: PlaybackEvent) async
    /// 在保留当前曲目进度的前提下重载音频会话（如切换原曲 / AI 翻唱或音源更新）。
    func reloadAudioSource(autoplayIfInactive: Bool) async
}

extension PlaybackControlling {
    var isPlayingVoiceAI: Bool { false }

    func reloadAudioSource(autoplayIfInactive: Bool) async {
        guard let track = currentTrack else { return }
        let wasPlaying = state.isPlaying
        await dispatch(.sourceChanged(track.sourceID))
        if autoplayIfInactive, !wasPlaying, !state.isPlaying {
            await play()
        }
    }
    /// 播放键的**唯一**语义。完整播放器、迷你条、菜单栏、媒体键都走这一条。
    ///
    /// 之前三处各写了一份，行为并不一致：菜单栏那份在"没有当前曲目"和"加载失败"时
    /// 直接调 `play()`，被状态机拒绝——按钮有按下反馈，却什么都不发生。
    func togglePlayback() async {
        switch state {
        case .playing, .buffering:
            await pause()
        case .failed:
            // 失败后再按播放 = 再试一次，而不是一个没有反应的按钮。
            await retryCurrentTrack()
        case .idle:
            // 没有当前曲目但队列还在（"回到浏览"之后）：从队首开始。
            let queue = queueSnapshot
            guard let first = queue.currentID ?? queue.items.first,
                  let track = track(for: first) else { return }
            await load(track, autoplay: true)
        case .preparing, .seeking:
            // 正在装载/跳转：这一下不该打断它，也不假装响应。
            return
        case .ready, .paused, .ended:
            await play()
        }
    }

    /// 用户**主动**要求重试当前这首：整首重新装载并播放。
    ///
    /// 不走状态机的 `.retry`：那条是给自动恢复用的，有次数上限，超限后会直接跳下一首——
    /// 用户连点三次「重试」，结果歌被换掉了。手动重试没有理由被计数。
    func retryCurrentTrack() async {
        guard let track = currentTrack else { return }
        await load(track, autoplay: true)
    }

    /// 是否有东西可播（决定播放键是否可点）。
    var hasPlayableContent: Bool {
        currentTrack != nil || !queueSnapshot.items.isEmpty
    }
}
