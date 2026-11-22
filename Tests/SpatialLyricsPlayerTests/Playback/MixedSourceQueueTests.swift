import XCTest
@testable import SpatialLyricsPlayer

/// 多源路由与通用播放队列契约（取代原耦合 B 站的 BiliMixedQueueTests）。
@MainActor
final class MixedSourceQueueTests: XCTestCase {

    private struct StubRemoteSource: PlaybackSourceProvider {
        static let sourceID = SourceID(rawValue: "remote-a")
        var descriptor: SourceDescriptor {
            SourceDescriptor(id: Self.sourceID, displayName: "Remote A", kind: .jsPlugin, requiresNetwork: true)
        }
        func search(_ request: SearchRequest) async throws -> [Track] { [] }
        func makeSession(for track: Track) async throws -> any PlaybackSession { throw PlaybackError.sourceUnavailable }
        func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession { throw PlaybackError.sourceUnavailable }
        func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
        func lyrics(for track: Track) async throws -> LyricsDocument? { nil }
        func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
    }

    private func makeRegistry() -> SourceRegistry {
        let registry = SourceRegistry()
        registry.register(MockPlaybackSource(behavior: .healthy, clock: TestPlaybackClock()))
        registry.register(StubRemoteSource())
        return registry
    }

    func testRegistryRoutesEachTrackToItsOwnSource() {
        let registry = makeRegistry()
        let mockTrack = Track(sourceID: .mock, externalID: "m1", title: "模拟", artist: "", duration: 100)
        let remoteTrack = Track(sourceID: StubRemoteSource.sourceID, externalID: "r1", title: "在线", artist: "", duration: 200)

        XCTAssertEqual(registry.provider(for: mockTrack.sourceID)?.descriptor.id, .mock)
        XCTAssertEqual(registry.provider(for: remoteTrack.sourceID)?.descriptor.id, StubRemoteSource.sourceID)
        XCTAssertNotEqual(SourceID.mock, StubRemoteSource.sourceID)
    }

    func testQueueKeepsOrderAndRepeatAllWrapsAndShuffleCoversAll() {
        let first = Track(sourceID: StubRemoteSource.sourceID, externalID: "r1", title: "一", artist: "", duration: 100)
        let second = Track(sourceID: .localFile, externalID: "/music/2.m4a", title: "二", artist: "", duration: 200)
        var queue = PlaybackQueue()
        queue.replace(items: [first.id, second.id, first.id], current: first.id)
        XCTAssertEqual(queue.currentID, first.id)
        XCTAssertEqual(queue.advance(), second.id)

        var wrapping = PlaybackQueue()
        wrapping.replace(items: [first.id, second.id], current: first.id)
        wrapping.repeatMode = .all
        XCTAssertEqual(wrapping.advance(), second.id)
        XCTAssertEqual(wrapping.advance(), first.id)

        let tracks = (0..<6).map { index in
            Track(sourceID: index % 2 == 0 ? StubRemoteSource.sourceID : .mock,
                  externalID: "id-\(index)", title: "t\(index)", artist: "", duration: 100)
        }
        var shuffled = PlaybackQueue()
        shuffled.replace(items: tracks.map(\.id), current: tracks[0].id)
        shuffled.shuffleSeed = 42
        var seen: Set<Track.ID> = [tracks[0].id]
        for _ in 0..<(tracks.count - 1) {
            guard let next = shuffled.advance() else { break }
            XCTAssertFalse(seen.contains(next))
            seen.insert(next)
        }
        XCTAssertEqual(seen.count, tracks.count)
    }
}
