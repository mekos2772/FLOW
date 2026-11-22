import AVFoundation
import Foundation

/// 源无关的通用音频播放会话。
///
/// 统一承接 `AVPlayer` 生命周期、HTTP 206 流式代理（`ProgressiveAudioStream`）、
/// `MTAudioProcessingTap`（5 段 EQ + 响度自动平衡）、淡入淡出、Gapless 首拍豁免与缓存保护锁。
/// 所有可变状态严格在 `@MainActor` 上访问。
final class HTTPStreamPlayerSession: PlaybackSession, @unchecked Sendable {
    let id = UUID()
    private(set) var duration: TimeInterval = 0
    let capabilities: SessionCapabilities = .full
    let events: AsyncStream<SessionEvent>

    private let player = AVPlayer()
    private var item: AVPlayerItem?
    private var continuation: AsyncStream<SessionEvent>.Continuation?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var lastKnownPosition: TimeInterval = 0
    private var isInvalidated = false
    private var transportGeneration: UInt64 = 0

    let title: String
    let trackCacheKey: String?
    private(set) var stream: AudioStreamDescriptor

    private let fadeRunner = AudioFadeRunner()
    private var baseVolume: Float = 1
    private var localFileURL: URL?
    private var tapHandle: AudioTapHandle?
    private var mixTask: Task<Void, Never>?
    private var loudnessTask: Task<Void, Never>?
    private var activeStream: ProgressiveAudioStream?
    private var streamingAsset: StreamingPreparedAsset?
    private let streamingAssetBuilder: StreamingAssetBuilder?
    private let onEvictLocalURL: (@Sendable (URL) -> Void)?
    private var fallbackStreamTask: Task<Void, Never>?
    private var timeControlObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var isStreamingStalled = false
    private var skipNextFadeIn = false
    private var readyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    private var fadeDuration: TimeInterval {
        AudioFade.isEnabled ? 0.12 : 0
    }

    static func requireMainThread(_ function: StaticString = #function) {
        #if DEBUG
        MainActor.assumeIsolated { _ = function }
        #endif
    }

    static var isOnMainThread: Bool { Thread.isMainThread }

    #if DEBUG
    @MainActor var debugPlaybackPosition: TimeInterval { player.currentTime().seconds }
    #endif

    @MainActor
    convenience init(stream: AudioStreamDescriptor,
                     localURL: URL,
                     title: String,
                     cacheKey: String? = nil,
                     onEvictLocalURL: (@Sendable (URL) -> Void)? = nil) throws {
        try self.init(stream: stream,
                      media: .local(localURL),
                      title: title,
                      cacheKey: cacheKey,
                      streamingAssetBuilder: nil,
                      onEvictLocalURL: onEvictLocalURL)
    }

    @MainActor
    init(stream: AudioStreamDescriptor,
         media: MediaAudioCache.MediaSource,
         title: String,
         cacheKey: String? = nil,
         streamingAssetBuilder: StreamingAssetBuilder? = nil,
         onEvictLocalURL: (@Sendable (URL) -> Void)? = nil) throws {
        self.stream = stream
        self.title = title
        self.trackCacheKey = cacheKey ?? (stream.cacheKey.isEmpty ? nil : stream.cacheKey)
        self.streamingAssetBuilder = streamingAssetBuilder
        self.onEvictLocalURL = onEvictLocalURL
        var sink: AsyncStream<SessionEvent>.Continuation!
        self.events = AsyncStream { sink = $0 }
        self.continuation = sink
        load(stream, media: media, preserving: 0)
    }

