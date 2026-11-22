import AppIntents
import Foundation

/// 小组件上的播放控制。
///
/// `openAppWhenRun = true`：命令必须落到真实播放器，而小组件进程没有播放器。
/// 系统会拉起主 App，命令写入共享存储后由 `WidgetCommandBridge` 执行。
struct TogglePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "播放/暂停"
    static let openAppWhenRun: Bool = true

    /// 这个按钮要下发的命令。抽成属性是为了**可测**：
    /// 直接测 `perform()` 会写进使用者的真实偏好，而映射本身最容易写错
    /// （复制粘贴忘记改名 → "下一首"按钮发的是"播放/暂停"）。
    var command: PlaybackCommand { .toggle }

    func perform() async throws -> some IntentResult {
        SharedStateStore.post(command)
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "下一首"
    static let openAppWhenRun: Bool = true

    var command: PlaybackCommand { .next }

    func perform() async throws -> some IntentResult {
        SharedStateStore.post(command)
        return .result()
    }
}
