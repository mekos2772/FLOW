import Foundation
import Observation

/// 播放内核编排器：接事件、跑状态机、执行 effect。
///
/// 隔离策略：全部状态在主 actor 上，不使用任何 GCD 队列。
/// 旧任务隔离：每次装载生成一个 token，异步回调返回时若 token 已变则直接丢弃，
/// 防止"快速连续切歌时上一首的加载结果覆盖新曲目状态"。
@MainActor
@Observable
final class PlaybackEngine: PlaybackControlling {
    private(set) var state: PlaybackState = .idle
    private(set) var currentTrack: Track?
    private(set) var isPlayingVoiceAI = false
    private(set) var lastError: PlaybackError?
    private(set) var queue: PlaybackQueue
    private(set) var rejectedEventCount = 0
    private(set) var volume: Float = 1
    private(set) var isMuted = false
    private(set) var outputGain: Float = 1

    private var machine: PlaybackStateMachine
    private let coordinator: PlaybackCoordinator
    /// 元信息补全任务（按曲目 id 取消旧的）。
    private var metadataTasks: [Track.ID: Task<Void, Never>] = [:]
    /// 补全完成后的回调：表现层据此刷新标题/封面。
    var metadataRefreshed: ((Track) -> Void)?
    private let clock: any PlaybackClock
    private var tracksByID: [Track.ID: Track] = [:]
    private var trackIDsByIdentity: [TrackIdentity: Track.ID] = [:]
    private var effectVersion: UInt64 = 0
    private var loadToken = UUID()
    private var pendingGaplessAutoAdvance = false
    /// 会话事件订阅。**必须**有：`.ended` 是曲目自然结束的唯一信号，
    /// 没人消费时状态机永远停在 `.playing`。
    private var sessionEventsTask: Task<Void, Never>?
    private var stateContinuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]

    init(clock: any PlaybackClock,
         coordinator: PlaybackCoordinator,
         queue: PlaybackQueue = PlaybackQueue()) {
        self.clock = clock
        self.coordinator = coordinator
        self.queue = queue
        self.machine = PlaybackStateMachine(now: clock.now)
        self.state = machine.state
    }

    // MARK: - 队列登记

    func setQueue(_ tracks: [Track], current: Track? = nil) {
        var seen: Set<Track.ID> = []
        var ids = tracks.map { register($0).id }.filter { seen.insert($0).inserted }
        let selected = current.map { register($0) } ?? currentTrack
        if let selected, !ids.contains(selected.id) { ids.insert(selected.id, at: 0) }
        queue.replace(items: ids, current: selected?.id)
        if let current { currentTrack = register(current) }
        broadcastState()
    }

    /// 冷启动恢复：把上次保存的队列**原样**装回来（含"下一首/稍后"与播放模式）。
    ///
    /// `setQueue` 是"用户换了一张列表"的语义，会清掉手动排的内容；
    /// 恢复不是换列表，所以单独一个入口。认不出的曲目会被剔掉。
    func restoreQueue(_ saved: PlaybackQueue, tracks: [Track]) {
        let ids = Dictionary(tracks.map { ($0.id, register($0).id) }, uniquingKeysWith: { first, _ in first })
        queue = PlaybackQueue.restored(from: saved.remappingIDs(ids), keeping: Set(ids.values))
        broadcastState()
    }

    /// 恢复持久化下来的播放模式与随机种子。
    func restoreRepeatMode(_ mode: RepeatMode, shuffleSeed: UInt64?) {
        queue.repeatMode = mode
        queue.shuffleSeed = shuffleSeed
        // 恢复后也要广播一次：界面模型靠状态流同步「播放模式」标签，
        // 不广播的话引擎里是「单曲循环」、界面却显示「顺序播放」（实测）。
        broadcastState()
    }

    /// 对外只读的队列快照，供持久化层与队列界面使用。
    var queueSnapshot: PlaybackQueue { queue }

    // MARK: - PlaybackControlling

    func position(at now: Instant) -> TimeInterval {
        guard let context = state.context else { return 0 }
        return context.clampedPosition(at: now)
    }

    var duration: TimeInterval { state.context?.duration ?? 0 }

    /// 用引擎自己的时钟换算当前位置。
    /// 外部不能拿 `ContinuousClock().now` 来算——测试注入的时钟与真实时钟不是同一条时间轴。
    var currentPosition: TimeInterval { position(at: clock.now) }

    func load(_ track: Track, autoplay: Bool) async {
        // 元信息补全**不进关键路径**。
        //
        // 之前是 `await coordinator.resolve(track)` 再装载：点一首歌要先等一次
        // B 站 view 接口（实测 146ms）才开始取流，连点几首就像"点了没反应"。
        // 现在立刻用原曲目开始装载，补全在后台跑完再把标题/歌手/封面换上去。
        //
        // 队列**只移动"当前"**，不重建：点队列里的另一首歌不该把刚拖好的顺序、
        // 刚删掉的条目、刚排的"下一首播放"全部还原（旧实现每次都 `replace`）。
        let track = register(track)
        queue.jump(to: track.id)
        currentTrack = track
        scheduleMetadataRefresh(for: track)
        await dispatch(.load(track, autoplay: autoplay))
    }

    /// 后台补全元信息；结果回来时只在"还是同一首"的情况下替换。
    private func scheduleMetadataRefresh(for track: Track) {
        metadataTasks[track.id]?.cancel()
        metadataTasks[track.id] = Task { [weak self] in
            guard let self else { return }
            guard let refreshed = await self.coordinator.resolve(track) else { return }
            guard !Task.isCancelled else { return }
            // 补全只换**元信息**，身份与队列位置都不变——所以不碰队列。
            // 旧实现在这里又 `replace` 了一次队列，等于每播一首需要补全的歌，
            // 用户手动排的"下一首/稍后"就被悄悄清空一次。
            let resolved = self.register(refreshed)
            // 期间用户可能已经切歌：只在仍是当前曲目时更新展示。
            guard self.currentTrack?.id == track.id else { return }
            self.currentTrack = resolved
            self.metadataRefreshed?(resolved)
            self.broadcastState()
        }
    }

    func play() async {
        switch state {
        case .paused:
            await dispatch(.resume)
        default:
            await dispatch(.play)
        }
    }

    func pause() async { await dispatch(.pause(.user)) }
    func seek(to position: TimeInterval) async { await dispatch(.seek(position)) }
    func skip(_ direction: SkipDirection) async {
        guard direction == .previous else {
            await dispatch(.next)
            return
        }
        // 已经播完的曲目上按「上一首」：从头再放一遍，而不是找上一首。
        if case .ended = state {
            await dispatch(.play)
            return
        }
        if shouldRestartCurrentTrack {
            // 失败态音频资源已经 releaseAudio，seek 会被状态机拒绝——
            // 「上一首」此刻等价于"把这首从头再播一遍"，整轨重载。
            if case .failed = state, let track = currentTrack {
                await load(track, autoplay: true)
                return
            }
            await dispatch(.seek(0))
            return
        }
        await dispatch(.previous)
    }

    /// 「上一首」的 3 秒规则，以及队首边界。
    ///
    /// 播过 3 秒按上一首 = 重头播本曲（QQ 音乐 / 网易云 / Apple Music 都是这个手感）。
    /// 队首再往前没有曲目时也重头播本曲，而不是把当前曲目丢掉 —— 旧实现会落到
    /// `requestNeighbor` 的 nil 分支 `dispatch(.stop)`，界面直接退回首页，
    /// 用户只知道"我点了一下上一首，歌没了"。
    private var shouldRestartCurrentTrack: Bool {
        guard state.isActive else { return false }
        if currentPosition > 3 { return true }
        return !queue.hasPrevious
    }

    func stop() async { await dispatch(.stop) }

    func reloadAudioSource(autoplayIfInactive: Bool) async {
        guard let track = currentTrack else { return }
        coordinator.cancelPrewarm()
        if case .failed = state {
            if autoplayIfInactive {
                await load(track, autoplay: true)
            }
            return
        }
        let wasPlaying = state.isPlaying
        await dispatch(.sourceChanged(track.sourceID))
        if autoplayIfInactive, !wasPlaying, !state.isPlaying {
            await play()
        }
    }

    // MARK: - 音量

    func setVolume(_ value: Float) {
        let clamped = max(0, min(value, 1))
        volume = clamped
        isMuted = clamped == 0
        if clamped > 0 { lastAudibleVolume = clamped }
        applyVolume()
        broadcastState()
    }

    /// 取消静音时恢复到的音量。
    ///
    /// 旧实现用 `max(volume, 0.001)`：可 `volume` 早就被写成 0 了，
    /// 于是"重新打开声音"只是变成 0.1%——听起来和静音没有区别，
    /// 而界面上那个喇叭图标又变回了有声形状，用户只能以为播放器坏了。
    /// 所以必须单独记住最后一次"听得见"的音量，而不是从当前值推导。
    private(set) var lastAudibleVolume: Float = 1

    func toggleMute() {
        if isMuted {
            isMuted = false
            if volume <= 0.001 { volume = lastAudibleVolume }
        } else {
            if volume > 0.001 { lastAudibleVolume = volume }
            isMuted = true
        }
        applyVolume()
        broadcastState()
    }

    /// 把"此刻该有多响"交给协调器。
    ///
    /// 协调器会**记住**这个值并套到之后每一个新会话上。旧实现只对"当前会话"
    /// 调一次 `setVolume`：新曲目的会话一律从 100% 起步——
    /// 音量拉到 30% 或静音之后一切歌就满音量炸出来，冷启动恢复的音量也形同虚设。
    func setOutputGain(_ gain: Float) {
        outputGain = max(0, min(gain, 1))
        applyVolume()
    }

    private func applyVolume() {
        let effective: Float = (isMuted ? 0 : volume) * outputGain
        coordinator.targetVolume = effective
        Task { [coordinator] in await coordinator.applyTargetVolume() }
    }

    func dispatch(_ event: PlaybackEvent) async {
        let outcome = machine.handle(event, now: clock.now)
        if !outcome.accepted { rejectedEventCount += 1 }
        guard outcome.accepted || !outcome.effects.isEmpty else { return }
        effectVersion &+= 1
        let version = effectVersion
        // 在第一个 await 之前隔离旧会话，包含同一首歌的重载与停止。
        if outcome.effects.contains(.cancelLoading) || outcome.effects.contains(.releaseAudio) {
            loadToken = UUID()
        }
        state = outcome.state
        currentTrack = resolveTrack(outcome.state.trackID)
        broadcastState()
        for effect in outcome.effects {
            guard version == effectVersion else { return }
            await perform(effect, version: version)
        }
    }

    func stateUpdates() -> AsyncStream<PlaybackState> {
        AsyncStream { continuation in
            let id = UUID()
            stateContinuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stateContinuations[id] = nil }
            }
        }
    }

    private func broadcastState() {
        isPlayingVoiceAI = coordinator.isPlayingVoiceAI
        syncPrewarm()
        for continuation in stateContinuations.values {
            continuation.yield(state)
        }
    }

    private func syncPrewarm() {
        if case .idle = state {
            coordinator.cancelPrewarm()
            return
        }
        guard state.isPlaying else { return }
        guard queue.repeatMode != .one,
              let nextID = queue.peekNext,
              nextID != currentTrack?.id,
              let nextTrack = tracksByID[nextID] else {
            coordinator.cancelPrewarm()
            return
        }
        coordinator.prewarm(track: nextTrack)
    }

    // MARK: - effect 执行

    private func perform(_ effect: PlaybackEffect, version: UInt64) async {
        switch effect {
        case .cancelLoading:
            // dispatch 已在状态迁移时使旧 token 失效。
            break

        case .releaseAudio:
            // 这里**不能**取消 `sessionEventsTask`：曲目自然播完后的自动续播就是在
            // 那个任务里触发的，`.releaseAudio` 正好在它的调用栈里——取消自己会让
            // 紧接着的 `beginLoading` 撞上 `Task.checkCancellation()`，新曲目永远停在
            // `.preparing`。会话在 `teardown()` 里 `invalidate()`，事件流自己会结束。
            await coordinator.teardown()

        case let .beginLoading(trackID, startAt, delay):
            await beginLoading(trackID: trackID, startAt: startAt, delay: delay, version: version)

        case let .reloadCurrentTrack(_, position):
            await reloadCurrentTrack(position: position)

        case .playAudio:
            await coordinator.play()

        case .pauseAudio:
            await coordinator.pause()

        case let .seekAudio(position):
            await coordinator.seek(to: position)
            if version == effectVersion, case .seeking = machine.state {
                await dispatch(.seekFinished(position))
            }

        case let .requestNeighbor(direction):
            guard let neighbor = neighbor(direction) else {
                await dispatch(.stop)
                return
            }
            await dispatch(.load(neighbor, autoplay: true))

        case let .reportError(error):
            lastError = error

        case .publish:
            // `dispatch` 在执行 effect **之前**已经同步落了状态并广播过。
            // 这里再按 effect 里那份快照写一次是纯粹的隐患：effect 之间有 `await`，
            // 期间一旦插进来另一次 dispatch，这份旧快照会把 `state` 写回过去
            // （引擎说"在装载 A"，状态机实际在装载 B，界面永远停在加载中）。
            break
        }
    }

    private func beginLoading(trackID: Track.ID, startAt: TimeInterval, delay: Duration, version: UInt64) async {
        if delay > .zero {
            try? await clock.sleep(for: delay)
        }
        guard version == effectVersion else { return }
        if Task.isCancelled {
            await dispatch(.stop)
            return
        }
        // 等待期间（重试退避、上一条 effect 的 `await`）用户可能已经切走。
        // 这条装载已经没人要了：再往下走会覆盖 `loadToken`、把新曲目的装载顶掉，
        // 而它自己的结果又会因为曲目对不上被丢弃——两头落空，界面卡死在"加载中"。
        guard case .preparing = machine.state, machine.state.trackID == trackID else { return }
        guard let track = tracksByID[trackID] else {
            await dispatch(.loadFailed(.sourceUnavailable))
            return
        }

        let token = UUID()
        loadToken = token
        let preferGapless = pendingGaplessAutoAdvance
        pendingGaplessAutoAdvance = false

        do {
            let duration = try await coordinator.beginLoading(
                track: track,
                startAt: startAt,
                preferGaplessTransition: preferGapless
            )
            guard loadToken == token, machine.state.trackID == trackID else { return }
            startObservingSessionEvents(token: token)
            await dispatch(.resourceReady(duration: duration))
        } catch {
            guard loadToken == token, machine.state.trackID == trackID else { return }
            let mapped = coordinator.map(error)
            if error is CancellationError || mapped == .cancelled {
                await dispatch(.stop)
            } else {
                await dispatch(.loadFailed(mapped))
            }
        }
    }

    private func reloadCurrentTrack(position: TimeInterval) async {
        guard let track = currentTrack ?? resolveTrack(machine.state.trackID) else { return }
        let token = UUID()
        loadToken = token
        do {
            let duration = try await coordinator.beginLoading(track: track, startAt: position)
            guard loadToken == token else { return }
            startObservingSessionEvents(token: token)
            await dispatch(.resourceReady(duration: duration))
        } catch {
            guard loadToken == token else { return }
            let mapped = coordinator.map(error)
            if error is CancellationError || mapped == .cancelled {
                await dispatch(.stop)
            } else {
                await dispatch(.loadFailed(mapped))
            }
        }
    }

    // MARK: - 队列推进

    /// 订阅当前会话的事件流。
    ///
    /// 旧实现里**没有任何地方读 `session.events`**：`.ended` 永远到不了状态机，
    /// 一首放完界面就停在 `.playing`（喇叭显示"暂停"）、进度冻在总时长，
    /// 再按播放又会被 `.playing` 分支拒绝——表现就是"放完了就卡死"。
    private func startObservingSessionEvents(token: UUID) {
        // 自然续播可能仍在旧订阅的调用栈中；取消它会连新歌的 prepare 一起取消。
        // 旧会话 invalidate 后事件流自行结束，迟到事件由 loadToken 拦截。
        guard let session = coordinator.session else { return }
        sessionEventsTask = Task { [weak self] in
            for await event in session.events {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.handle(sessionEvent: event, token: token)
            }
        }
    }

    private func handle(sessionEvent: SessionEvent, token: UUID) async {
        // 旧会话的迟到事件不能作用到新曲目上。
        guard token == loadToken else { return }
        switch sessionEvent {
        case .ended:
            await finishCurrentTrack()
        case let .failed(error):
            await dispatch(.playbackFailed(error))
        case let .stalled(isStalled):
            await dispatch(isStalled ? .stallBegan : .stallEnded)
        case .prepared, .rateChanged:
            // 时长已由 `beginLoading` 的返回值喂给状态机，这里不重复。
            break
        }
    }

    /// 曲目自然播完：交给播放模式决定重播 / 下一首 / 停在原地。
    private func finishCurrentTrack() async {
        await dispatch(.playbackFinished)
        guard case .ended = state else { return }
        switch queue.repeatMode {
        case .one:
            // 单曲循环：`.ended` 上的 play 语义就是"从头再来"。
            await dispatch(.play)
        case .all, .off:
            // 顺序/列表循环：能往后走就走；走不动就停在这首（不再清空队列）。
            guard let next = neighbor(.next) else { return }
            pendingGaplessAutoAdvance = true
            await dispatch(.load(next, autoplay: true))
        }
    }

    private func neighbor(_ direction: SkipDirection) -> Track? {
        let id: Track.ID?
        switch direction {
        case .next: id = queue.advance()
        case .previous: id = queue.regress()
        }
        guard let id, let track = tracksByID[id] else { return nil }
        return track
    }

    // MARK: - 队列操作（供 UI 调用）

    // 队列的每一次改动都要广播：界面投影、持久化、控制中心都只认 `stateUpdates()`。
    // 之前只有"删除一项"广播了，拖动排序 / 下一首播放 / 清空待播都只改了内存——
    // 界面要靠各处手动刷新，退出时也可能存下旧队列。

    func enqueueNext(_ track: Track) {
        let track = register(track)
        queue.enqueueNext(track.id)
        broadcastState()
    }

    func enqueueLater(_ track: Track) {
        let track = register(track)
        queue.enqueueLater(track.id)
        broadcastState()
    }

    func clearLater() {
        queue.clearLater()
        broadcastState()
    }

    @discardableResult
    func clearUpNext() -> Bool {
        let changed = queue.clearUpNext()
        if changed { broadcastState() }
        return changed
    }

    func moveQueueItem(from source: Int, to destination: Int) {
        queue.move(from: source, to: destination)
        broadcastState()
    }

    @discardableResult
    func removePendingItem(_ id: Track.ID) -> Bool {
        let changed = queue.removePending(id)
        if changed { broadcastState() }
        return changed
    }

    /// 从队列删掉一项。
    ///
    /// 不允许删**正在播放**的那一项：那样会让"当前曲目"凭空消失、音频却还在响。
    /// 想删它就先跳到下一首。当前曲目在界面上也不会显示删除按钮。
    @discardableResult
    func removeQueueItem(at index: Int) -> Bool {
        guard queue.items.indices.contains(index) else { return false }
        guard queue.items[index] != queue.currentID else { return false }
        queue.remove(at: index)
        broadcastState()
        return true
    }

    func cycleRepeatMode() {
        queue.repeatMode = queue.repeatMode.next
        // 必须广播：持久化、控制中心、队列界面都靠 stateUpdates() 拿变化。
        // 少了这一行，模式只在内存里变了——退出再进来又回到"顺序播放"（实测）。
        broadcastState()
    }

    func toggleShuffle() {
        if queue.isShuffling {
            queue.shuffleSeed = nil
        } else {
            queue.shuffleSeed = UInt64.random(in: 1...UInt64.max)
        }
        broadcastState()
    }

    func setRepeatMode(_ mode: RepeatMode) {
        guard queue.repeatMode != mode else { return }
        queue.repeatMode = mode
        // 广播一次：订阅方（持久化、控制中心、队列界面）都靠 stateUpdates() 拿变化，
        // 队列模式虽然没有独立的事件通道，但走同一条广播就能一起被记下。
        broadcastState()
    }

    func setShuffling(_ on: Bool) {
        guard queue.isShuffling != on else { return }
        queue.shuffleSeed = on ? UInt64.random(in: 1...UInt64.max) : nil
        broadcastState()
    }

    func track(for id: Track.ID) -> Track? { tracksByID[id] }

    private func register(_ track: Track) -> Track {
        let id = trackIDsByIdentity[track.identity] ?? track.id
        let canonical = track.withID(id)
        trackIDsByIdentity[track.identity] = id
        tracksByID[id] = canonical
        return canonical
    }

    private func resolveTrack(_ id: Track.ID?) -> Track? {
        guard let id else { return nil }
        return tracksByID[id]
    }
}
