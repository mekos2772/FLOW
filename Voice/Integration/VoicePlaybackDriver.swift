import Foundation

/// 把已渲染的 FLOW Voice 产物接进 PlaybackCoordinator（cache hit 直接播 AI 音频，cache miss 返回 nil 退回原曲）。
/// 切歌/起播只刷新已有成品的命中状态；转换一律由用户显式发起，搜索或切歌绝不在后台自动生成。
@MainActor
final class VoicePlaybackDriver {
    private let voice: VoiceManager
    private let inputResolver: @MainActor (Track) async -> URL?
    private weak var observedPlayback: (any PlaybackControlling)?
    private var stateObservationTask: Task<Void, Never>?
    private var lastHandledTrackKey: String?
    /// 当前播放会话追踪到的曲目与成品键。`private(set)` 是为了让测试能直接断言
    /// "预热下一首不会覆盖正在播的那首"。
    private(set) var lastLoadedTrackKey: String?
    private(set) var lastLoadedRenderKey: String?
    private var lastLoadedRenderURL: URL?
    /// 预热出来的下一首成品。它被直接提升成当前会话时不会再走工厂，
    /// 所以单独记一份，切歌时再补进 `lastLoaded*`（否则删成品后退回原曲会失效）。
    private var standbyRender: (trackKey: String, cacheKey: String, url: URL)?
    private var isReloadingTrack = false
    private var pendingExplicitAutoplayTrackKey: String?

    var onRenderReady: (@MainActor (Track, VoiceRender) -> Void)?

    init(voice: VoiceManager, inputResolver: @escaping @MainActor (Track) async -> URL?) {
        self.voice = voice
        self.inputResolver = inputResolver
    }

    /// 监听播放状态变化：切歌时刷新磁盘已渲染缓存命中（不入队任何转换）。
    func startObserving(playback: any PlaybackControlling) {
        observedPlayback = playback
        stateObservationTask?.cancel()
        stateObservationTask = Task { [weak self, weak playback] in
            guard let playback else { return }
            for await state in playback.stateUpdates() {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.handlePlaybackStateChange(state: state, track: playback.currentTrack)
            }
        }
    }

    func stopObserving() {
        stateObservationTask?.cancel()
        stateObservationTask = nil
    }

    func handlePlaybackStateChange(state: PlaybackState, track: Track?) async {
        guard Self.isActive(state), let track else { return }
        let trackKey = TrackIdentity.storageKey(track.identity)
        guard trackKey != lastHandledTrackKey else { return }
        lastHandledTrackKey = trackKey
        // 预热接力：standby 被直接提升成当前会话时不会再走工厂，这里把追踪补上。
        if let standby = standbyRender, standby.trackKey == trackKey, lastLoadedTrackKey != trackKey {
            lastLoadedTrackKey = standby.trackKey
            lastLoadedRenderKey = standby.cacheKey
            lastLoadedRenderURL = standby.url
        }
        await voice.refreshRenderAvailability(for: track)
    }

    /// 流媒体完整落盘后补查一次：原曲文件到位才能精确匹配已有成品（只查不生成）。
    func handleAudioCachedOnCurrentTrack() async {
        guard let track = observedPlayback?.currentTrack else { return }
        await voice.refreshRenderAvailability(for: track)
    }

    /// 返回当前曲目应走的 AI 渲染唯一签名；`nil` 表示当前应播放原曲。
    func activeRoutingSignature(for track: Track) async -> String? {
        guard voice.canRouteToVoice(track) else { return nil }
        return (await voice.resolvePlayableRender(for: track))?.cacheKey
    }

    /// 离线页点播 AI 翻唱：整首装载；装载期间挡住开关变化触发的对齐，避免同一首被重复装载。
    func startTrack(_ track: Track, playback: any PlaybackControlling) async {
        let wasReloading = isReloadingTrack
        isReloadingTrack = true
        defer { isReloadingTrack = wasReloading }
        await playback.load(track, autoplay: true)
    }

    /// 当开关、音色版本或后台渲染完成导致上下文变化时，平稳把当前播放会话与目标版本对齐（避免拖滑杆期间无谓断音）。
    func reconcileActiveTrackRouting(playback: any PlaybackControlling, coordinator: PlaybackCoordinator) async {
        guard !isReloadingTrack,
              let track = playback.currentTrack,
              playback.state != .idle else {
            return
        }
        isReloadingTrack = true
        defer { isReloadingTrack = false }

        let trackKey = TrackIdentity.storageKey(track.identity)
        let desiredSig = await activeRoutingSignature(for: track)
        let currentlyVoice = coordinator.isPlayingVoiceAI
        let currentSig: String? = (currentlyVoice && lastLoadedTrackKey == trackKey) ? lastLoadedRenderKey : (currentlyVoice ? "__voice__" : nil)

        // 正在播的成品文件被删掉（离线页删除/清空缓存）也要退回原曲；仅仅调参导致不匹配则继续播，避免拖滑杆时断音。
        let currentRenderGone = currentlyVoice
            && lastLoadedTrackKey == trackKey
            && lastLoadedRenderURL.map { !FileManager.default.fileExists(atPath: $0.path) } == true
        let shouldReloadToVoice = (desiredSig != nil && desiredSig != currentSig)
        let shouldReloadToOriginal = currentlyVoice && desiredSig == nil
            && (!voice.isEnabled || !voice.baseModelsReady || currentRenderGone)
        guard shouldReloadToVoice || shouldReloadToOriginal else {
            let deferredAutoplay = pendingExplicitAutoplayTrackKey == trackKey
                || voice.consumePendingAutoplay(for: trackKey)
            if deferredAutoplay {
                pendingExplicitAutoplayTrackKey = nil
                if !playback.state.isPlaying {
                    await playback.play()
                }
            }
            return
        }

        // 「生成并播放 AI 版」在没命中缓存时把意图交给了 VoiceManager，这里一起消费。
        let honorPendingAutoplay = pendingExplicitAutoplayTrackKey == trackKey
            || voice.consumePendingAutoplay(for: trackKey)
        if honorPendingAutoplay {
            pendingExplicitAutoplayTrackKey = nil
        }
        RedactingLog.info("voice reconcile reload enabled=\(voice.isEnabled) baseReady=\(voice.baseModelsReady) currentlyVoice=\(currentlyVoice) toVoice=\(shouldReloadToVoice) autoplay=\(honorPendingAutoplay)")
        await playback.reloadAudioSource(autoplayIfInactive: honorPendingAutoplay)
    }

