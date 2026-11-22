import CoreGraphics
import Foundation

/// 辅助功能权限四态。
enum AccessibilityPermission: String, Sendable, Equatable {
    case unknown
    case notGranted
    case granted
    case unavailable   // 系统不支持或查询失败

    var allowsWindowInspection: Bool { self == .granted }
}

/// 前台应用信息。只保存做决策必需的字段，不保存任何窗口标题/文档内容。
struct FrontmostAppInfo: Sendable, Equatable {
    let bundleID: String?
    let name: String
    let isFullscreen: Bool
}

/// 桌面空间快照。空间求解的唯一输入，不含任何窗口对象，因此可以被纯函数处理与测试。
struct SpatialSnapshot: Sendable, Equatable {
    let displayID: String
    let safeZone: CGRect
    let screenFrame: CGRect
    /// 已过滤的障碍物（安全区坐标系，AppKit 左下原点）。
    let obstacles: [CGRect]
    let frontmostApp: FrontmostAppInfo?
    let floatingFrame: CGRect?
    let preferredSize: CGSize
    let currentShape: LyricsShape
    /// 用户手动位置记忆（归一化到 0...1 的安全区比例），没有则为 nil。
    let userPreferredOrigin: CGPoint?
    let isLocked: Bool
    let permission: AccessibilityPermission
}

/// 求解结果。
struct PlacementDecision: Sendable, Equatable {
    var frame: CGRect
    var shape: LyricsShape
    /// 为什么这么放，用于日志与调试面板。
    var reason: PlacementReason
    /// 是否应当隐藏悬浮歌词（全屏等场景）。
    var shouldHide: Bool

    enum PlacementReason: String, Sendable {
        case keepCurrent      // 保持现状
        case solved           // 找到更优解
        case clamped          // 只做了安全区钳制
        case locked           // 用户锁定，只做可见性修复
        case fallbackEdge     // 无合法候选，贴最近边
        case hidden           // 全屏或无处可放
    }
}
