import Foundation
import SwiftData

/// 悬浮歌词窗口的每屏记忆。Phase 3 使用，Phase 0 先建表。
///
/// 之所以在 V1 就建：让它出现在首个发布版本的库里，
/// Phase 3 加字段时走轻量迁移即可，不必处理"表本身是新加的"这一分支。
@Model
final class PlacementRecord {
    @Attribute(.unique) var scopeKey: String
    /// 显示器稳定标识（CGDisplay UUID）。Phase 2 会把它并入 scopeKey，做成"每屏 × 每形态"。
    var displayID: String = ""
    var showsBackground: Bool = true
    var preferredX: Double?
    var preferredY: Double?
    var originX: Double
    var originY: Double
    var width: Double
    var height: Double
    var form: String
    var opacity: Double
    var isClickThrough: Bool
    var isLocked: Bool
    var updatedAt: Date

    init(scopeKey: String,
         originX: Double = 0,
         originY: Double = 0,
         width: Double = 0,
         height: Double = 0,
         form: String = "capsule",
         opacity: Double = 0.85,
         isClickThrough: Bool = true,
         isLocked: Bool = false,
         updatedAt: Date = .now) {
        self.scopeKey = scopeKey
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.form = form
        self.opacity = opacity
        self.isClickThrough = isClickThrough
        self.isLocked = isLocked
        self.updatedAt = updatedAt
    }
}
