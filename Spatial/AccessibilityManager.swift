import AppKit
import Foundation

/// 辅助功能权限管理。
///
/// 三个约束写在这里，避免散落到调用方：
/// 1. 只在用户主动请求时提示一次，不重复弹窗骚扰；
/// 2. 未授权时返回 `.notGranted`，调用方据此关闭"基于他人窗口的避让"，其余功能照常；
/// 3. 权限变化通过 `onChange` 通知，方便把避让能力从关闭状态恢复。
@MainActor
final class AccessibilityManager {
    private(set) var permission: AccessibilityPermission = .unknown
    private(set) var hasPrompted = false
    /// 权限来源。默认走系统 API；测试可注入，用来验证"未授权时的降级行为"。
    private let isTrusted: () -> Bool

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.isTrusted = isTrusted
    }

    var onChange: ((AccessibilityPermission) -> Void)?

    /// 上次真正查询系统的时刻，用于节流。
    private var lastQueryAt: ContinuousClock.Instant?
    /// 节流间隔：权限状态不会一秒一变，但 `obstacles(for:)` 每 2 秒就要问一次。
    private let queryInterval: Duration = .seconds(10)

    /// 节流版只读查询。
    ///
    /// `AXIsProcessTrusted()` 每次调用都会产生一次 TCC IPC——实测每 2 秒一条
    /// `TCCAccessRequest()`，日志被刷满，也没有必要。这里按 `queryInterval` 限频，
    /// 首次（`permission == .unknown`）仍然立刻问。
    @discardableResult
    func refreshIfStale(now: ContinuousClock.Instant = ContinuousClock().now) -> AccessibilityPermission {
        if permission != .unknown, let last = lastQueryAt, now < last.advanced(by: queryInterval) {
            return permission
        }
        lastQueryAt = now
        return refresh()
    }

    /// 只查询，不弹窗。
    @discardableResult
    func refresh() -> AccessibilityPermission {
        lastQueryAt = ContinuousClock().now
        let granted = isTrusted()
        let newValue: AccessibilityPermission = granted ? .granted : .notGranted
        if newValue != permission {
            permission = newValue
            onChange?(newValue)
        }
        return newValue
    }

    /// 用户主动点了"授权"才弹系统引导，且每次启动最多一次。
    @discardableResult
    func requestIfNeeded() -> AccessibilityPermission {
        if permission.allowsWindowInspection { return .granted }
        guard !hasPrompted else { return refresh() }
        hasPrompted = true

        // 键名与 kAXTrustedCheckOptionPrompt 的字面值相同；直接写字面量避免引用全局可变 CFString。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        permission = granted ? .granted : .notGranted
        onChange?(permission)
        return permission
    }
}
