import AppKit
import Foundation
import Observation

/// 隐私模式。开启后主窗口、悬浮歌词、小组件都不再展示歌名与歌词。
///
/// 单一开关、单一状态：不在各自视图里再存一份布尔量，避免"主窗口隐藏了但悬浮窗没隐藏"。
@MainActor
@Observable
final class PrivacyState {
    private(set) var isEnabled: Bool
    /// 会议应用是否已进入前台。与 `isEnabled` 分开存：
    /// 手动开关是用户的意愿，会议检测是环境事实，两者都要能独立观察。
    private(set) var isMaskedByMeetingApp = false
    private(set) var meetingPolicy = MeetingModePolicy.disabled
    /// 会议应用名单原文（逗号分隔 bundle id）。空串表示不启用。
    private(set) var meetingAppsRaw: String
    private let settings: any SettingsStoring

    init(settings: any SettingsStoring) {
        self.settings = settings
        self.isEnabled = settings.isPrivacyMode
        self.meetingAppsRaw = settings.meetingAppsRaw
    }

    /// 遮罩状态变化时通知谁。
    ///
    /// 系统"正在播放"、小组件、悬浮歌词都是**推**出去的内容：遮罩一变就得立刻重推，
    /// 不能等下一次播放状态变化——那可能是几个小时以后。
    var onMaskingChanged: [@MainActor () -> Void] = []

    private func notifyIfMaskingChanged(from old: Bool) {
        guard old != isMasking else { return }
        for observer in onMaskingChanged { observer() }
    }

    func setEnabled(_ value: Bool) {
        let before = isMasking
        isEnabled = value
        Task { [settings] in await settings.setPrivacyMode(value) }
        notifyIfMaskingChanged(from: before)
    }

    func toggle() { setEnabled(!isEnabled) }

    /// 实际上是否要遮住内容：手动开关或会议应用在前台，任一成立即遮。
    var isMasking: Bool { isEnabled || isMaskedByMeetingApp }

    /// 写入会议应用名单并立即生效。逗号或换行分隔都能识别。
    func setMeetingApps(_ raw: String) {
        meetingAppsRaw = raw
        let ids = raw.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        setMeetingPolicy(MeetingModePolicy(isEnabled: !ids.isEmpty, bundleIdentifiers: Set(ids)))
        Task { [settings] in await settings.setMeetingAppsRaw(raw) }
    }

    /// 启动时用已保存的名单初始化策略。
    ///
    /// 名单为空 = 用户没开这个功能（或旧版本从未写过）。此时**不**自动填充内置清单，
    /// 因为"自动隐藏歌名"是显式隐私选择，不能替用户打开。
    func loadMeetingApps() { setMeetingApps(meetingAppsRaw) }

    /// 导入设置备份后重新读取隐私开关与会议名单（构造时只读过一次）。
    func reloadFromStore() {
        let before = isMasking
        isEnabled = settings.isPrivacyMode
        meetingAppsRaw = settings.meetingAppsRaw
        loadMeetingApps()
        notifyIfMaskingChanged(from: before)
    }

    /// 会议模式开关（界面用）。
    ///
    /// 打开时写入内置的常见会议应用清单，关闭时写空串——
    /// 这样不必另开一个设置键，备份/恢复也自动覆盖（`meetingAppsRaw` 已在里面）。
    var isMeetingModeEnabled: Bool { !meetingPolicy.bundleIdentifiers.isEmpty }

    func setMeetingModeEnabled(_ enabled: Bool) {
        if enabled {
            setMeetingApps(MeetingModePolicy.defaultBundleIdentifiers.sorted().joined(separator: ","))
        } else {
            setMeetingApps("")
        }
    }

    func setMeetingPolicy(_ policy: MeetingModePolicy) {
        meetingPolicy = policy
        refreshMeetingMask()
    }

    /// `NSWorkspace` 前台应用变化时调用。传 nil 表示当前无法判定（例如屏幕锁定）。
    func updateFrontmost(bundleID: String?) {
        refreshMeetingMask(bundleID: bundleID)
    }

    private func refreshMeetingMask(bundleID: String? = nil) {
        let front = bundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let before = isMasking
        isMaskedByMeetingApp = meetingPolicy.shouldMask(frontmostBundleID: front)
        notifyIfMaskingChanged(from: before)
    }

    /// 隐私模式下对外展示的标题。
    func sanitize(_ title: String) -> String {
        isMasking ? "正在播放" : title
    }
}
