import Foundation
@testable import SpatialLyricsPlayer

/// 播放链路的测试装配器（Round 57 误删后重建）。
///
/// 负责把时钟 / 注册表 / 队列 / 引擎串起来；队列用源的目录预置，
/// 因为切歌类断言依赖「队列里确实有下一首」。
@MainActor
final class EngineHarness {

    let clock: TestPlaybackClock
    let registry: SourceRegistry
    let coordinator: PlaybackCoordinator
    let engine: PlaybackEngine
    let tracks: [Track]

    convenience init(behavior: MockBehavior = .healthy) {
        let clock = TestPlaybackClock()
        let source = MockPlaybackSource(behavior: behavior, clock: clock)
        self.init(clock: clock, provider: source, tracks: source.catalog)
    }

    /// 用调用方提供的源替换默认模拟源。
    /// 只接受能给出目录的脚本源——没有目录就无从预置队列，切歌断言没有意义。
    convenience init(provider: ScriptedSourceProvider) {
        self.init(clock: TestPlaybackClock(), provider: provider, tracks: provider.catalog)
    }

    private init(clock: TestPlaybackClock, provider: any PlaybackSourceProvider, tracks: [Track]) {
        let registry = SourceRegistry()
        registry.register(provider)
        // 引擎的队列来自 setQueue(_:current:)，不是 init 里的 queue 参数——
        // 只传 queue 会被 load() 用 orderedTrackIDs 覆盖成「只剩当前首」。
        let queue = PlaybackQueue()
        self.clock = clock
        self.registry = registry
        self.tracks = tracks
        self.coordinator = PlaybackCoordinator(registry: registry)
        let engine = PlaybackEngine(clock: clock, coordinator: coordinator, queue: queue)
        engine.setQueue(tracks)
        self.engine = engine
    }
}

/// 可脚本化的源：包一层模拟源，但目录里的曲目换成独立源标识，
/// 且**故意建会话失败**——用来验证「源替换后错误路径可复现」。
struct ScriptedSourceProvider: PlaybackSourceProvider {

    static let sourceID = SourceID(rawValue: "scripted")

    let catalog: [Track]
    private let inner: MockPlaybackSource

    init(behavior: MockBehavior = .healthy, clock: any PlaybackClock = SystemPlaybackClock()) {
        let inner = MockPlaybackSource(behavior: behavior, clock: clock)
        self.inner = inner
        self.catalog = inner.catalog.map { track in
            Track(id: track.id,
                  sourceID: Self.sourceID,
                  externalID: track.externalID,
                  title: track.title,
                  artist: track.artist,
                  album: track.album,
                  duration: track.duration,
                  artwork: track.artwork,
                  lyrics: track.lyrics,
                  persistentIdentifier: track.persistentIdentifier)
        }
    }

    var descriptor: SourceDescriptor {
        SourceDescriptor(id: Self.sourceID,
                         displayName: "脚本源",
                         requiresNetwork: false,
                         supportsSearch: true,
                         supportsLyrics: false)
    }

    func search(_ request: SearchRequest) async throws -> [Track] { catalog }

    /// 内层模拟源会校验 `track.sourceID == 自己的 descriptor.id`，
    /// 而本源的曲目 sourceID 是 "scripted"，所以按 id 换回内层记录后再建会话。
    /// 这样「换源后轨迹相同」才是真的相同，而不是靠同源冒充。
    func makeSession(for track: Track) async throws -> any PlaybackSession {
        let innerTrack = inner.catalog.first { $0.id == track.id } ?? track
        return try await inner.makeSession(for: innerTrack)
    }

    func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession {
        try await inner.refresh(session)
    }

    func artwork(for reference: ArtworkReference) async throws -> Data? { nil }

    func lyrics(for track: Track) async throws -> LyricsDocument? { nil }

    func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
}

extension Track {
    static var mock: Track { mock(externalID: UUID().uuidString) }

    static func mock(externalID: String,
                     title: String = "测试曲目",
                     artist: String = "测试艺术家",
                     duration: TimeInterval = 180) -> Track {
        Track(id: UUID(),
              sourceID: .mock,
              externalID: externalID,
              title: title,
              artist: artist,
              album: nil,
              duration: duration,
              artwork: nil,
              lyrics: nil,
              persistentIdentifier: nil)
    }
}
