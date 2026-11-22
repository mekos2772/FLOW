import Foundation
import SwiftData

/// 队列快照。
///
/// 整队列序列化成 JSON 存一列，而不是把 items/nextUp/later 拆成多列：
/// 队列是"整体语义"的数据，拆列会让每次改队列结构都要动 schema 与迁移；
/// 整体存储只需要保证 `PlaybackQueue` 自身 Codable 可演进（缺字段用默认值兜底）。
@Model
final class QueueRecord {
    @Attribute(.unique) var slot: String
    var payload: Data
    var updatedAt: Date

    init(slot: String = "main", payload: Data, updatedAt: Date = .now) {
        self.slot = slot
        self.payload = payload
        self.updatedAt = updatedAt
    }
}

extension QueueRecord {
    convenience init(_ queue: PlaybackQueue, encoder: JSONEncoder = JSONEncoder()) {
        self.init(payload: (try? encoder.encode(queue)) ?? Data())
    }

    func asQueue(decoder: JSONDecoder = JSONDecoder()) -> PlaybackQueue {
        (try? decoder.decode(PlaybackQueue.self, from: payload)) ?? PlaybackQueue()
    }
}
