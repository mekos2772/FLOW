import Foundation

/// 副作用执行器。把状态机吐出的 effect 落成真实的 session 调用。
///
/// 它是播放内核里唯一知道"存在播放器"的地方，但连播放器类型都不知道——
/// session 是协议类型，模拟会话与真实音频会话在它眼里完全一样。
@MainActor
final class PlaybackCoordinator {
    private let registry: SourceRegistry
    private(set) var session: (any PlaybackSession)?
    private(set) var activeSource: (any PlaybackSourceProvider)?
    /// 此刻该有的输出音量（已含静音）。**每个新会话都要套一次**——
    /// 会话是按曲目新建的，自己并不知道用户把音量调到了多少。
    var targetVolume: Float = 1
    /// 装载代数。每次装载/释放都 +1，用来认出"已经没人要了"的在途装载。
    private var generation: UInt64 = 0

    /// 联网是否开启（可选）。关闭联网时源不注册，装载要报 `.networkDisabled`
    /// 而不是 `.sourceUnavailable`——前者告诉用户"去设置打开联网"，
    /// 后者只会被当成"暂时播不了"拿去 refetch 重试（必然再败）。
    var isNetworkEnabled: (() -> Bool)?

    /// FLOW Voice：AI 渲染会话工厂（可选）。
    /// 返回非 nil 时该曲目用 AI 翻唱产物起播；返回 nil 走原声路径。
    /// 实现方（VoicePlaybackDriver）内部已判定"开启 + 渲染缓存命中"，
    /// 这里不重复判断条件，直接信任返回值。
    /// 第二个参数是"这是不是预热"：预热出来的会话不能覆盖当前播放会话的追踪。
    var voiceSessionFactory: (@Sendable (Track, _ isPrewarm: Bool) async throws -> (any PlaybackSession)?)?
    /// FLOW Voice：返回当前曲目期望使用的音色渲染签名（`nil` 表示应播原曲），用于校验 `standby` 预热是否仍匹配。
    var voiceRoutingSignature: (@MainActor (Track) async -> String?)?
    private(set) var isPlayingVoiceAI = false

    /// 离线回退会话工厂：联网关闭（在线源未注册）时，仍允许从本地已缓存/离线保存音频直连构造会话。
    var offlineSessionFactory: (@Sendable (Track) async throws -> (any PlaybackSession)?)?
    /// 静默预热离线会话工厂（不提前触发"当前音质"等状态上报，晋升时通过 `onOfflineSessionPromoted` 补报）。
    var offlinePrewarmSessionFactory: (@Sendable (Track) async throws -> (any PlaybackSession)?)?
    var onOfflineSessionPromoted: (@MainActor (any PlaybackSession) -> Void)?

    private struct StandbySession {
        let trackID: Track.ID
        let sourceID: SourceID
        let isOffline: Bool
        let isVoiceAI: Bool
        let voiceSignature: String?
        let session: any PlaybackSession
    }

    private var standby: StandbySession?
    private var prewarmTask: Task<Void, Never>?
    private var prewarmingTrackID: Track.ID?
    private(set) var standbyHitCount = 0
    private(set) var lastLoadWasGaplessHit = false

    init(registry: SourceRegistry) {
        self.registry = registry
    }

    var activeSourceID: SourceID? { activeSource?.descriptor.id }
    var currentDuration: TimeInterval { session?.duration ?? 0 }
    var hasSession: Bool { session != nil }
    var prewarmedTrackID: Track.ID? { standby?.trackID }

    /// 交给源补全元信息（没有该能力时原样返回）。
    func resolve(_ track: Track) async -> Track? {
        guard let provider = registry.provider(for: track.sourceID) else { return nil }
        let resolved = await provider.resolve(track)
        // 只接受身份一致的解析结果：源不该在这里替换成别的曲目。
        guard let resolved, resolved.identity == track.identity else { return nil }
        return resolved.withID(track.id)
    }

