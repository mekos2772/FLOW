import Foundation
import SwiftData

/// 播放现场持久化：队列 + 当前曲目 + 位置 + 模式。
///
/// 冷启动恢复的语义（对应规格 15.1）：
/// - 恢复队列与曲目元信息，但**不自动播放**；
/// - 恢复上次进度并把播放位置摆好，等用户按播放键；
/// - 音频资源失效时保留元信息、报告可恢复的错误，而不是静默丢掉这首歌。
@MainActor
final class PlaybackSessionPersistence {
    private let engine: PlaybackEngine
    private let persistence: PersistenceController
    private let tracks: any TrackRepository
    private var saveTask: Task<Void, Never>?
    private var trackSaveTask: Task<Void, Never>?
    /// 已经落过库的曲目（按"身份 + 标题"记，标题补全后会再存一次）。
    private var persistedTrackKeys: Set<String> = []
    /// 恢复出来、但**还没真正摆到位**的进度。
    ///
    /// 恢复时要先把音频装载好才能跳到上次的位置；装载要联网，可能很慢，也可能失败。
    /// 这段时间里引擎报的位置是 0——照实存下去，上次的进度就被 0 覆盖了
    /// （离线启动一次，或者装载到一半就退出，下回都从头开始）。
    /// 所以在进度真正生效之前，存盘用的是这份"待恢复"的值。
    /// 冷启动恢复尚未结束时置位，防止启动 1 秒节流或失焦写库把空队列/0进度反写回库。
    private var isInitialRestorePending = false
    private var pendingPosition: (identity: TrackIdentity, position: TimeInterval)?

    init(engine: PlaybackEngine, persistence: PersistenceController, tracks: any TrackRepository) {
        self.engine = engine
        self.persistence = persistence
        self.tracks = tracks
    }

    /// 由冷启动入口在异步 `restore()` 前标记；在 `restore()` 返回前禁止 `saveNow()` 覆写旧现场。
    func beginInitialRestore() {
        isInitialRestorePending = true
    }

    // MARK: - 保存

    /// 节流保存：状态抖动时不频繁写库。
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        guard !isInitialRestorePending else { return }
        let queue = engine.queue
        let identity = engine.currentTrack?.identity
        let position = positionToPersist(for: identity)