    /// 显式切换原曲 / AI 版并确保起播（用于播控按钮直接点击）。
    func playRequestedVersion(of track: Track, playback: any PlaybackControlling, coordinator: PlaybackCoordinator, autoplay: Bool) async {
        let trackKey = TrackIdentity.storageKey(track.identity)
        if isReloadingTrack {
            if autoplay {
                pendingExplicitAutoplayTrackKey = trackKey
            }
            RedactingLog.info("voice play requested deferred while reload in progress autoplay=\(autoplay)")
            return
        }
        isReloadingTrack = true
        defer { isReloadingTrack = false }

        if playback.currentTrack?.identity != track.identity || playback.state == .idle {
            RedactingLog.info("voice play requested load idle/other autoplay=\(autoplay)")
            await playback.load(track, autoplay: autoplay)
            return
        }
        let desiredSig = await activeRoutingSignature(for: track)
        let currentlyVoice = coordinator.isPlayingVoiceAI
        let currentSig: String? = (currentlyVoice && lastLoadedTrackKey == trackKey) ? lastLoadedRenderKey : (currentlyVoice ? "__voice__" : nil)

        RedactingLog.info("voice play requested currentlyVoice=\(currentlyVoice) sameSig=\(currentSig == desiredSig) desiredVoice=\(desiredSig != nil) autoplay=\(autoplay)")
        if currentSig != desiredSig {
            await playback.reloadAudioSource(autoplayIfInactive: autoplay)
        } else if case .failed = playback.state, autoplay {
            await playback.load(track, autoplay: true)
        } else if autoplay, !playback.state.isPlaying {
            await playback.play()
        }
    }

    private static func isActive(_ state: PlaybackState) -> Bool {
        switch state {
        case .preparing, .ready, .playing:
            return true
        default:
            return false
        }
    }

    /// 缓存命中当前音色包+版本+参数组合（或原声缓存失效时同音色同版本最新成品）时返回本地播放会话，
    /// 未命中或开关/底座未就绪返回 nil 交由正常播放器加载。
    ///
    /// `isPrewarm` 区分"真的要播"和"提前备好下一首"：预热不能覆盖当前会话的追踪，
    /// 否则正在播的那首删掉成品后识别不出"文件没了"，也就不会退回原曲。
    func makeSessionIfAvailable(for track: Track, isPrewarm: Bool = false) async throws -> (any PlaybackSession)? {
        let trackKey = TrackIdentity.storageKey(track.identity)
        guard voice.canRouteToVoice(track),
              let render = await voice.resolvePlayableRender(for: track, inputResolver: inputResolver),
              FileManager.default.fileExists(atPath: render.fileURL.path) else {
            // 只清这首歌自己的追踪：预热下一首时不能把正在播的那首抹掉。
            if lastLoadedTrackKey == trackKey {
                lastLoadedTrackKey = nil
                lastLoadedRenderKey = nil
                lastLoadedRenderURL = nil
            }
            if standbyRender?.trackKey == trackKey {
                standbyRender = nil
            }
            return nil
        }
        if isPrewarm {
            standbyRender = (trackKey, render.cacheKey, render.fileURL)
        } else {
            lastLoadedTrackKey = trackKey
            lastLoadedRenderKey = render.cacheKey
            lastLoadedRenderURL = render.fileURL
        }
        onRenderReady?(track, render)
        RedactingLog.info("voice session hit pack=\(render.packID) sr=\(render.sampleRate) ext=\(render.fileURL.pathExtension) prewarm=\(isPrewarm)")
        return try buildSession(from: render, for: track)
    }

    private func buildSession(from render: VoiceRender, for track: Track) throws -> any PlaybackSession {
        let ext = render.fileURL.pathExtension.lowercased()
        let lossless: Set<String> = ["flac", "wav", "aiff", "aif", "alac", "caf"]
        let isLossless = lossless.contains(ext)
        let resolvedExt = ext.isEmpty ? "m4a" : ext
        let stream = AudioStreamDescriptor(
            cacheKey: "\(render.cacheKey)#voice",
            fileExtension: resolvedExt,
            qualityTier: isLossless ? .lossless : .high,
            qualityID: 0,
            codec: isLossless ? resolvedExt.uppercased() : "AAC",
            bandwidth: 256_000,
            sampleRate: render.sampleRate,
            isLossless: isLossless,
            url: render.fileURL
        )
        return try HTTPStreamPlayerSession(stream: stream, localURL: render.fileURL, title: track.title)
    }
}
