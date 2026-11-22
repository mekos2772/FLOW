import Foundation

/// 悬浮歌词的位置与形态快照。
///
/// 用显示器稳定标识作为键，而不是数组下标或屏幕坐标——
/// 插拔显示器后下标会变，坐标会失效，只有 UUID 稳定。
struct PlacementSnapshot: Codable, Sendable, Equatable {
    var displayID: String
    var originX: Double
    var originY: Double
    /// 记录当时的窗口尺寸。
    ///
    /// **不是权威值**：恢复位置时尺寸一律取自 `shape.preferredSize`
    /// （见 `MorphWindowController.restore(_:)`）——面板尺寸由形态决定，
    /// 用户不能自由拉伸。这两个字段只作为现场记录保留，
    /// 别拿它们去 `setFrame`，否则会和形态尺寸打架。
    var width: Double
    var height: Double
    var shape: LyricsShape
    var isLocked: Bool
    var isClickThrough: Bool
    var opacity: Double
    var showsBackground: Bool
    /// 用户手动位置的归一化坐标（0...1，相对安全区）。自动布局以此为偏好中心。
    var preferredX: Double?
    var preferredY: Double?
}

extension PlacementSnapshot {
    /// 清洗脏数据。
    ///
    /// 位置是**唯一会直接决定窗口几何**的持久化数据：
    /// - 坐标是 NaN 时，AppKit 的 frame 运算结果不可预期；
    /// - 尺寸是 0 或负数时，面板会缩成看不见的一条，用户以为 App 坏了；
    /// - 透明度越界时，面板可能完全透明。
    ///
    /// 这些值正常路径不会产生，但数据库被外部改过、或者旧版本写坏过都可能出现。
    /// 读出来先清洗，比让用户面对一个"看不见的播放器"要好。
    func sanitized() -> PlacementSnapshot {
        var copy = self
        func finite(_ value: Double, fallback: Double) -> Double {
            value.isFinite ? value : fallback
        }
        copy.originX = finite(originX, fallback: 0)
        copy.originY = finite(originY, fallback: 0)
        let minSize = FloatingLyricMetrics.minCardSize
        copy.width = min(max(finite(width, fallback: Double(minSize.width)),
                             Double(minSize.width)), 4000)
        copy.height = min(max(finite(height, fallback: Double(minSize.height)),
                              Double(minSize.height)), 4000)
        copy.opacity = min(max(finite(opacity, fallback: 1), 0.3), 1)
        copy.preferredX = preferredX.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        copy.preferredY = preferredY.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        return copy
    }
}

protocol PlacementStoring: Sendable {
    func load() async -> PlacementSnapshot?
    func save(_ snapshot: PlacementSnapshot) async
    func clear() async
}