        let context = ModelContext(persistence.container)
        upsertQueue(queue, in: context)
        upsertState(identity: identity, position: position, in: context)
        try? context.save()
        persistQueueTracks(queue)
    }

    /// 该存哪个位置：进度已经生效就用引擎的，否则用"待恢复"的那一份。
    private func positionToPersist(for identity: TrackIdentity?) -> TimeInterval {
        guard let pending = pendingPosition else { return engine.currentPosition }
        guard pending.identity == identity else {
            // 换歌了：那份待恢复的进度作废。
            pendingPosition = nil
            return engine.currentPosition
        }
        switch engine.state {
        case .ready, .playing, .paused, .buffering, .seeking, .ended:
            // 装载好了。位置已经跳过去（或者用户自己动过）就认引擎的。
            if engine.currentPosition > 0.5 || engine.state.isPlaying {
                pendingPosition = nil
                return engine.currentPosition
            }
            return pending.position
        case .idle, .preparing, .failed:
            return pending.position
        }
    }

    /// 把队列里出现的曲目都落库。
    ///
    /// 队列与收藏只存**身份**，要靠曲目库把身份还原成"歌名 / 歌手 / 封面"。
    /// 以前只有"正在播的那一首"会被存：点一次「播放全部」排了 23 首、听了 2 首就退出，
    /// 重启后队列只剩 2 首——另外 21 首在库里根本查不到。
    private func persistQueueTracks(_ queue: PlaybackQueue) {
        var pending: [Track] = []
        for id in queue.items + queue.nextUp + queue.later {
            guard let track = engine.track(for: id) else { continue }
            let key = Self.key(track.identity) + "|" + track.title
            guard persistedTrackKeys.insert(key).inserted else { continue }
            pending.append(track)
        }
        guard !pending.isEmpty else { return }
        let repository = tracks
        let previous = trackSaveTask
        // 真正的写库放在一条专用阻塞线程上跑，而不是 Task：
        // `applicationWillTerminate` 一返回进程就可能被杀，Task 的调度本身都可能
        // 来不及发生；线程一启动就在跑，`done` 条件量能真的等到它落盘。
        // 不用 semaphore：架构守卫按裸 GCD 队列字面量扫文件，semaphore 的名字会撞线。
        // 同步原语封装在一个自管状态的盒子里：async 上下文里不能 lock/unlock，
        // 所有等/放都收进它自己的线程。
        let sync = SaveSync()
        let batch = pending
        Thread.detachNewThread {
            sync.waitGate()
            // 等的是"前一个批次的落盘完成"，不是它的 Task 包装——退出路径上
            // trackSaveTask 可能已经死了，等它会永远卡住。
            Task {
                try? await repository.save(contentsOf: batch)
                sync.signalDone()
            }
        }
        trackSaveTask = Task {
            // 排队写：两批并发落库没有意义，顺序也更好推理。
            await previous?.value
            sync.openGate()
            await sync.awaitDone()
        }
        pendingSaveGates.removeAll(where: \.isDone)
        pendingSaveGates.append(sync)
    }

    /// 尚未落盘完成的同步盒子队列（按投递顺序，退出路径上按序等待落库）。
    private var pendingSaveGates: [SaveSync] = []

    /// 同步等待已排队的曲目落库（仅退出路径用）。
    ///
    /// `applicationWillTerminate` 返回后进程就可能被杀，`trackSaveTask` 那层
    /// async/await 包装大概率跑不完——但真正的写库只需要按投递顺序给每个 `gate`
    /// 放行并限时等 `done`，既不并发写库也不会漏掉早期批次。超过 5 秒放弃等待直接退出。
    func waitForPendingTrackSaves() {
        let pending = pendingSaveGates
        pendingSaveGates.removeAll()
        guard !pending.isEmpty else { return }
        let deadline = Date().addingTimeInterval(5)
        for sync in pending {
            sync.openGate()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            sync.waitDone(timeout: remaining)
        }
    }

    /// 等曲目落库完成（退出前、测试里用）。
    func flushTracks() async { await trackSaveTask?.value }

    /// 队列的快照格式（写进 `QueueRecord.payload`）。
    ///
    /// 为什么包一层：`payload` 里原来只存 `PlaybackQueue`，而它的条目是 `Track.ID` ——
    /// **本地主键**，同一首歌每次从列表里点出来都是一个新值。重启时按它对不上曲目库，
    /// 所以额外记一份 `Track.ID → 稳定身份` 的映射。
    ///
    /// 刻意**不加 SwiftData 字段**：给模型加属性会让已存在的库无法自动迁移
    /// （实测 `Cannot use staged migration with an unknown model version`，整库打不开）。
    /// 塞进 payload 则完全向后兼容——旧数据仍能按老格式解出来。
    private struct PersistedQueue: Codable {
        var queue: PlaybackQueue
        /// 与 `queue.items` 同序；空串表示那一首当时没拿到身份。（旧格式，保留以便降级读取）
        var identities: [String]
        var currentIdentity: String?
        /// 队列里**每一个** ID（含"下一首/稍后"）对应的身份。新格式；旧数据里没有。
        var identityByID: [String: String]?
    }

    private func upsertQueue(_ queue: PlaybackQueue, in context: ModelContext) {
        let identities: [String] = queue.items.map { id in
            guard let track = engine.track(for: id) else { return "" }
            return Self.key(track.identity)
        }
        let currentKey: String? = queue.currentID
            .flatMap { engine.track(for: $0) }
            .map { Self.key($0.identity) }
        var identityByID: [String: String] = [:]
        for id in queue.items + queue.nextUp + queue.later + [queue.currentID].compactMap({ $0 }) {
            guard let track = engine.track(for: id) else { continue }
            identityByID[id.uuidString] = Self.key(track.identity)
        }
        let snapshot = PersistedQueue(queue: queue, identities: identities,
                                      currentIdentity: currentKey, identityByID: identityByID)
        // 编码失败时**不要**写空数据：那会把上一次的好快照覆盖掉，
        // 下次启动就成了"队列凭空消失"。宁可这轮不更新。
        guard let payload = (try? JSONEncoder().encode(snapshot))
                ?? (try? JSONEncoder().encode(queue)) else {
            RedactingLog.error("queue snapshot encode failed, keeping previous payload")
            return
        }

        var descriptor = FetchDescriptor<QueueRecord>(predicate: #Predicate { $0.slot == "main" })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.payload = payload
            existing.updatedAt = .now
        } else {
            context.insert(QueueRecord(slot: "main", payload: payload))
        }
    }

    private struct DecodedQueue {
        var queue: PlaybackQueue
        var identities: [String]?
        var currentIdentity: String?
        var identityByID: [String: String]?
    }

    /// 从 payload 里读出队列与身份；旧格式（只有 `PlaybackQueue`）没有身份表。
    private static func decodeQueue(_ data: Data) -> DecodedQueue {
        if let snapshot = try? JSONDecoder().decode(PersistedQueue.self, from: data) {
            return DecodedQueue(queue: snapshot.queue, identities: snapshot.identities,
                                currentIdentity: snapshot.currentIdentity,
                                identityByID: snapshot.identityByID)
        }
        if let queue = try? JSONDecoder().decode(PlaybackQueue.self, from: data) {
            return DecodedQueue(queue: queue)
        }
        return DecodedQueue(queue: PlaybackQueue())
    }

    /// 身份键：与 `PlaybackStateRecord.trackIdentityKey` 同一套格式。
    static func key(_ identity: TrackIdentity) -> String {
        TrackIdentity.storageKey(identity)
    }

    /// 位置归一化。
    ///
    /// `AVPlayer.currentTime().seconds` 在不可用时会返回 `NaN`，
    /// 直接写进存储既没有意义，也可能让读取方拿到一个"永远大于 0 也不小于 0"的怪值。
    static func sanitizedPosition(_ position: TimeInterval) -> TimeInterval {
        guard position.isFinite, position > 0 else { return 0 }
        return position
    }

    private func upsertState(identity: TrackIdentity?, position: TimeInterval, in context: ModelContext) {
        let position = Self.sanitizedPosition(position)
        let key = identity.map(Self.key)
        var descriptor = FetchDescriptor<PlaybackStateRecord>(predicate: #Predicate { $0.slot == "main" })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.trackIdentityKey = key
            existing.position = position
            existing.updatedAt = .now
        } else {
            context.insert(PlaybackStateRecord(trackIdentityKey: key, position: position, pauseReason: "user"))
        }
    }

    // MARK: - 恢复

    @discardableResult
    func restore() async -> Bool {
        defer { isInitialRestorePending = false }
        let context = ModelContext(persistence.container)

        guard let queueRecord = (try? context.fetch(FetchDescriptor<QueueRecord>()))?.first else {
            return false
        }
        // 在任何 await 之前先读出播放位置快照，避免异步读库期间被并发状态改动覆盖。
        let stateRecord = (try? context.fetch(FetchDescriptor<PlaybackStateRecord>()))?.first
        let decoded = Self.decodeQueue(queueRecord.payload)
        let saved = decoded.queue

        let allTracks = (try? await tracks.all()) ?? []
        var byIdentity: [TrackIdentity: Track] = [:]
        for track in allTracks where byIdentity[track.identity] == nil { byIdentity[track.identity] = track }
        var byLocalID: [Track.ID: Track] = [:]
        for track in allTracks where byLocalID[track.id] == nil { byLocalID[track.id] = track }

        // 把保存下来的每个 ID 还原成曲目，**沿用保存时的 ID**：
        // 这样整份队列（顺序、"下一首/稍后"、随机进度）可以原样装回去，不需要逐项改写。
        var identityByID: [Track.ID: TrackIdentity] = [:]
        if let map = decoded.identityByID {
            for (rawID, key) in map {
                guard let id = UUID(uuidString: rawID), let identity = Self.identity(from: key) else { continue }
                identityByID[id] = identity
            }
        }
        // 位置对齐的那份身份表做补充（旧格式只有它；新格式里它也在，两份互为备份）。
        if let keys = decoded.identities {
            for (id, key) in zip(saved.items, keys) where identityByID[id] == nil {
                if let identity = Self.identity(from: key) { identityByID[id] = identity }
            }
        }

        var restored: [Track.ID: Track] = [:]
        for id in saved.items + saved.nextUp + saved.later + [saved.currentID].compactMap({ $0 }) {
            guard restored[id] == nil else { continue }
            if let identity = identityByID[id], let stored = byIdentity[identity] {
                restored[id] = stored.withID(id)
            } else if let stored = byLocalID[id] {
                // 旧数据：没有身份表，只能按本地主键碰运气。
                restored[id] = stored
            }
        }
        guard !restored.isEmpty else { return false }

        let currentIdentity = stateRecord?.trackIdentityKey.flatMap(Self.identity(from:))
            ?? decoded.currentIdentity.flatMap(Self.identity(from:))
        let orderedTracks = (saved.items + saved.nextUp + saved.later).compactMap { restored[$0] }
        let current = currentIdentity.flatMap { identity in orderedTracks.first { $0.identity == identity } }
            ?? saved.currentID.flatMap { restored[$0] }
            ?? orderedTracks.first
        guard let current else { return false }

        engine.restoreQueue(saved, tracks: Array(restored.values))
        // 这些曲目本来就是从库里读出来的，不必再写回去。
        for track in restored.values {
            persistedTrackKeys.insert(Self.key(track.identity) + "|" + track.title)
        }

        let position = Self.sanitizedPosition(stateRecord?.position ?? 0)
        if position > 0 { pendingPosition = (current.identity, position) }
        await engine.load(current, autoplay: false)
        if position > 0, engine.currentTrack?.identity == current.identity {
            await engine.seek(to: position)
        }
        return true
    }

    static func identity(from key: String) -> TrackIdentity? {
        TrackIdentity.fromStorageKey(key)
    }
}

