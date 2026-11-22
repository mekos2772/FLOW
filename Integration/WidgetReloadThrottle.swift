import Foundation

/// 小组件时间线重载的节流决策。
///
/// 抽成纯结构的原因：`WidgetCenter.reloadAllTimelines()` 没法在测试里观察，
/// 而"多久重载一次"正是这轮要修的东西（之前播放时每秒重载一次）。
///
/// 规则：
/// - 曲目/状态/队列身份变化 → **立刻**重载（换歌必须马上反映）；
/// - 只有进度推进 → 最多每 `minimumInterval` 一次；
/// - `force` 无条件放行（启动时同步一次）。
struct WidgetReloadThrottle {
    static let defaultMinimumInterval: TimeInterval = 30

    let minimumInterval: TimeInterval
    private(set) var lastReloadAt: Date = .distantPast
    private(set) var lastIdentity: String = ""

    init(minimumInterval: TimeInterval = WidgetReloadThrottle.defaultMinimumInterval) {
        self.minimumInterval = minimumInterval
    }

    mutating func shouldReload(identity: String, now: Date, force: Bool = false) -> Bool {
        if force {
            lastIdentity = identity
            lastReloadAt = now
            return true
        }
        if identity != lastIdentity {
            lastIdentity = identity
            lastReloadAt = now
            return true
        }
        guard now.timeIntervalSince(lastReloadAt) >= minimumInterval else { return false }
        lastReloadAt = now
        return true
    }
}
