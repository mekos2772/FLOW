import XCTest
@testable import SpatialLyricsPlayer

@MainActor
final class HomeNavigationTests: XCTestCase {
    func testBrowsingDoesNotStopOrResetPlayback() async throws {
        let harness = try MorphTestSupport.make()
        let tracks = MockCatalog.tracks(count: 2)
        harness.engine.setQueue(tracks, current: tracks[0])
        await harness.engine.load(tracks[0], autoplay: true)
        await harness.engine.seek(to: 42)
        harness.controller.refreshQueue()
        let model = harness.controller.model
        let state = harness.engine.state
        let position = harness.engine.currentPosition
        let queue = harness.engine.queueSnapshot

        harness.controller.browseToHome()
        await Task.yield()
        XCTAssertTrue(model.showsHome)
        XCTAssertEqual(harness.engine.currentTrack?.identity, tracks[0].identity)
        XCTAssertEqual(harness.engine.state, state)
        XCTAssertEqual(harness.engine.currentPosition, position, accuracy: 0.1)
        XCTAssertEqual(harness.engine.queueSnapshot, queue)

        model.showPlayer()
        XCTAssertFalse(model.showsHome)
        XCTAssertEqual(harness.engine.currentTrack?.identity, tracks[0].identity)
        await harness.engine.stop()
    }

    func testIdleAlwaysShowsHomeAndNavigationPreservesResults() {
        let model = MorphPresentationModel()
        XCTAssertTrue(model.showsHome)
        let song = MockCatalog.tracks(count: 1)[0]
        model.home.query = "Nocturne"
        model.home.list.tracks = [song]
        model.track = song
        model.showPlayer()
        XCTAssertFalse(model.showsHome)
        model.showHome()
        model.home.cancel()
        XCTAssertEqual(model.home.query, "Nocturne")
        XCTAssertEqual(model.home.list.tracks, [song])
        model.showPlayer()
        XCTAssertEqual(model.home.list.tracks, [song])
        model.track = nil
        XCTAssertTrue(model.showsHome)
    }

    func testFavoritesUsesLocalLibraryWithoutOnlineAccount() async throws {
        let app = try ContainerBuilder.make(.testing(inMemory: true))
        let track = MockCatalog.tracks(count: 1)[0]
        try await app.tracks.save(track)
        _ = await app.library.toggleFavorite(track.identity)
        let home = OnlineHomeState()
        home.loadFavorites(app: app)
        for _ in 0..<100 {
            if home.list.tracks == [track], !home.list.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(home.list.tracks, [track])
        XCTAssertEqual(home.section, .favorites)
        XCTAssertNil(home.feedback)
        home.cancel()
    }

    func testEditingSearchCancelsAndClearsStaleFeedback() {
        let home = OnlineHomeState()
        home.select(.search, app: nil)
        home.list.tracks = MockCatalog.tracks(count: 1)
        home.list.message = SourceErrorPresentation.emptyResultSentinel
        home.query = "新歌名"
        home.queryEdited()
        XCTAssertTrue(home.list.tracks.isEmpty)
        XCTAssertNil(home.list.message)
        XCTAssertFalse(home.list.isLoading)
    }

    func testSwitchingLibraryPagesPreservesSearchAndPlayback() async throws {
        let app = try ContainerBuilder.make(.testing(inMemory: true))
        let tracks = MockCatalog.tracks(count: 3)
        for track in tracks { try await app.tracks.save(track) }
        _ = await app.library.toggleFavorite(tracks[1].identity)
        await app.library.recordPlayed(tracks[0].identity, at: Date(timeIntervalSince1970: 1))
        await app.library.recordPlayed(tracks[2].identity, at: Date(timeIntervalSince1970: 2))
        let model = MorphPresentationModel()
        model.home.select(.search, app: nil)
        model.home.query = "保留搜索"
        model.home.list.tracks = [tracks[0]]
        model.browse(.favorites, app: app)
        for _ in 0..<100 {
            if model.home.list.tracks == [tracks[1]] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.home.list.tracks, [tracks[1]])
        model.browse(.recent, app: app)
        for _ in 0..<100 {
            if model.home.list.tracks.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.home.list.tracks.map(\.identity), [tracks[2].identity, tracks[0].identity])
        model.browse(.search, app: nil)
        XCTAssertEqual(model.home.query, "保留搜索")
        XCTAssertEqual(model.home.list.tracks, [tracks[0]])
        model.home.cancel()
    }

    func testRapidNavigationCannotPublishOldLibraryResults() async throws {
        let app = try ContainerBuilder.make(.testing(inMemory: true))
        let track = MockCatalog.tracks(count: 1)[0]
        try await app.tracks.save(track)
        _ = await app.library.toggleFavorite(track.identity)
        let home = OnlineHomeState()
        home.loadFavorites(app: app)
        home.select(.playlists, app: app)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(home.section, .playlists)
        XCTAssertTrue(home.list.tracks.isEmpty)
        XCTAssertFalse(home.list.isLoading)
    }

    func testFeedbackIsShortAndDistinguishesFailureFromNoMatch() {
        let home = OnlineHomeState()
        home.list.message = SourceErrorPresentation.emptyResultSentinel
        XCTAssertEqual(home.feedback, String(localized: "暂无推荐歌曲"))
        home.list.message = SourceErrorPresentation.unavailableSentinel
        XCTAssertEqual(home.feedback, String(localized: "暂时无法加载歌曲"))
    }
}
