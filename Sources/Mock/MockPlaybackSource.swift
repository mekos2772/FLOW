import Foundation

/// Phase 0 唯一实现的源。用于验证播放链路，不代表产品将绑定任何媒体库。
struct MockPlaybackSource: PlaybackSourceProvider {
    let descriptor: SourceDescriptor
    let behavior: MockBehavior
    let clock: any PlaybackClock
    let catalog: [Track]
    private let sessionCache = MockSessionCache()
    private let attempts = MockAttemptCounter()

    init(behavior: MockBehavior = .healthy,
         clock: any PlaybackClock = SystemPlaybackClock()) {
        self.init(behavior: behavior, clock: clock, catalog: MockCatalog.tracks(count: behavior.corpusSize))
    }

    init(behavior: MockBehavior, clock: any PlaybackClock, catalog: [Track]) {
        self.behavior = behavior
        self.clock = clock
        self.catalog = catalog
        self.descriptor = SourceDescriptor(
            id: .mock,
            displayName: "模拟源",
            requiresNetwork: false,
            supportsSearch: true,
            supportsLyrics: false
        )
    }

    func search(_ request: SearchRequest) async throws -> [Track] {
        try Task.checkCancellation()
        try await clock.sleep(for: behavior.searchLatency)
        try Task.checkCancellation()

        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = query.isEmpty
            ? catalog
            : catalog.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.artist.localizedCaseInsensitiveContains(query)
            }
        let slice = matched.dropFirst(request.offset).prefix(request.limit)
        return Array(slice)
    }

    func makeSession(for track: Track) async throws -> any PlaybackSession {
        try Task.checkCancellation()
        guard track.sourceID == descriptor.id else {
            throw PlaybackError.sourceUnavailable
        }
        try await clock.sleep(for: behavior.prepareLatency)
        try Task.checkCancellation()

        if let existing = sessionCache.session(for: track.id), behavior.reusesSession {
            return existing
        }
        let session = MockPlaybackSession(
            duration: track.duration,
            behavior: behavior,
            clock: clock,
            attemptNumber: attempts.next()
        )
        sessionCache.store(session, for: track.id)
        return session
    }

    func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession {
        try Task.checkCancellation()
        await session.invalidate()
        let replacement = MockPlaybackSession(
            duration: session.duration,
            behavior: behavior,
            clock: clock,
            attemptNumber: attempts.next()
        )
        return replacement
    }

    func artwork(for reference: ArtworkReference) async throws -> Data? {
        try Task.checkCancellation()
        // Mock 源没有封面资源，返回 nil 即"无封面"，由表现层降级为占位。
        return nil
    }

    func lyrics(for track: Track) async throws -> LyricsDocument? {
        try Task.checkCancellation()
        return nil
    }

    func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
}

/// 会话创建序号。故障注入依赖它，保证 `failurePlan[1]`、`failurePlan[2]` 跨 session 生效。
final class MockAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// session 缓存。用锁而非 actor，避免在同步路径上引入 await。
final class MockSessionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Track.ID: any PlaybackSession] = [:]

    func session(for id: Track.ID) -> (any PlaybackSession)? {
        lock.lock()
        defer { lock.unlock() }
        return storage[id]
    }

    func store(_ session: any PlaybackSession, for id: Track.ID) {
        lock.lock()
        defer { lock.unlock() }
        storage[id] = session
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}
