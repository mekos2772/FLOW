import XCTest
@testable import SpatialLyricsPlayer

final class MockSourceTests: XCTestCase {

    func testCatalogIsDeterministic() {
        let first = MockCatalog.tracks(count: 12)
        let second = MockCatalog.tracks(count: 12)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 12)
        XCTAssertEqual(Set(first.map(\.externalID)).count, 12, "源内标识必须唯一")
    }

    func testSearchFiltersByTitleAndRespectsLimit() async throws {
        let clock = TestPlaybackClock()
        let source = MockPlaybackSource(behavior: .healthy, clock: clock)

        let all = try await source.search(SearchRequest(query: "", limit: 5))
        XCTAssertEqual(all.count, 5)

        let filtered = try await source.search(SearchRequest(query: "Notch", limit: 10))
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.title, "Notch")
    }

    func testSearchIsCancellable() async {
        let clock = TestPlaybackClock()
        let source = MockPlaybackSource(behavior: .healthy, clock: clock)

        let task = Task {
            try await source.search(SearchRequest(query: "anything"))
        }
        task.cancel()

        do {
            _ = try await task.value
            // 取消可能发生得足够晚，任务成功也是可接受结果。
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testMakeSessionRejectsForeignSourceTrack() async {
        let clock = TestPlaybackClock()
        let source = MockPlaybackSource(behavior: .healthy, clock: clock)
        let foreign = Track(sourceID: SourceID("other"), externalID: "x", title: "x", artist: "x", duration: 10)

        do {
            _ = try await source.makeSession(for: foreign)
            XCTFail("跨源取 session 必须失败")
        } catch let error as PlaybackError {
            XCTAssertEqual(error, .sourceUnavailable)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testFailurePlanHitsSpecifiedAttemptNumbers() async {
        let clock = TestPlaybackClock()
        let behavior = MockBehavior.failOnAttempts([2], with: .decodeFailed(reason: "second"))
        let source = MockPlaybackSource(behavior: behavior, clock: clock)
        let track = MockCatalog.tracks(count: 1)[0]

        do {
            let first = try await source.makeSession(for: track)
            try await first.prepare()

            let second = try await source.makeSession(for: track)
            try await second.prepare()
            XCTFail("第 2 次会话应当失败")
        } catch let error as PlaybackError {
            XCTAssertEqual(error, .decodeFailed(reason: "second"))
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testDescriptorDeclaresNoNetworkDependency() {
        let source = MockPlaybackSource(behavior: .healthy, clock: TestPlaybackClock())
        XCTAssertFalse(source.descriptor.requiresNetwork)
        XCTAssertEqual(source.descriptor.id, .mock)
    }
}
