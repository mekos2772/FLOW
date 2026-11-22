import Foundation

/// 会议模式策略（P1，规格 13.3）：当指定的会议应用进入前台时，把歌名与歌词遮起来。
///
/// 只做纯判断，不去观察 `NSWorkspace`——观察由 `PrivacyState` 负责注入前台 bundle id。
/// 这样"什么时候该遮"能用纯测试固定下来，不必真的打开 Zoom。
struct MeetingModePolicy: Equatable, Sendable {
    var isEnabled: Bool
    var bundleIdentifiers: Set<String>

    static let disabled = MeetingModePolicy(isEnabled: false, bundleIdentifiers: [])

    /// 常见会议应用的 bundle id。
    ///
    /// 这个功能（规格 13.3）此前**完全无法启用**：策略与遮罩都写好了，
    /// 但没有内置清单、界面上也没有地方填，`meetingAppsRaw` 永远是空串，
    /// 于是"会议时隐藏歌名与歌词"从未生效过。
    static let defaultBundleIdentifiers: Set<String> = [
        "us.zoom.xos",                                  // Zoom
        "com.tencent.meeting",                          // 腾讯会议
        "com.microsoft.teams2",                         // Microsoft Teams
        "com.microsoft.teams",                          // Microsoft Teams（旧）
        "com.bytedance.macos.feishu",                   // 飞书
        "com.alibaba.DingTalkMac",                      // 钉钉
        "com.apple.FaceTime",                           // FaceTime
        "com.webex.meetingmanager",                     // Webex
    ]

    /// 用内置清单构造一个已启用的策略。
    static var `default`: MeetingModePolicy {
        MeetingModePolicy(isEnabled: true, bundleIdentifiers: defaultBundleIdentifiers)
    }

    /// 当前前台应用是否应当触发遮罩。
    func shouldMask(frontmostBundleID: String?) -> Bool {
        guard isEnabled, let frontmostBundleID, !frontmostBundleID.isEmpty else { return false }
        return bundleIdentifiers.contains(frontmostBundleID)
    }
}
