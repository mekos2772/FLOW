import Foundation

/// 淡入淡出的音量曲线（P1）。纯函数，不碰播放器，方便用数值断言验证。
///
/// 采用线性插值而不是指数曲线：人耳对音量是对数感知，线性听起来"前快后慢"，
/// 但淡入淡出的时长只有几百毫秒，线性足够且不会有尾巴拖长的听感问题。
enum FadeRamp {

    /// 生成从 `from` 到 `to` 的等分音量序列，**含起点与终点**。
    /// `steps` 是区间数，返回 `steps + 1` 个值。
    static func volumes(from: Float, to: Float, steps: Int) -> [Float] {
        let segments = max(1, steps)  // 至少一段，保证返回首尾两个值
        return (0...segments).map { index in
            // 首尾直接返回端点值：浮点插值在终点会算出 0.19999999，
            // 既过不了精确断言，用户看到的音量也会差一点点。
            if index == 0 { return min(max(from, 0), 1) }
            if index == segments { return min(max(to, 0), 1) }
            let t = Float(index) / Float(segments)
            let value = from + (to - from) * t
            return min(max(value, 0), 1)  // 音量离开 0...1 会被引擎截断，这里先夹紧
        }
    }

    /// 按固定间隔把总时长切成若干段。间隔非法或时长为零时退化为 1 段（直接跳到目标音量）。
    static func stepCount(duration: Duration, interval: Duration) -> Int {
        let total = duration.timeInterval
        let step = interval.timeInterval
        guard total > 0, step > 0 else { return 1 }
        return max(1, Int((total / step).rounded(.up)))
    }
}