    @MainActor
    private func load(_ stream: AudioStreamDescriptor,
                      media: MediaAudioCache.MediaSource,
                      preserving position: TimeInterval) {
        resolveReadyWaiters(error: CancellationError())
        fallbackStreamTask?.cancel()
        fallbackStreamTask = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil
        mixTask?.cancel()
        loudnessTask?.cancel()
        tapHandle?.detach()
        tapHandle = nil
        streamingAsset?.invalidate()
        streamingAsset = nil
        if let previousStream = activeStream {
            activeStream = nil
            previousStream.releaseConsumer()
        }
        if isStreamingStalled {
            isStreamingStalled = false
            continuation?.yield(.stalled(false))
        }

        let incomingLocalURL: URL? = if case let .local(url) = media { url } else { nil }
        if let previous = localFileURL, previous != incomingLocalURL { MediaAudioCache.unpin(previous) }
        self.stream = stream

        let asset: AVURLAsset
        let loudnessKey: String
        let targetMeasureURL: URL?
        let progressiveSource: ProgressiveAudioStream?

        switch media {
        case let .local(localURL):
            localFileURL = localURL
            MediaAudioCache.pin(localURL)
            asset = AVURLAsset(url: localURL)
            player.automaticallyWaitsToMinimizeStalling = false
            loudnessKey = trackCacheKey ?? localURL.lastPathComponent
            targetMeasureURL = localURL
            progressiveSource = nil

        case let .stream(progressive):
            localFileURL = nil
            activeStream = progressive
            guard let builder = streamingAssetBuilder else {
                player.automaticallyWaitsToMinimizeStalling = false
                fallbackStreamTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let completedURL = await progressive.waitForLocalFile(),
                          !Task.isCancelled, !self.isInvalidated else {
                        self.resolveReadyWaiters(error: PlaybackError.sourceUnavailable)
                        return
                    }
                    self.load(stream, media: .local(completedURL), preserving: position)
                }
                return
            }
            let prepared = builder(progressive)
            streamingAsset = prepared
            asset = prepared.asset
            player.automaticallyWaitsToMinimizeStalling = false
            loudnessKey = trackCacheKey ?? progressive.destinationURL.lastPathComponent
            targetMeasureURL = nil
            progressiveSource = progressive

        case let .hls(prepared):
            localFileURL = nil
            streamingAsset = prepared
            asset = prepared.asset
            player.automaticallyWaitsToMinimizeStalling = true
            loudnessKey = trackCacheKey ?? stream.url.absoluteString
            targetMeasureURL = nil
            progressiveSource = nil
        }

        let item = AVPlayerItem(asset: asset)
        if progressiveSource != nil {
            item.preferredForwardBufferDuration = 10
        }
        self.item = item

