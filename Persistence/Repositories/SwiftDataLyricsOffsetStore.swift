import Foundation
import SwiftData

@ModelActor
actor SwiftDataLyricsOffsetStore: LyricsOffsetStoring {
    func offset(for identity: TrackIdentity) async -> TimeInterval {
        let stored = storedOffset(for: identity)
        return stored.isFinite ? stored : 0
    }

    private func storedOffset(for identity: TrackIdentity) -> TimeInterval {
        let key = Self.key(for: identity)
        var descriptor = FetchDescriptor<LyricsOffsetRecord>(
            predicate: #Predicate { $0.trackIdentityKey == key }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor).first?.offset) ?? 0
    }

    func save(_ offset: TimeInterval, for identity: TrackIdentity) async {
        // 非有限值一律不写：偏移量一旦是 NaN，歌词时间轴的比较全部失效
        // （`time > NaN` 永远为假），表现为"歌词卡住不动"，且很难联想到这里。
        guard offset.isFinite else { return }
        let key = Self.key(for: identity)
        var descriptor = FetchDescriptor<LyricsOffsetRecord>(
            predicate: #Predicate { $0.trackIdentityKey == key }
        )
        descriptor.fetchLimit = 1

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.offset = offset
            existing.updatedAt = .now
        } else {
            modelContext.insert(LyricsOffsetRecord(trackIdentityKey: key, offset: offset))
        }
        try? modelContext.save()
    }

    func remove(for identity: TrackIdentity) async {
        let key = Self.key(for: identity)
        try? modelContext.delete(model: LyricsOffsetRecord.self,
                                 where: #Predicate { $0.trackIdentityKey == key })
        try? modelContext.save()
    }

    func all() async -> [TrackIdentity: TimeInterval] {
        let records = (try? modelContext.fetch(FetchDescriptor<LyricsOffsetRecord>())) ?? []
        var result: [TrackIdentity: TimeInterval] = [:]
        for record in records {
            guard let identity = Self.identity(from: record.trackIdentityKey) else { continue }
            result[identity] = record.offset
        }
        return result
    }

    static func key(for identity: TrackIdentity) -> String {
        "\(identity.sourceID.rawValue)::\(identity.externalID)"
    }

    static func identity(from key: String) -> TrackIdentity? {
        TrackIdentity.fromStorageKey(key)
    }
}
