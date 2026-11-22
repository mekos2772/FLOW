import Foundation
import SwiftData

@ModelActor
actor SwiftDataLibraryStore: LibraryStoring {
    private static let historyLimit = 200

    func recordPlayed(_ identity: TrackIdentity, at date: Date = .now) async {
        let key = "\(Self.identityKey(identity))#\(Int(date.timeIntervalSince1970 * 1000))"
        modelContext.insert(HistoryRecord(key: key, trackIdentityKey: Self.identityKey(identity), playedAt: date))
        try? modelContext.save()
        await trimHistory()
    }

    func recent(limit: Int = 50) async -> [TrackIdentity] {
        var descriptor = FetchDescriptor<HistoryRecord>(
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        let records = (try? modelContext.fetch(descriptor)) ?? []

        var seen = Set<String>()
        var result: [TrackIdentity] = []
        for record in records {
            guard !seen.contains(record.trackIdentityKey) else { continue }
            seen.insert(record.trackIdentityKey)
            if let identity = Self.identity(from: record.trackIdentityKey) {
                result.append(identity)
            }
        }
        return result
    }

    func toggleFavorite(_ identity: TrackIdentity) async -> Bool {
        let key = Self.identityKey(identity)
        var descriptor = FetchDescriptor<FavoriteRecord>(
            predicate: #Predicate { $0.trackIdentityKey == key }
        )
        descriptor.fetchLimit = 1

        if let existing = try? modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
            try? modelContext.save()
            return false
        }
        modelContext.insert(FavoriteRecord(trackIdentityKey: key))
        try? modelContext.save()
        return true
    }

    func favorites() async -> [TrackIdentity] {
        let records = (try? modelContext.fetch(
            FetchDescriptor<FavoriteRecord>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)])
        )) ?? []
        return records.compactMap { Self.identity(from: $0.trackIdentityKey) }
    }

    func isFavorite(_ identity: TrackIdentity) async -> Bool {
        let key = Self.identityKey(identity)
        var descriptor = FetchDescriptor<FavoriteRecord>(
            predicate: #Predicate { $0.trackIdentityKey == key }
        )
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetch(descriptor).count) ?? 0) > 0
    }

    func clearHistory() async {
        try? modelContext.delete(model: HistoryRecord.self)
        try? modelContext.save()
    }

    private func trimHistory() async {
        let descriptor = FetchDescriptor<HistoryRecord>(
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )
        guard let all = try? modelContext.fetch(descriptor), all.count > Self.historyLimit else { return }
        for record in all[Self.historyLimit...] {
            modelContext.delete(record)
        }
        try? modelContext.save()
    }

    static func identityKey(_ identity: TrackIdentity) -> String {
        "\(identity.sourceID.rawValue)::\(identity.externalID)"
    }

    static func identity(from key: String) -> TrackIdentity? {
        TrackIdentity.fromStorageKey(key)
    }
}
