import Foundation

/// 源无关的网络连通性观察器（由真实播放报错/成功驱动推断）。
@MainActor
final class NetworkConnectivityMonitor {
    private(set) var isOnline = true

    func noteSuccess() { isOnline = true }

    func noteFailure(_ error: PlaybackError) {
        if case .networkUnavailable = error {
            isOnline = false
        }
    }
}

/// 源无关的自动播放失败恢复策略与驱动器。
enum PlaybackRecoveryPolicy {
    enum Action: Equatable, Sendable {
        case refetch
        case wait(seconds: Double)
        case waitForNetwork
        case giveUp
    }

    static let maxNetworkProbes = 60

    static func decide(attempt: Int, isOnline: Bool, error: PlaybackError) -> Action {
        if error == .networkDisabled || error == .songNotVerified { return .giveUp }
        if !isOnline { return .waitForNetwork }
        guard attempt < 3 else { return .giveUp }
        switch error {
        case .sourceUnavailable, .decodeFailed, .unknown:
            return attempt == 0 ? .refetch : .wait(seconds: backoff(attempt))
        case .networkUnavailable:
            return .waitForNetwork
        case .networkDisabled, .rightsRestricted, .unsupportedFormat, .cancelled, .songNotVerified:
            return .giveUp
        }
    }

    static func backoff(_ attempt: Int) -> Double {
        min(5, 0.8 * pow(2, Double(attempt)))
    }
}

@MainActor
final class PlaybackRecoveryDriver {
    private let playback: any PlaybackControlling
    private let network: NetworkConnectivityMonitor
    private let clock: any PlaybackClock
    private let onEvictCache: @Sendable (Track) async -> Void
    private var task: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private var recoveryToken = UUID()
    private var recoveringIdentity: TrackIdentity?
    private var resumePosition: TimeInterval = 0
    private var attempt = 0
    private var networkProbes = 0
    private(set) var lastAction: String?

    init(playback: any PlaybackControlling,
         network: NetworkConnectivityMonitor,
         clock: any PlaybackClock = SystemPlaybackClock(),
         onEvictCache: (@Sendable (Track) async -> Void)? = nil) {
        self.playback = playback
        self.network = network
        self.clock = clock
        self.onEvictCache = onEvictCache ?? { track in
            await MediaAudioCache.shared.evict(cacheKey: TrackIdentity.storageKey(track.identity))
            await MediaAudioCache.shared.evict(cacheKey: track.externalID)
        }
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            for await _ in self.playback.stateUpdates() {
                if Task.isCancelled { return }
                self.handleStateChange()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        recoveryToken = UUID()
        recovery?.cancel()
        recovery = nil
    }

    private func handleStateChange() {
        switch playback.state {
        case .playing:
            network.noteSuccess()
            reset()
        case let .ready(ctx):
            if !ctx.pendingAutoplay, recovery == nil {
                network.noteSuccess()
                reset()
            }
        case let .failed(_, error):
            guard let track = playback.currentTrack, track.sourceID != .mock else { return }
            if recoveringIdentity != track.identity {
                reset()
                recoveringIdentity = track.identity
            }
            resumePosition = max(resumePosition, playback.currentPosition)
            network.noteFailure(error)
            guard recovery == nil else { return }
            schedule(for: track, error: error)
        case .idle:
            recoveryToken = UUID()
            recovery?.cancel()
            recovery = nil
            reset()
        case .preparing, .paused, .buffering, .seeking, .ended:
            break
        }
    }

    private func reset() {
        attempt = 0
        networkProbes = 0
        recoveringIdentity = nil
        resumePosition = 0
    }

    private func schedule(for track: Track, error: PlaybackError) {
        let action = PlaybackRecoveryPolicy.decide(attempt: attempt, isOnline: network.isOnline, error: error)
        let delay: Duration
        switch action {
        case .refetch:
            attempt += 1
            delay = .zero
            lastAction = "重新取流"
        case let .wait(seconds):
            attempt += 1
            delay = .milliseconds(Int(seconds * 1000))
            lastAction = "稍后重试"
        case .waitForNetwork:
            networkProbes += 1
            guard networkProbes <= PlaybackRecoveryPolicy.maxNetworkProbes else {
                lastAction = "放弃重试"
                return
            }
            delay = .milliseconds(Int(PlaybackRecoveryPolicy.backoff(min(networkProbes, 4)) * 1000))
            lastAction = "等待网络"
        case .giveUp:
            lastAction = "放弃重试"
            return
        }

        let resumeAt = resumePosition
        let shouldAutoplay = playback.state.context?.pendingAutoplay ?? true
        let token = UUID()
        recoveryToken = token
        recovery = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.recoveryToken == token {
                    self.recovery = nil
                }
            }
            if delay > .zero { try? await self.clock.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            guard case .failed = self.playback.state,
                  self.playback.currentTrack?.identity == track.identity else { return }
            if case .decodeFailed = error {
                await self.onEvictCache(track)
            }
            await self.playback.load(track, autoplay: shouldAutoplay)
            guard !Task.isCancelled,
                  self.recoveryToken == token,
                  self.playback.currentTrack?.identity == track.identity else { return }
            if resumeAt > 1 {
                switch self.playback.state {
                case .playing, .ready:
                    await self.playback.seek(to: resumeAt)
                default:
                    break
                }
            }
            self.recovery = nil
            if case .failed = self.playback.state,
               self.playback.currentTrack?.identity == track.identity {
                self.handleStateChange()
            }
        }
    }
}
