import Foundation

/// 表现层操作悬浮歌词的唯一入口。
///
/// 主窗口、菜单栏、快捷键都只调这个协议，拿不到 NSPanel，也拿不到放置算法。
@MainActor
protocol FloatingLyricsControlling: AnyObject {
    var isVisible: Bool { get }
    var shape: LyricsShape { get }
    var isInteractive: Bool { get }
    var isLocked: Bool { get }
    /// 辅助功能授权状态。未授权时智能避让关闭，其余功能照常。
    var accessibilityPermission: AccessibilityPermission { get }

    func start()
    func show()
    func hide()
    func toggleVisibility()
    func setShape(_ shape: LyricsShape)
    func cycleShape()
    func toggleInteractive()
    func toggleLock()
    func resetToDefaultPosition()
    /// 设置页改字号后立即生效，不必重启。
    func applyLyricFontSize(_ size: Double)
    /// 行距同理：改完立即生效。
    func applyLyricLineSpacing(_ spacing: Double)
    /// 外文歌双语对照译文开关：改完立即生效。
    func applyShowLyricTranslation(_ enabled: Bool)
    /// 自动避让前台窗口开关，改完立即重新求解。
    func applyAutoAvoid(_ enabled: Bool)
    /// 清空位置记忆并回到默认形态/默认位置（规格 6.4「恢复默认布局」）。
    func resetPlacementMemory() async
    /// 用户主动请求辅助功能授权（只弹一次系统引导）。
    func requestAccessibilityPermission()
    /// 只查询、不弹窗。设置页进入"权限"分页时调用，
    /// 让用户刚在系统设置里授权完回来就能看到状态变化。
    func refreshAccessibilityPermission()
}
