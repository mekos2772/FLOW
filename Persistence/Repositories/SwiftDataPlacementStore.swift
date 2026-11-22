import Foundation
import SwiftData

/// 悬浮位置的 SwiftData 实现。
///
/// 用 SwiftData 而不是 UserDefaults，是因为它和其它领域数据（曲目、队列、偏移）
/// 共享同一个 schema 与迁移链，Phase 2 要按显示器 × 形态存多份偏好时只加字段即可。
@ModelActor
actor SwiftDataPlacementStore: PlacementStoring {
    private static let scopeKey = "floating-main"

    func load() async -> PlacementSnapshot? {
        var descriptor = FetchDescriptor<PlacementRecord>(
            predicate: #Predicate { $0.scopeKey == "floating-main" }
        )
        descriptor.fetchLimit = 1
        guard let record = try? modelContext.fetch(descriptor).first else { return nil }
        return PlacementSnapshot(
            displayID: record.displayID,
            originX: record.originX,
            originY: record.originY,
            width: record.width,
            height: record.height,
            shape: LyricsShape(rawValue: record.form) ?? .capsule,
            isLocked: record.isLocked,
            isClickThrough: record.isClickThrough,
            opacity: record.opacity,
            showsBackground: record.showsBackground,
            preferredX: record.preferredX,
            preferredY: record.preferredY
        ).sanitized()
    }

    func save(_ snapshot: PlacementSnapshot) async {
        var descriptor = FetchDescriptor<PlacementRecord>(
            predicate: #Predicate { $0.scopeKey == "floating-main" }
        )
        descriptor.fetchLimit = 1

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.displayID = snapshot.displayID
            existing.originX = snapshot.originX
            existing.originY = snapshot.originY
            existing.width = snapshot.width
            existing.height = snapshot.height
            existing.form = snapshot.shape.rawValue
            existing.isLocked = snapshot.isLocked
            existing.isClickThrough = snapshot.isClickThrough
            existing.opacity = snapshot.opacity
            existing.showsBackground = snapshot.showsBackground
            existing.preferredX = snapshot.preferredX
            existing.preferredY = snapshot.preferredY
            existing.updatedAt = .now
        } else {
            let record = PlacementRecord(
                scopeKey: Self.scopeKey,
                originX: snapshot.originX,
                originY: snapshot.originY,
                width: snapshot.width,
                height: snapshot.height,
                form: snapshot.shape.rawValue,
                opacity: snapshot.opacity,
                isClickThrough: snapshot.isClickThrough,
                isLocked: snapshot.isLocked
            )
            record.displayID = snapshot.displayID
            record.showsBackground = snapshot.showsBackground
            record.preferredX = snapshot.preferredX
            record.preferredY = snapshot.preferredY
            modelContext.insert(record)
        }
        try? modelContext.save()
    }

    func clear() async {
        try? modelContext.delete(model: PlacementRecord.self)
        try? modelContext.save()
    }
}
