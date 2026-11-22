import Foundation

/// 时长的显示格式。**全工程只此一处**。
///
/// 之前有两份几乎相同的实现（完整播放器、B 站搜索页），而且**都漏了一小时以上的情况**：
/// 3600 秒会显示成 `60:00`，而不是 `1:00:00`。B 站的直播回放、播客、DJ set
/// 动辄一两个小时，这个错误在真实内容里很常见。
///
/// 两份实现还有一处不一致：一份把 0 显示成 `0:00`，另一份显示 `--:--`。
enum DurationText {
    /// 歌词偏移量的显示：`0 ms` / `+250 ms` / `-120 ms`。
    ///
    /// 两处界面（设置页、队列抽屉）原本各写了一遍同样的格式化，
    /// 和当年 `clock` 的情况一样——统一到这里，只有一处需要维护。
    static func offset(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0 ms" }
        let ms = Int((seconds * 1000).rounded())
        return ms == 0 ? "0 ms" : String(format: "%+d ms", ms)
    }

    /// - Parameter seconds: 秒。负数 / 非有限值返回 `--:--`。
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
