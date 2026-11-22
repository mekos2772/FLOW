import XCTest
@testable import SpatialLyricsPlayer

@MainActor
final class PlaylistPageTests: XCTestCase {
    func testCreateRejectsBlankAndDeletionRequiresConfirmation() throws {
        let app = try ContainerBuilder.make(.testing(inMemory: true))
        let page = PlaylistPageState()
        page.newName = "  "
        page.create(app: app)
        XCTAssertTrue(app.playlists.playlists().isEmpty)
        page.newName = "测试歌单"
        page.create(app: app)
        let id = try XCTUnwrap(page.selectedID)
        page.deletingID = id
        XCTAssertEqual(app.playlists.playlists().count, 1)
        page.deletingID = nil
        page.confirmDelete(app: app)
        XCTAssertEqual(app.playlists.playlists().count, 1)
        page.deletingID = id
        page.confirmDelete(app: app)
        XCTAssertTrue(app.playlists.playlists().isEmpty)
        XCTAssertNil(page.selected)
    }

    func testVisibleIndexMappingRetainsHiddenEntries() throws {
        let app = try ContainerBuilder.make(.testing(inMemory: true))
        let tracks = MockCatalog.tracks(count: 3)
        let playlist = app.playlists.create(name: "排序")
        let entries = tracks.map { PlaylistEntry(sourceID: $0.sourceID, externalID: $0.externalID) }
        entries.forEach { app.playlists.add($0, to: playlist.id) }
        let page = PlaylistPageState()
        page.reload(app: app)
        page.list.tracks = [tracks[0], tracks[2]]
        XCTAssertEqual(page.visibleEntries.map(\.index), [0, 2])
        page.move(from: IndexSet(integer: 0), to: 2, app: app)
        XCTAssertEqual(app.playlists.entries(in: playlist.id), [entries[1], entries[2], entries[0]])
        page.remove(at: page.visibleEntries[0].index, app: app)
        XCTAssertEqual(app.playlists.entries(in: playlist.id), [entries[1], entries[0]])
    }

    func testSingleSongPlayKeepsVisiblePlaylistOrder() async throws {
        let app = try ContainerBuilder.make(.testing(inMemory: true))
        let tracks = MockCatalog.tracks(count: 3)
        let playlist = app.playlists.create(name: "播放")
        for track in tracks {
            try await app.tracks.save(track)
            app.playlists.add(PlaylistEntry(sourceID: track.sourceID, externalID: track.externalID), to: playlist.id)
        }
        let page = PlaylistPageState()
        page.reload(app: app)
        await page.loadSongs(app: app)
        XCTAssertTrue(page.play(tracks[1], app: app))
        XCTAssertEqual(app.playback.queueSnapshot.items, tracks.map(\.id))
        XCTAssertEqual(app.playback.queueSnapshot.currentID, tracks[1].id)
        for _ in 0..<100 {
            if app.playback.currentTrack?.id == tracks[1].id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(app.playback.currentTrack?.id, tracks[1].id)
        await app.playback.stop()
    }
}