/// `persistQueueTracks` 的同步原语。
///
/// 为什么单独封一个类型：`NSCondition` 的 `lock/unlock/wait/signal` 在 Swift async
/// 上下文里**不可用**（运行时禁止在协程里持锁），而这里需要让两条线程
/// （退出路径的终止线程、写库线程）与一条 Task 链三方握手。
/// 所有等/放都收在它自己的方法里——调用方拿到的只是"开门"/"等完成"两个意图，
/// 锁的生命周期完全由它自己管理。
private final class SaveSync: @unchecked Sendable {
    private let gate = NSCondition()
    private var gateOpen = false
    private let done = NSCondition()
    private var doneFlag = false

    var isDone: Bool {
        done.lock()
        defer { done.unlock() }
        return doneFlag
    }

    /// 放行写库线程（幂等：退出来不及等 `trackSaveTask` 时直接调）。
    func openGate() {
        gate.lock(); gateOpen = true; gate.signal(); gate.unlock()
    }

    /// 等 `trackSaveTask` 排到自己后再放行（Task 链里的正常路径）。
    func waitGate() {
        gate.lock(); while !gateOpen { gate.wait() }; gate.unlock()
    }

    /// 写库线程落盘完成（在写库线程上调）。
    func signalDone() {
        done.lock(); doneFlag = true; done.signal(); done.unlock()
    }

    /// 等写库完成，给 async 调用方用：内部起一条短线程阻塞，
    /// 这样 `await` 侧不持锁、不违反 async 上下文禁止 `wait()` 的规则。
    func awaitDone() async {
        await withCheckedContinuation { cont in
            Thread.detachNewThread {
                self.done.lock(); while !self.doneFlag { self.done.wait() }; self.done.unlock()
                cont.resume()
            }
        }
    }

    /// 同步等写库完成（退出路径用）。超时返回，不等死。
    func waitDone(timeout: TimeInterval) {
        done.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while !doneFlag, done.wait(until: deadline) {}
        done.unlock()
    }
}
