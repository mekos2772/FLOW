import Foundation
import XCTest
@testable import SpatialLyricsPlayer

/// 验证第二阶段多音源抽象层：`SourceManager`、`RelatedRadioDriver` 与 `PlaybackRecoveryDriver`。
@MainActor
final class SourceManagerTests: XCTestCase {

    private struct StubSource:
        PlaybackSourceProvider,
        DiscoverableSourceProvider,
        URLResolvableSourceProvider,
        RelatedRadioSourceProvider
    {
        let descriptor: SourceDescriptor
        var searchResults: [Track] = []
        var discoverResults: [Track] = []
        var relatedResults: [Track] = []
        var handledPrefix: String?
        var shouldThrowOnSearch = false

        func search(_ request: SearchRequest) async throws -> [Track] {
            if shouldThrowOnSearch {
                throw RemoteHTTPFailure(code: 503, message: "upstream down", url: "https://example.local")
            }
            return searchResults
        }

        func discoverTracks(limit: Int, progress: (@Sendable (TrackListBatch) -> Void)?) async throws -> [Track] {
            Array(discoverResults.prefix(limit))
        }

        func canHandleQuery(_ query: String) -> Bool {
            guard let handledPrefix else { return false }
            return query.hasPrefix(handledPrefix)
        }

        func resolveQuery(_ query: String) async throws -> [Track] {
            searchResults.filter { $0.externalID == query || query.hasPrefix(handledPrefix ?? "") }
        }

        func relatedTracks(for track: Track, limit: Int) async throws -> [Track] {
            Array(relatedResults.prefix(limit))
        }

        func makeSession(for track: Track) async throws -> any PlaybackSession {
            throw PlaybackError.sourceUnavailable
        }

        func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession {
            throw PlaybackError.sourceUnavailable
        }

        func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
        func lyrics(for track: Track) async throws -> LyricsDocument? { nil }
        func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "flow.sourcemanager.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    private final class NetworkFlag: @unchecked Sendable {
        var enabled = true
    }

    func testRegistrationSwitchingAndNetworkGate() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let networkFlag = NetworkFlag()
        let registry = SourceRegistry()
        let manager = SourceManager(registry: registry, networkEnabledProvider: { networkFlag.enabled }, defaults: defaults)

        let alphaID = SourceID(rawValue: "alpha")
        let localID = SourceID(rawValue: "local-stub")

        let alpha = StubSource(descriptor: SourceDescriptor(
            id: alphaID,
            displayName: "Alpha",
            kind: .jsPlugin,
            requiresNetwork: true,
            supportsDiscover: true
        ))
        let local = StubSource(descriptor: SourceDescriptor(
            id: localID,
            displayName: "Local",
            kind: .builtinLocal,
            requiresNetwork: false,
            supportsDiscover: true
        ))

        manager.registerSource(alpha, originLabel: "Alpha")
        manager.registerSource(local, isBuiltIn: true, originLabel: "Local")

        XCTAssertTrue(manager.hasAnyConfiguredSource)
        XCTAssertEqual(manager.browsableSources.map(\.id), [alphaID, localID])
        XCTAssertEqual(manager.activeBrowseSource?.id, alphaID)

        manager.selectActiveBrowseSource(localID)
        XCTAssertEqual(manager.activeBrowseSource?.id, localID)

        // 禁用当前源会自动回落到下一个可用源，并从 PlaybackEngine 注册表注销。
        manager.setSourceEnabled(localID, enabled: false)
        XCTAssertNil(registry.provider(for: localID))
        XCTAssertEqual(manager.activeBrowseSource?.id, alphaID)

