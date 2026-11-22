import Foundation

/// 由虚拟时钟驱动的无声音会话。
///
/// 不发声、不读文件、不占 CPU：只维护一段"虚拟进度"，并在越过 duration 时发 `.ended`。
/// `failurePlan` 在这里兑现，用于验证播放内核的重试与降级路径。
actor MockPlaybackSession: PlaybackSession {
    nonisolated let id = UUID()
    nonisolated let duration: TimeInterval
    nonisolated let capabilities: SessionCapabilities
    nonisolated let events: AsyncStream<SessionEvent>

    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let behavior: MockBehavior
    private let clock: any PlaybackClock

    /// 第几次会话创建（从 1 开始）。故障注入按这个序号命中，跨 session 有效。
    private let attemptNumber: Int
    private var accumulated: TimeInterval = 0
    private var lastResumeAt: Instant?
    private var rate: Double = 1
    private var ticker: Task<Void, Never>?
    private var isFinished = false
    private var currentVolume: Float = 1

    init(duration: TimeInterval,
         behavior: MockBehavior = .healthy,
         clock: any PlaybackClock = SystemPlaybackClock(),
         attemptNumber: Int = 1) {
        self.duration = duration
        self.attemptNumber = attemptNumber
        self.behavior = behavior
        self.clock = clock
        self.capabilities = SessionCapabilities(
            canSeek: behavior.supportsSeek,
            canSetRate: behavior.supportsRate,
            canSkip: true
        )
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    func prepare() async throws {
        try Task.checkCancellation()

        if let error = behavior.alwaysFailWith {
            throw error
        }
        if let error = behavior.failurePlan[attemptNumber] {
            throw error
        }

        try await clock.sleep(for: behavior.prepareLatency)
        try Task.checkCancellation()
        continuation.yield(.prepared(duration: duration))
    }

    func play() async throws {
        guard !isFinished else { return }
        try Task.checkCancellation()
        lastResumeAt = clock.now
        startTickerIfNeeded()
    }

    func pause() async {
        if let resumeAt = lastResumeAt {
            accumulated += (clock.now - resumeAt).timeInterval * rate
            lastResumeAt = nil
        }
        ticker?.cancel()
        ticker = nil
    }

    func seek(to position: TimeInterval) async throws {
        guard capabilities.canSeek else { throw PlaybackError.unsupportedFormat(.other) }
        accumulated = min(max(0, position), duration)
        if lastResumeAt != nil { lastResumeAt = clock.now }
    }

    func setVolume(_ volume: Float) async {
        currentVolume = max(0, min(volume, 1))
    }


    func setRate(_ newRate: Double) async {
        let clamped = max(0.25, min(newRate, 4))
        if let resumeAt = lastResumeAt {
            accumulated += (clock.now - resumeAt).timeInterval * rate
            lastResumeAt = clock.now
        }
        rate = clamped
        continuation.yield(.rateChanged(clamped))
    }

    func invalidate() async {
        ticker?.cancel()
        ticker = nil
        lastResumeAt = nil
        continuation.finish()
    }

    /// 当前虚拟进度（测试断言用）。
    func currentPosition() -> TimeInterval {
        guard let resumeAt = lastResumeAt else { return accumulated }
        return accumulated + (clock.now - resumeAt).timeInterval * rate
    }

    /// 测试中强制走到结尾，免去真实等待。
    func forceEnd() async {
        isFinished = true
        lastResumeAt = nil
        continuation.yield(.ended)
    }

    private func startTickerIfNeeded() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                if await self.tick() { return }
            }
        }
    }

    /// 返回 true 表示已结束，ticker 应停止。
    private func tick() -> Bool {
        guard !isFinished, lastResumeAt != nil else { return true }
        if currentPosition() >= duration {
            isFinished = true
            lastResumeAt = nil
            continuation.yield(.ended)
            return true
        }
        return false
    }
}
