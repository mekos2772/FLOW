import Foundation

/// 悬浮歌词不透明度的取值规则。
///
/// 之所以单独抽出来：这个值同时决定窗口淡入终点和实时透明度，
/// 两处若各写一遍 `min(max(...))`，改下限时很容易只改一处。
enum LyricsOpacity {
    /// 下限 0.3：再低歌词就看不清了，用户以为坏了。上限 1.0：窗口不能再比不透明更不透明。
    static let range: ClosedRange<Double> = 0.3...1.0

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }    // 配置被写坏时退回不透明，而不是给出 NaN
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