        // 关网时只注销需要联网的源，但保留其配置记录。
        manager.setSourceEnabled(localID, enabled: true)
        networkFlag.enabled = false
        manager.syncNetworkState()
        XCTAssertNil(registry.provider(for: alphaID))
        XCTAssertNotNil(registry.provider(for: localID))
    }

    func testSingleVsAggregateSearchAndURLDispatch() async throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let registry = SourceRegistry()
        let manager = SourceManager(registry: registry, networkEnabledProvider: { true }, defaults: defaults)

        let s1 = SourceID(rawValue: "src1")
        let s2 = SourceID(rawValue: "src2")
        let s3 = SourceID(rawValue: "src3")

        let t1 = Track(sourceID: s1, externalID: "id-1", title: "One", artist: "A", duration: 120)
        let t2 = Track(sourceID: s2, externalID: "id-2", title: "Two", artist: "B", duration: 180)
        let t1Direct = Track(sourceID: s1, externalID: "scheme://open/1", title: "Direct", artist: "A", duration: 100)

        manager.registerSource(StubSource(
            descriptor: SourceDescriptor(id: s1, displayName: "One", kind: .jsPlugin, requiresNetwork: true, supportsDiscover: true),
            searchResults: [t1, t1Direct],
            discoverResults: [t1],
            handledPrefix: "scheme://"
        ))
        manager.registerSource(StubSource(
            descriptor: SourceDescriptor(id: s2, displayName: "Two", kind: .jsonTemplate, requiresNetwork: true),
            searchResults: [t2]
        ))
        manager.registerSource(StubSource(
            descriptor: SourceDescriptor(id: s3, displayName: "Broken", kind: .jsPlugin, requiresNetwork: true),
            shouldThrowOnSearch: true
        ))

        // 聚合搜索应返回正常源的结果并隔离单个失败源的异常。
        manager.aggregateSearchEnabled = true
        let aggregated = try await manager.search(query: "test")
        XCTAssertEqual(Set(aggregated.map(\.identity)), Set([t1.identity, t1Direct.identity, t2.identity]))

        // 关闭聚合后只查当前浏览源。
        manager.selectActiveBrowseSource(s2)
        manager.aggregateSearchEnabled = false
        let singleOnly = try await manager.search(query: "test")
        XCTAssertEqual(singleOnly.map(\.identity), [t2.identity])

        // URL 直链解析不受聚合开关限制，直接派发到声称能处理前缀的源。
        let resolved = try await manager.search(query: "scheme://open/1")
        XCTAssertTrue(resolved.contains(where: { $0.identity == t1Direct.identity }))

        // Discover 只走当前浏览源（或显式指定的 sourceID）。
        let discovered = try await manager.discoverTracks(sourceID: s1, limit: 10)
        XCTAssertEqual(discovered.map(\.identity), [t1.identity])
    }

    private final class EndableTestSession: PlaybackSession, @unchecked Sendable {
        let id = UUID()
        let duration: TimeInterval
        let capabilities = SessionCapabilities.full
        let events: AsyncStream<SessionEvent>
        private let continuation: AsyncStream<SessionEvent>.Continuation

        init(duration: TimeInterval = 180) {
            self.duration = duration
            var cont: AsyncStream<SessionEvent>.Continuation!
            self.events = AsyncStream { cont = $0 }
            self.continuation = cont
        }

        func prepare() async throws { continuation.yield(.prepared(duration: duration)) }
        func play() async throws {}
        func pause() async {}
        func seek(to position: TimeInterval) async throws {}
        func setRate(_ rate: Double) async {}
        func setVolume(_ volume: Float) async {}
        func invalidate() async { continuation.finish() }
        func finish() { continuation.yield(.ended) }
    }

    private final class EndableTestSource: PlaybackSourceProvider, @unchecked Sendable {
        let descriptor = SourceDescriptor(id: SourceID(rawValue: "radio-stub"), displayName: "Radio", requiresNetwork: false)
        var sessions: [TrackIdentity: EndableTestSession] = [:]

        func search(_ request: SearchRequest) async throws -> [Track] { [] }
        func makeSession(for track: Track) async throws -> any PlaybackSession {
            let session = EndableTestSession(duration: track.duration)
            sessions[track.identity] = session
            return session
        }
        func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession { session }
        func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
        func lyrics(for track: Track) async throws -> LyricsDocument? { nil }
        func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
    }

    func testRelatedRadioDriverAppendsRelatedTrackWhenQueueEnds() async throws {
        let clock = SystemPlaybackClock()
        let source = EndableTestSource()
        let registry = SourceRegistry()
        registry.register(source)
        let engine = PlaybackEngine(clock: clock, coordinator: PlaybackCoordinator(registry: registry))

        let current = Track(
            sourceID: source.descriptor.id,
            externalID: "current-track",
            title: "Current Song",
            artist: "Mock",
            duration: 180
        )
        let related = Track(
            sourceID: source.descriptor.id,
            externalID: "related-next",
            title: "Related Song",
            artist: "Mock",
            duration: 180
        )

        let defaultsSuite = "flow.radio.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let radio = RelatedRadioDriver(
            playback: engine,
            relatedProvider: { _, _ in [related] },
            defaults: defaults
        )
        radio.start()
        defer { radio.stop() }

        engine.setQueue([current], current: current)
        await engine.load(current, autoplay: true)
        source.sessions[current.identity]?.finish()

        for _ in 0..<40 {
            if engine.currentTrack?.identity == related.identity { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(engine.currentTrack?.identity, related.identity)
        XCTAssertNil(RelatedRadioDriver.pick(from: [related], excluding: [related.identity]))
    }

    func testPlaybackRecoveryPolicyAndConnectivityMonitor() {
        let monitor = NetworkConnectivityMonitor()
        XCTAssertTrue(monitor.isOnline)
        monitor.noteFailure(.networkUnavailable)
        XCTAssertFalse(monitor.isOnline)
        monitor.noteSuccess()
        XCTAssertTrue(monitor.isOnline)

        XCTAssertEqual(PlaybackRecoveryPolicy.decide(attempt: 0, isOnline: true, error: .sourceUnavailable), .refetch)
        XCTAssertEqual(PlaybackRecoveryPolicy.decide(attempt: 1, isOnline: false, error: .sourceUnavailable), .waitForNetwork)
        XCTAssertEqual(PlaybackRecoveryPolicy.decide(attempt: 0, isOnline: true, error: .networkDisabled), .giveUp)
        XCTAssertEqual(PlaybackRecoveryPolicy.decide(attempt: 3, isOnline: true, error: .sourceUnavailable), .giveUp)
    }
}
