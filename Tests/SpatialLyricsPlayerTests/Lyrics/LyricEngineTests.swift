import XCTest
@testable import SpatialLyricsPlayer

@MainActor
final class LyricEngineTests: XCTestCase {

    private func makeEngine(loader: StubLyricsLoader) throws -> (LyricEngine, PersistenceController) {
        let persistence = try PersistenceController(inMemory: true)
        let store = SwiftDataLyricsOffsetStore(modelContainer: persistence.container)
        return (LyricEngine(loader: loader, offsets: store), persistence)
    }

    func testLoadsDocumentAndResolvesCurrentLine() async throws {
        let loader = StubLyricsLoader()
        let track = LyricsTestFixtures.track(externalID: "t1")
        loader.stub(LyricsTestFixtures.document(for: track, starts: [0, 10, 20]), for: "t1")

        let (engine, _) = try makeEngine(loader: loader)
        await engine.load(track: track)

        XCTAssertEqual(engine.state, .loaded)
        XCTAssertEqual(engine.snapshot(at: 12).current?.text, "t1-L1")
        XCTAssertEqual(engine.snapshot(at: 12).next?.text, "t1-L2")
    }

    func testMissingLyricsReportsEmpty() async throws {
        let loader = StubLyricsLoader()
        let track = LyricsTestFixtures.track(externalID: "none")
        let (engine, _) = try makeEngine(loader: loader)

        await engine.load(track: track)
        XCTAssertEqual(engine.state, .empty)
        XCTAssertNil(engine.snapshot(at: 10).current)
    }

    func testFastTrackSwitchDiscardsStaleLyrics() async throws {
        let loader = StubLyricsLoader()
        let slow = LyricsTestFixtures.track(externalID: "slow")
        let fast = LyricsTestFixtures.track(externalID: "fast")
        loader.stub(LyricsTestFixtures.document(for: slow, starts: [0]), for: "slow", delay: .milliseconds(300))
        loader.stub(LyricsTestFixtures.document(for: fast, starts: [0]), for: "fast")

        let (engine, _) = try makeEngine(loader: loader)

        let first = Task { await engine.load(track: slow) }
        try await Task.sleep(for: .milliseconds(50))
        await engine.load(track: fast)
        _ = await first.value

        XCTAssertEqual(engine.currentIdentity, fast.identity, "慢加载晚到不得覆盖当前曲目")
        XCTAssertEqual(engine.snapshot(at: 1).current?.text, "fast-L0")
    }

    func testOffsetShiftsTimeline() async throws {
        let loader = StubLyricsLoader()
        let track = LyricsTestFixtures.track(externalID: "off")
        loader.stub(LyricsTestFixtures.document(for: track, starts: [10]), for: "off")

        let (engine, _) = try makeEngine(loader: loader)
        await engine.load(track: track)

        XCTAssertNil(engine.snapshot(at: 9.5).current, "10s 的行在 9.5s 时还没到")
        engine.setOffset(0.5)
        XCTAssertNotNil(engine.snapshot(at: 9.5).current, "offset 应把时间轴推后以适应播放时间")
    }

    func testOffsetPersistsPerTrack() async throws {
        let loader = StubLyricsLoader()
        let a = LyricsTestFixtures.track(externalID: "a")
        let b = LyricsTestFixtures.track(externalID: "b")
        loader.stub(LyricsTestFixtures.document(for: a, starts: [0]), for: "a")
        loader.stub(LyricsTestFixtures.document(for: b, starts: [0]), for: "b")

        let (engine, _) = try makeEngine(loader: loader)

        await engine.load(track: a)
        engine.adminSetOffsetForTest(0.35)
        await engine.commitOffset()

        await engine.load(track: b)
        XCTAssertEqual(engine.userOffset, 0, "不同曲目不得共享偏移")

        await engine.load(track: a)
        XCTAssertEqual(engine.userOffset, 0.35, accuracy: 0.0001)
    }

    func testRevertDiscardsUnsavedOffset() async throws {
        let loader = StubLyricsLoader()
        let track = LyricsTestFixtures.track(externalID: "rev")
        loader.stub(LyricsTestFixtures.document(for: track, starts: [0]), for: "rev")

        let (engine, _) = try makeEngine(loader: loader)
        await engine.load(track: track)

        engine.adjustOffset(by: 0.2)
        XCTAssertEqual(engine.userOffset, 0.2, accuracy: 0.0001)

        await engine.revertOffset()
        XCTAssertEqual(engine.userOffset, 0, accuracy: 0.0001)
    }

    func testResetClearsPersistedOffset() async throws {
        let loader = StubLyricsLoader()
        let track = LyricsTestFixtures.track(externalID: "reset")
        loader.stub(LyricsTestFixtures.document(for: track, starts: [0]), for: "reset")

        let (engine, _) = try makeEngine(loader: loader)
        await engine.load(track: track)
        engine.adminSetOffsetForTest(1.0)
        await engine.commitOffset()
        await engine.resetOffset()

        await engine.load(track: track)
        XCTAssertEqual(engine.userOffset, 0, accuracy: 0.0001)
    }

    func testOffsetIsMillisecondPrecision() async throws {
        let loader = StubLyricsLoader()
        let track = LyricsTestFixtures.track(externalID: "ms")
        loader.stub(LyricsTestFixtures.document(for: track, starts: [0]), for: "ms")

        let (engine, _) = try makeEngine(loader: loader)
        await engine.load(track: track)
        engine.adjustOffset(by: 0.12345)
        XCTAssertEqual(engine.userOffset, 0.123, accuracy: 0.0005)
    }
}