        mixTask = Task { @MainActor [weak self, weak item] in
            guard let self, let item, !Task.isCancelled else { return }
            let cached = await LoudnessCache.shared.cachedProfile(forKey: loudnessKey)
            guard !Task.isCancelled, !self.isInvalidated, self.item === item else { return }
            if let built = await AudioProcessingTap.buildAudioMix(
                for: asset,
                trackLoudnessGain: cached?.recommendedGain ?? 1.0
            ) {
                guard !Task.isCancelled, !self.isInvalidated, self.item === item else {
                    built.handle.detach()
                    return
                }
                item.audioMix = built.mix
                self.tapHandle = built.handle
            }
            if cached == nil {
                self.loudnessTask = Task { @MainActor [weak self, weak item] in
                    guard let self, let item, !Task.isCancelled else { return }
                    let measureURL: URL?
                    if let targetMeasureURL {
                        measureURL = targetMeasureURL
                    } else if let progressiveSource {
                        measureURL = await progressiveSource.waitForLocalFile()
                        guard !Task.isCancelled, !self.isInvalidated, self.item === item else { return }
                        if self.isStreamingStalled {
                            self.isStreamingStalled = false
                            self.continuation?.yield(.stalled(false))
                        }
                        if let completed = measureURL {
                            self.localFileURL = completed
                            MediaAudioCache.pin(completed)
                        }
                    } else {
                        measureURL = nil
                    }
                    guard let measureURL,
                          let measured = await LoudnessCache.shared.measureIfNeeded(key: loudnessKey, url: measureURL) else {
                        return
                    }
                    guard !Task.isCancelled, !self.isInvalidated, self.item === item else { return }
                    self.tapHandle?.setTrackLoudnessGain(measured.recommendedGain)
                }
            }
        }
        player.replaceCurrentItem(with: item)
        if position > 0 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }

        if let progressiveSource {
            let evaluateStall: @MainActor () -> Void = { [weak self, weak item, weak progressiveSource] in
                guard let self, let item, let progressiveSource,
                      !self.isInvalidated, self.item === item,
                      self.activeStream === progressiveSource else { return }
                guard !progressiveSource.isCompleted else {
                    if self.isStreamingStalled {
                        self.isStreamingStalled = false
                        self.continuation?.yield(.stalled(false))
                    }
                    return
                }
                let waitingForData = (item.isPlaybackBufferEmpty && self.player.rate > 0)
                    || (self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                        && self.player.reasonForWaitingToPlay == .toMinimizeStalls)
                if waitingForData {
                    if !self.isStreamingStalled {
                        self.isStreamingStalled = true
                        self.continuation?.yield(.stalled(true))
                    }
                } else if self.player.timeControlStatus == .playing || item.isPlaybackLikelyToKeepUp {
                    if self.isStreamingStalled {
                        self.isStreamingStalled = false
                        self.continuation?.yield(.stalled(false))
                    }
                }
            }
            timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { _, _ in
                Task { @MainActor in evaluateStall() }
            }
            bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { _, _ in
                Task { @MainActor in evaluateStall() }
            }
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isInvalidated, self.item === item else { return }
                switch item.status {
                case .readyToPlay:
                    let seconds = item.duration.seconds
                    if seconds.isFinite, seconds > 0 {
                        self.duration = seconds
                        self.resolveReadyWaiters(error: nil)
                        self.continuation?.yield(.prepared(duration: seconds))
                    } else {
                        self.duration = 0
                        self.resolveReadyWaiters(error: nil)
                        self.continuation?.yield(.prepared(duration: 0))
                    }
                    if position > 0, !self.isInvalidated, self.item === item {
                        let current = self.player.currentTime().seconds
                        if !current.isFinite || abs(current - position) > 1 {
                            try? await self.seek(to: position)
                        }
                    }
                case .failed:
                    let err = PlaybackError.decodeFailed(
                        reason: item.error?.localizedDescription ?? "音频装载失败"
                    )
                    self.resolveReadyWaiters(error: err)
                    self.continuation?.yield(.failed(err))
                default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.continuation?.yield(.ended) }
        }
    }

    @MainActor
    func refresh(with stream: AudioStreamDescriptor, localURL: URL) async throws {
        try await refresh(with: stream, media: .local(localURL))
    }

    @MainActor
    func refresh(with stream: AudioStreamDescriptor, media: MediaAudioCache.MediaSource) async throws {
        Self.requireMainThread()
        guard !isInvalidated else { return }
        let position = player.currentTime().seconds
        let resume = position.isFinite ? position : lastKnownPosition
        let wasPlaying = player.rate != 0
        load(stream, media: media, preserving: resume)
        if wasPlaying { player.play() }
    }

    @MainActor
    func prepare() async throws {
        Self.requireMainThread()
        try Task.checkCancellation()
        await mixTask?.value
        try Task.checkCancellation()
        if item?.status == .readyToPlay {
            syncDurationFromItem()
            return
        }
        if item?.status == .failed {
            evictFailedLocalCacheIfNeeded()
            throw PlaybackError.decodeFailed(reason: item?.error?.localizedDescription ?? "音频装载失败")
        }

        let timeoutSeconds: Double = activeStream != nil ? 15 : 5
        do {
            try await awaitItemReady(timeoutSeconds: timeoutSeconds)
            syncDurationFromItem()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            evictFailedLocalCacheIfNeeded()
            throw error
        }
    }

    private func evictFailedLocalCacheIfNeeded() {
        guard let cached = localFileURL else { return }
        if let onEvictLocalURL {
            onEvictLocalURL(cached)
        } else if let key = trackCacheKey {
            MediaAudioCache.shared.evictIfCached(cacheKey: key, url: cached)
        }
    }

    @MainActor
    private func awaitItemReady(timeoutSeconds: Double) async throws {
        let waiterID = UUID()
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            self?.finishReadyWaiter(id: waiterID, result: .failure(PlaybackError.decodeFailed(reason: "音频装载超时")))
        }
        defer { timeoutTask.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if item?.status == .readyToPlay {
                    continuation.resume(returning: ())
                    return
                }
                if item?.status == .failed {
                    continuation.resume(throwing: PlaybackError.decodeFailed(
                        reason: item?.error?.localizedDescription ?? "音频装载失败"
                    ))
                    return
                }
                readyWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishReadyWaiter(id: waiterID, result: .failure(CancellationError()))
            }
        }
    }

    @MainActor
    private func finishReadyWaiter(id: UUID, result: Result<Void, Error>) {
        guard let continuation = readyWaiters.removeValue(forKey: id) else { return }
        switch result {
        case .success: continuation.resume()
        case let .failure(error): continuation.resume(throwing: error)
        }
    }

    @MainActor
    private func resolveReadyWaiters(error: (any Error)?) {
        let keys = Array(readyWaiters.keys)
        for key in keys {
            if let error {
                finishReadyWaiter(id: key, result: .failure(error))
            } else {
                finishReadyWaiter(id: key, result: .success(()))
            }
        }
    }

    private func syncDurationFromItem() {
        guard let item else { return }
        let seconds = item.duration.seconds
        if seconds.isFinite, seconds > 0, duration != seconds {
            duration = seconds
        }
    }

    @MainActor
    func markGaplessNext() async {
        Self.requireMainThread()
        skipNextFadeIn = true
    }

    @MainActor
    func play() async throws {
        Self.requireMainThread()
        guard !isInvalidated else { return }
        transportGeneration &+= 1
        let skipFade = skipNextFadeIn
        skipNextFadeIn = false
        let effectiveFade = skipFade ? 0 : fadeDuration
        if effectiveFade <= 0 {
            await fadeRunner.cancel()
            player.volume = baseVolume
            player.play()
            return
        }
        player.volume = 0
        player.play()
        await fadeRunner.run(kind: .fadeIn, duration: effectiveFade, target: baseVolume) { [weak player] value in
            player?.volume = value
        }
    }

    @MainActor
    func pause() async {
        Self.requireMainThread()
        guard !isInvalidated else { return }
        transportGeneration &+= 1
        let generation = transportGeneration
        lastKnownPosition = player.currentTime().seconds
        await fadeRunner.run(kind: .fadeOut, duration: fadeDuration, target: baseVolume) { [weak player] value in
            player?.volume = value
        }
        guard generation == transportGeneration, !isInvalidated else { return }
        player.pause()
        player.volume = baseVolume
    }

    @MainActor
    func seek(to position: TimeInterval) async throws {
        Self.requireMainThread()
        guard !isInvalidated else { return }
        let target = CMTime(seconds: max(0, position), preferredTimescale: 600)
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @MainActor
    func setRate(_ rate: Double) async {
        Self.requireMainThread()
        guard !isInvalidated else { return }
        player.rate = Float(rate)
        continuation?.yield(.rateChanged(rate))
    }

    @MainActor
    func setVolume(_ volume: Float) async {
        Self.requireMainThread()
        baseVolume = max(0, min(1, volume))
        await fadeRunner.setBaseVolume(baseVolume)
        if await fadeRunner.isFading == false {
            player.volume = baseVolume
        }
    }

    @MainActor
    func invalidate() async {
        Self.requireMainThread()
        guard !isInvalidated else { return }
        isInvalidated = true
        transportGeneration &+= 1
        resolveReadyWaiters(error: CancellationError())
        fallbackStreamTask?.cancel()
        fallbackStreamTask = nil
        mixTask?.cancel()
        loudnessTask?.cancel()
        tapHandle?.detach()
        tapHandle = nil
        streamingAsset?.invalidate()
        streamingAsset = nil
        if let activeStream {
            self.activeStream = nil
            activeStream.releaseConsumer()
        }
        if let localFileURL { MediaAudioCache.unpin(localFileURL) }
        await fadeRunner.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation?.invalidate()
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        continuation?.finish()
    }
}
