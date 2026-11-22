import Foundation
import XCTest
@testable import SpatialLyricsPlayer

/// 歌词到底从哪来。
///
/// `SourceAwareLyricsLoader` 决定这件事，但之前**零覆盖**：
/// 源给了歌词就用源的；源没给（或抛错）就退回本地文件加载器。
/// 这条策略错了，表现为"在线曲目明明有歌词却显示没有"，很难从界面上看出来。
final class SourceAwareLyricsLoaderTests: XCTestCase {

    /// 只关心 `lyrics(for:)`，其余一律走空实现。
    private struct StubSource: PlaybackSourceProvider {
        let id: SourceID
        let document: LyricsDocument?
        let shouldThrow: Bool

        var descriptor: SourceDescriptor {
            SourceDescriptor(id: id, displayName: "stub", requiresNetwork: false,
                             supportsSearch: false, supportsLyrics: document != nil)
        }
        func search(_ request: SearchRequest) async throws -> [Track] { [] }
        func makeSession(for track: Track) async throws -> any PlaybackSession {
            throw PlaybackError.sourceUnavailable
        }
        func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession {
            throw PlaybackError.sourceUnavailable
        }
        func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
        func lyrics(for track: Track) async throws -> LyricsDocument? {
            if shouldThrow { throw PlaybackError.sourceUnavailable }
            return document
        }
        func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
        func completed(_ track: Track) async {}
    }

    private func document(lines: [String]) -> LyricsDocument {
        LyricsDocument(
            trackIdentity: TrackIdentity(sourceID: SourceID("stub"), externalID: "x"),
            lines: lines.enumerated().map { LyricLine(start: Double($0.offset) * 5, text: $0.element) },
            source: .external,
            synchronization: .synced)
    }

    private func track(sourceID: String = "stub") -> Track {
        Track(sourceID: SourceID(sourceID), externalID: "x",
              title: "曲目", artist: "", album: nil, duration: 100)
    }

    func testUsesSourceLyricsWhenAvailable() async throws {
        let registry = SourceRegistry()
        let id = SourceID("stub")
        registry.register(StubSource(id: id, document: document(lines: ["来自源"]), shouldThrow: false))

        let loaded = await SourceAwareLyricsLoader(registry: registry).loadLyrics(for: track())
        XCTAssertEqual(try XCTUnwrap(loaded).lines.first?.text, "来自源",
                       "源给了歌词就必须用源的")
    }

    func testFallsBackToLocalWhenSourceHasNothing() async throws {
        let registry = SourceRegistry()
        let id = SourceID("stub")
        registry.register(StubSource(id: id, document: nil, shouldThrow: false))

        // 没有本地文件，所以结果应当是 nil —— 但关键是没有崩、也没有误判成"源有歌词"。
        let loaded = await SourceAwareLyricsLoader(registry: registry).loadLyrics(for: track())
        XCTAssertNil(loaded, "源没有歌词且本地也没有，应当返回 nil")
    }

    func testFallsBackWhenSourceThrows() async throws {
        let registry = SourceRegistry()
        let id = SourceID("stub")
        registry.register(StubSource(id: id, document: document(lines: ["不该被用到"]), shouldThrow: true))

        let loaded = await SourceAwareLyricsLoader(registry: registry).loadLyrics(for: track())
        XCTAssertNil(loaded, "源抛错时应当安静退回本地，而不是把错误抛给界面")
    }

    func testUnknownSourceDoesNotCrash() async {
        let registry = SourceRegistry()   // 什么都没注册
        let loaded = await SourceAwareLyricsLoader(registry: registry).loadLyrics(for: track())
        XCTAssertNil(loaded)
    }

    func testEmptyDocumentFromSourceIsTreatedAsNothing() async {
        let registry = SourceRegistry()
        let id = SourceID("stub")
        registry.register(StubSource(id: id, document: document(lines: []), shouldThrow: false))

        let loaded = await SourceAwareLyricsLoader(registry: registry).loadLyrics(for: track())
        XCTAssertNil(loaded, "空文档等于没有歌词，不能当成\"有歌词但一行都没有\"")
    }
}
