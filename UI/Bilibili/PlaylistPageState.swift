import Foundation
import Observation

/// 歌单页只投影仓库快照，可见索引始终映射回原始条目。
@MainActor
@Observable
final class PlaylistPageState {
    private(set) var playlists: [Playlist] = []
    var selectedID: UUID?
    var newName = ""
    var message: String?
    var deletingID: UUID?
    var isDownloadingOffline = false
    let list = SongListState()
    private(set) var revision = 0

    var selected: Playlist? { playlists.first { $0.id == selectedID } }
    var visibleEntries: [(index: Int, track: Track)] {
        guard let selected else { return [] }
        return selected.entries.enumerated().compactMap { index, entry in
            guard let track = list.tracks.first(where: {
                $0.sourceID == entry.sourceID && $0.externalID == entry.externalID
            }) else { return nil }
            return (index, track)
        }
    }

    func reload(app: AppContainer?) {
        playlists = app?.playlists.playlists() ?? []
        if !playlists.contains(where: { $0.id == selectedID }) { select(playlists.first?.id) }
        revision &+= 1
    }

    func select(_ id: UUID?) {
        list.cancel()
        list.tracks = []
        list.message = nil
        message = nil
        selectedID = id
    }

    func create(app: AppContainer?) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let store = app?.playlists else { return }
        select(store.create(name: name).id)
        newName = ""
        reload(app: app)
    }

    func confirmDelete(app: AppContainer?) {
        guard let id = deletingID else { return }
        deletingID = nil
        app?.playlists.delete(id: id)
        reload(app: app)
    }

    func remove(at originalIndex: Int, app: AppContainer?) {
        guard let selected, selected.entries.indices.contains(originalIndex) else { return }
        app?.playlists.remove(selected.entries[originalIndex], from: selected.id)
        reload(app: app)
    }

    func move(from offsets: IndexSet, to destination: Int, app: AppContainer?) {
        let visible = visibleEntries
        guard let selected, let from = offsets.first, visible.indices.contains(from) else { return }
        let target = destination > from ? destination - 1 : destination
        guard visible.indices.contains(target) else { return }
        app?.playlists.move(in: selected.id, from: visible[from].index, to: visible[target].index)
        reload(app: app)
    }

    func addCurrent(app: AppContainer?) {
        guard let app, let selected, let track = app.playback.currentTrack,
              app.sourceManager.isTrackVisible(track) else {
            message = String(localized: "歌曲尚未确认")
            return
        }
        let added = app.playlists.add(PlaylistEntry(sourceID: track.sourceID, externalID: track.externalID), to: selected.id)
        message = added ? String(localized: "已加入歌单") : String(localized: "这首已经在歌单里了")
        reload(app: app)
    }

    func loadSongs(app: AppContainer?) async {
        guard !Task.isCancelled, let app, let selected else { return }
        await list.load { progress in
            let stored = try await app.tracks.all()
            let live = app.playback.queueSnapshot.items.compactMap { app.playback.track(for: $0) }
            let raw = selected.entries.map { entry in
                let identity = TrackIdentity(sourceID: entry.sourceID, externalID: entry.externalID)
                return app.offline.savedTrack(for: identity)
                    ?? (live + stored).first { $0.identity == identity }
                    ?? Track(sourceID: entry.sourceID, externalID: entry.externalID,
                             title: entry.externalID, artist: "", duration: 0)
            }
            guard !raw.isEmpty else { return [] }
            guard app.settings.enableNetwork else {
                return raw.filter { app.offline.isOffline($0.identity) || app.sourceManager.isTrackVisible($0) }
            }
            return try await app.sourceManager.verifyTracks(raw, progress: progress)
        }
    }

    func downloadOffline(app: AppContainer?) async {
        let tracks = visibleEntries.map(\.track)
        guard let app, !tracks.isEmpty, !isDownloadingOffline else { return }
        isDownloadingOffline = true
        defer { isDownloadingOffline = false }
        _ = await app.downloadOffline(tracks)
        message = app.offline.statusMessage
    }

    @discardableResult
    func play(_ track: Track? = nil, app: AppContainer?) -> Bool {
        let tracks = visibleEntries.map(\.track)
        guard let app, let current = track ?? tracks.first,
              tracks.contains(where: { $0.identity == current.identity }) else { return false }
        app.playback.setQueue(tracks, current: current)
        Task { await app.playback.load(current, autoplay: true) }
        return true
    }
}
