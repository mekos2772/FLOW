import Foundation
import SwiftData

/// 歌单的 SwiftData 实现。
@MainActor
final class SwiftDataPlaylistStore: PlaylistStoring {
    private let context: ModelContext

    init(modelContainer: ModelContainer) {
        self.context = ModelContext(modelContainer)
        self.context.autosaveEnabled = false
    }

    private func records() -> [PlaylistRecord] {
        let descriptor = FetchDescriptor<PlaylistRecord>(
            sortBy: [SortDescriptor(\PlaylistRecord.createdAt, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func record(id: UUID) -> PlaylistRecord? {
        let uuid = id
        let descriptor = FetchDescriptor<PlaylistRecord>(
            predicate: #Predicate { $0.id == uuid }
        )
        return (try? context.fetch(descriptor))?.first
    }

    func playlists() -> [Playlist] {
        records().map(Self.value(from:))
    }

    @discardableResult
    func create(name: String) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = PlaylistRecord(name: trimmed.isEmpty ? "未命名歌单" : trimmed)
        context.insert(record)
        try? context.save()
        return Self.value(from: record)
    }

    func rename(id: UUID, to name: String) {
        guard let record = record(id: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        record.name = trimmed
        record.updatedAt = .now
        try? context.save()
    }

    func delete(id: UUID) {
        guard let record = record(id: id) else { return }
        context.delete(record)
        try? context.save()
    }

    @discardableResult
    func add(_ entry: PlaylistEntry, to id: UUID) -> Bool {
        guard let record = record(id: id) else { return false }
        guard !record.itemKeys.contains(entry.key) else { return false }
        record.itemKeys.append(entry.key)
        record.updatedAt = .now
        try? context.save()
        return true
    }

    func remove(_ entry: PlaylistEntry, from id: UUID) {
        guard let record = record(id: id) else { return }
        record.itemKeys.removeAll { $0 == entry.key }
        record.updatedAt = .now
        try? context.save()
    }

    func move(in id: UUID, from: Int, to: Int) {
        guard let record = record(id: id) else { return }
        var keys = record.itemKeys
        guard keys.indices.contains(from) else { return }
        let target = max(0, min(keys.count - 1, to))
        let moved = keys.remove(at: from)
        keys.insert(moved, at: target)
        record.itemKeys = keys
        record.updatedAt = .now
        try? context.save()
    }

    func entries(in id: UUID) -> [PlaylistEntry] {
        guard let record = record(id: id) else { return [] }
        return record.itemKeys.compactMap(PlaylistEntry.init(key:))
    }

    private static func value(from record: PlaylistRecord) -> Playlist {
        Playlist(id: record.id,
                 name: record.name,
                 entries: record.itemKeys.compactMap(PlaylistEntry.init(key:)),
                 updatedAt: record.updatedAt)
    }
}

/// 内存实现：测试与预览用，绝不进发布路径。
@MainActor
final class InMemoryPlaylistStore: PlaylistStoring {
    private var storage: [UUID: Playlist] = [:]
    private var order: [UUID] = []

    func playlists() -> [Playlist] {
        order.compactMap { storage[$0] }
    }

    @discardableResult
    func create(name: String) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(id: UUID(),
                                name: trimmed.isEmpty ? "未命名歌单" : trimmed,
                                entries: [],
                                updatedAt: .now)
        storage[playlist.id] = playlist
        order.append(playlist.id)
        return playlist
    }

    func rename(id: UUID, to name: String) {
        guard var playlist = storage[id] else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlist.name = trimmed
        playlist.updatedAt = .now
        storage[id] = playlist
    }

    func delete(id: UUID) {
        storage.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    @discardableResult
    func add(_ entry: PlaylistEntry, to id: UUID) -> Bool {
        guard var playlist = storage[id] else { return false }
        guard !playlist.entries.contains(entry) else { return false }
        playlist.entries.append(entry)
        playlist.updatedAt = .now
        storage[id] = playlist
        return true
    }

    func remove(_ entry: PlaylistEntry, from id: UUID) {
        guard var playlist = storage[id] else { return }
        playlist.entries.removeAll { $0 == entry }
        playlist.updatedAt = .now
        storage[id] = playlist
    }

    func move(in id: UUID, from: Int, to: Int) {
        guard var playlist = storage[id], playlist.entries.indices.contains(from) else { return }
        let target = max(0, min(playlist.entries.count - 1, to))
        let moved = playlist.entries.remove(at: from)
        playlist.entries.insert(moved, at: target)
        playlist.updatedAt = .now
        storage[id] = playlist
    }

    func entries(in id: UUID) -> [PlaylistEntry] {
        storage[id]?.entries ?? []
    }
}
