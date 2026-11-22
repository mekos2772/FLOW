import Foundation
import Observation

/// 源无关的相关推荐连续电台驱动：队列末尾播完后调用对应源的 `RelatedRadioSourceProvider` 续播。
@MainActor
@Observable
final class RelatedRadioDriver {
    @ObservationIgnored private let playback: any PlaybackControlling
    @ObservationIgnored private let relatedProvider: @Sendable (Track, Int) async throws -> [Track]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var recent: [TrackIdentity] = []
    @ObservationIgnored private let historyLimit = 12
    @ObservationIgnored private var attemptedFor: TrackIdentity?

    private(set) var isEnabled: Bool
    private(set) var isFetching = false
    private(set) var lastNote: String?

    private static let enabledKey = "settings.radioEnabled"

    init(playback: any PlaybackControlling,
         relatedProvider: @escaping @Sendable (Track, Int) async throws -> [Track],
         defaults: UserDefaults = RuntimeSandbox.defaults) {
        self.playback = playback
        self.relatedProvider = relatedProvider
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: Self.enabledKey) == nil
            ? true : defaults.bool(forKey: Self.enabledKey)
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            for await _ in self.playback.stateUpdates() {
                if Task.isCancelled { return }
                await self.handleStateChange()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        attemptedFor = nil
        if enabled {
            Task { await self.handleStateChange() }
        }
    }

    private func handleStateChange() async {
        guard let track = playback.currentTrack else { return }
        remember(track.identity)

        let queue = playback.queueSnapshot
        if case .ended = playback.state, !queue.hasNext {
            guard isEnabled, attemptedFor != track.identity else { return }
            attemptedFor = track.identity
            await advance()
            return
        }
        if case .ended = playback.state {} else {
            attemptedFor = nil
        }
    }

    func advance() async {
        guard !isFetching else { return }
        guard let current = playback.currentTrack else { return }

        isFetching = true
        defer { isFetching = false }
        do {
            let related = try await relatedProvider(current, 20)
            guard case .ended = playback.state,
                  playback.currentTrack?.identity == current.identity,
                  !playback.queueSnapshot.hasNext else { return }
            guard let next = Self.pick(from: related, excluding: recent) else {
                lastNote = String(localized: "没有可用的相关推荐了")
                return
            }
            lastNote = next.title.isEmpty ? nil : next.title
            await playback.load(next, autoplay: true)
            remember(next.identity)
        } catch {
            lastNote = String(localized: "取相关推荐失败")
        }
    }

    @discardableResult
    private func remember(_ identity: TrackIdentity) -> Bool {
        guard !recent.contains(identity) else { return false }
        recent.append(identity)
        if recent.count > historyLimit {
            recent.removeFirst(recent.count - historyLimit)
        }
        return true
    }

    static func pick(from candidates: [Track], excluding played: [TrackIdentity]) -> Track? {
        candidates.first { !played.contains($0.identity) }
    }
}