    /// 后台预热下一首会话，使自然切歌或顺延下一首几乎零停顿。
    func prewarm(track: Track) {
        let source = registry.provider(for: track.sourceID)
        let offlineFactory: (@Sendable (Track) async throws -> (any PlaybackSession)?)?
        let isOffline: Bool
        let canFallbackPrewarm: Bool
        if let source {
            offlineFactory = nil
            isOffline = false
            canFallbackPrewarm = source.supportsGaplessPrewarm
        } else if let prewarmOffline = offlinePrewarmSessionFactory {
            offlineFactory = prewarmOffline
            isOffline = true
            canFallbackPrewarm = true
        } else {
            offlineFactory = nil
            isOffline = true
            canFallbackPrewarm = false
        }

        guard canFallbackPrewarm || voiceSessionFactory != nil else { return }

        if let ready = standby, ready.trackID == track.id, ready.isOffline == isOffline {
            return
        }
        if prewarmingTrackID == track.id {
            return
        }

        cancelPrewarm()
        prewarmingTrackID = track.id

        prewarmTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.prewarmingTrackID == track.id {
                    self.prewarmingTrackID = nil
                    self.prewarmTask = nil
                }
            }
            do {
                let expectedSig = await self.voiceRoutingSignature?(track)
                let candidate: any PlaybackSession
                var usedVoiceAI = false
                if let voiceFactory = self.voiceSessionFactory,
                   let voiceBuilt = try? await voiceFactory(track, true) {
                    candidate = voiceBuilt
                    usedVoiceAI = true
                } else if let source, canFallbackPrewarm {
                    candidate = try await source.makePrewarmSession(for: track)
                } else if let offlineFactory {
                    guard let built = try await offlineFactory(track) else { return }
                    candidate = built
                } else {
                    return
                }
                guard !Task.isCancelled, self.prewarmingTrackID == track.id else {
                    await candidate.invalidate()
                    return
                }
                try await candidate.prepare()
                guard !Task.isCancelled, self.prewarmingTrackID == track.id else {
                    await candidate.invalidate()
                    return
                }
                if let oldStandby = self.standby {
                    self.standby = nil
                    await oldStandby.session.invalidate()
                }
                self.standby = StandbySession(
                    trackID: track.id,
                    sourceID: track.sourceID,
                    isOffline: isOffline,
                    isVoiceAI: usedVoiceAI,
                    voiceSignature: usedVoiceAI ? expectedSig : nil,
                    session: candidate
                )
            } catch {
                // 预热失败保持安静，不阻断当前播放。
            }
        }
    }

    func cancelPrewarm() {
        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmingTrackID = nil
        if let stale = standby {
            standby = nil
            Task { await stale.session.invalidate() }
        }
    }

    /// 装载并准备一个曲目，返回真实时长。
    @discardableResult
    func beginLoading(track: Track,
                      startAt: TimeInterval,
                      preferGaplessTransition: Bool = false) async throws -> TimeInterval {
        let source = registry.provider(for: track.sourceID)
        generation &+= 1
        let token = generation

        // 若该曲目正在后台预热中，直接等它收尾，避免重复发一次取流请求。
        if standby?.trackID != track.id, prewarmingTrackID == track.id, let inFlightPrewarm = prewarmTask {
            await inFlightPrewarm.value
            guard token == generation, !Task.isCancelled else {
                throw CancellationError()
            }
        }

        // 命中已就绪的预热会话：跳过取流、跳过下载、跳过 prepare 等待，直接晋升切换。
        // 若 Voice 上下文（开/关或音色签名）已变更，拒绝复用过期预热会话。
        let expectedOffline = (source == nil)
        let expectedVoiceSignature = await voiceRoutingSignature?(track)
        let voiceMatches: (StandbySession) -> Bool = { ready in
            guard self.voiceRoutingSignature != nil else { return true }
            return ready.isVoiceAI == (expectedVoiceSignature != nil) && ready.voiceSignature == expectedVoiceSignature
        }
        if let ready = standby,
           ready.trackID == track.id,
           ready.sourceID == track.sourceID,
           ready.isOffline == expectedOffline,
           voiceMatches(ready) {
            standby = nil
            prewarmTask?.cancel()
            prewarmTask = nil
            prewarmingTrackID = nil
            activeSource = source

            if let old = session, old.id != ready.session.id {
                session = nil
                await old.invalidate()
                guard token == generation, !Task.isCancelled else {
                    await ready.session.invalidate()
                    throw CancellationError()
                }
            }
            session = ready.session
            isPlayingVoiceAI = ready.isVoiceAI
            await ready.session.setVolume(max(0, min(targetVolume, 1)))
            if preferGaplessTransition {
                await ready.session.markGaplessNext()
            }
            if let source, !ready.isVoiceAI {
                source.noteSessionPromoted(ready.session)
            } else if source == nil && !ready.isVoiceAI {
                onOfflineSessionPromoted?(ready.session)
            }
            if startAt > 0, ready.session.capabilities.canSeek {
                try await ready.session.seek(to: startAt)
            }
            standbyHitCount += 1
            lastLoadWasGaplessHit = true
            return ready.session.duration
        }

        cancelPrewarm()
        lastLoadWasGaplessHit = false

        // FLOW Voice：AI 翻唱产物优先于原声会话。命中时已渲染完成的本地文件，
        // 直接构造会话起播；未命中/未开启时工厂返回 nil，落到原声路径。
        // 工厂抛错不阻断播放——AI 失败要退回原声而不是让整首歌播不了。
        var voiceSession: (any PlaybackSession)?
        if let factory = voiceSessionFactory {
            voiceSession = try? await factory(track, false)
        }

        let offlineSession: (any PlaybackSession)?
        if source == nil && voiceSession == nil {
            offlineSession = try await offlineSessionFactory?(track)
            if offlineSession == nil {
                // 没注册到这个源且没有可用本地缓存或 AI 渲染：联网被关掉时明确报 networkDisabled，否则报 sourceUnavailable。
                throw isNetworkEnabled?() == false ? PlaybackError.networkDisabled : PlaybackError.sourceUnavailable
            }
        } else {
            offlineSession = nil
        }
        guard token == generation, !Task.isCancelled else {
            await voiceSession?.invalidate()
            await offlineSession?.invalidate()
            throw CancellationError()
        }

        let newSession: any PlaybackSession
        var resolvedActiveSource = source
        if let voiceSession {
            newSession = voiceSession
        } else if let offlineSession {
            newSession = offlineSession
        } else if let source {
            do {
                newSession = try await source.makeSession(for: track)
            } catch {
                // 在线源取流失败（如切回原曲时插件缺字段或接口抖动），若本地已有完整音频缓存，无缝兜底播放。
                if Self.shouldAttemptOfflineCacheFallback(for: error, mappedBy: source),
                   let cachedFallback = try? await offlineSessionFactory?(track) {
                    RedactingLog.info("playback online source failed, falling back to cached offline session")
                    newSession = cachedFallback
                    resolvedActiveSource = nil
                } else {
                    throw error
                }
            }
        } else {
            throw PlaybackError.sourceUnavailable
        }
        // `makeSession` 要联网取流、下载音频，可能要好几秒。期间用户很可能又点了别的歌
        // （或者直接停了）。旧实现不管三七二十一把这份迟到的会话装上去，
        // 顺手 `invalidate` 掉"当前会话"——而那正是用户后点的、正在响的那一首：
        // 界面还显示在播放，声音没了，也再不会有"播完"事件。
        guard token == generation, !Task.isCancelled else {
            await newSession.invalidate()
            throw CancellationError()
        }

        // 同一个会话对象被源复用时（`reusesSession`）不能把它自己作废掉。
        if let old = session, old.id != newSession.id {
            session = nil
            await old.invalidate()
            guard token == generation else {
                await newSession.invalidate()
                throw CancellationError()
            }
        }
        activeSource = resolvedActiveSource
        session = newSession
        isPlayingVoiceAI = (voiceSession != nil)
        // 先定音量再准备：否则第一声是按 100% 出来的。
        await newSession.setVolume(max(0, min(targetVolume, 1)))
        if preferGaplessTransition {
            await newSession.markGaplessNext()
        }

        guard token == generation else { throw CancellationError() }
        try Task.checkCancellation()
        try await newSession.prepare()
        guard token == generation else { throw CancellationError() }
        try Task.checkCancellation()
        if startAt > 0, newSession.capabilities.canSeek {
            try await newSession.seek(to: startAt)
            guard token == generation else { throw CancellationError() }
            try Task.checkCancellation()
        }
        return newSession.duration
    }

    func play() async {
        guard let session else { return }
        do {
            try await session.play()
        } catch is CancellationError {
            return
        } catch {
            // 播放错误通过会话事件通道回报，这里只兜底避免崩溃。
        }
    }

    func pause() async {
        await session?.pause()
    }

    func seek(to position: TimeInterval) async {
        guard let session, session.capabilities.canSeek else { return }
        do {
            try await session.seek(to: max(0, position))
        } catch {
            // seek 失败不致命：保持当前位置即可，不必打断播放。
        }
    }

    /// 把 `targetVolume` 套到当前会话上（没有会话时什么都不做，等新会话建立时再套）。
    func applyTargetVolume() async {
        await session?.setVolume(max(0, min(targetVolume, 1)))
    }

    func setRate(_ rate: Double) async {
        guard let session, session.capabilities.canSetRate else { return }
        await session.setRate(rate)
    }

    func teardown() async {
        // 代数先推进：还在路上的装载回来时会发现自己已经过期，不会再把会话装上。
        generation &+= 1
        isPlayingVoiceAI = false
        guard let current = session else { return }
        // 先摘再作废：`invalidate` 里有 `await`，期间不能让别人再拿到这份会话。
        session = nil
        await current.invalidate()
    }

    func map(_ error: any Error) -> PlaybackError {
        if let playbackError = error as? PlaybackError { return playbackError }
        if error is CancellationError { return .cancelled }
        return activeSource?.map(error) ?? .unknown(reason: String(describing: error))
    }

    private static func shouldAttemptOfflineCacheFallback(for error: any Error,
                                                          mappedBy source: any PlaybackSourceProvider) -> Bool {
        if error is CancellationError { return false }
        let mapped = (error as? PlaybackError) ?? source.map(error)
        switch mapped {
        case .cancelled, .networkDisabled, .rightsRestricted, .songNotVerified:
            return false
        case .sourceUnavailable, .networkUnavailable, .decodeFailed, .unsupportedFormat, .unknown:
            return true
        }
    }
}
