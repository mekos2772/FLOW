import AppKit
import CoreGraphics
import Foundation

/// 动效时长的计算规则。
///
/// 关键点：动画必须**与刷新率无关**。
/// 位置按"已用时间 × 曲线"算出，所以 240Hz 屏天然会得到 240 帧/秒；
/// 而 60Hz 屏如果只给 0.18s，就只剩 11 帧——想不卡都难。
/// 因此时长不写死，而是由**帧数下限**反推：`max(基准时长, 帧数下限 / 刷新率)`。
/// 这样 60Hz 屏会自然放慢到够帧，240Hz 屏则按原速跑满。
struct MotionTiming: Sendable, Equatable {
    /// 一段过渡至少要呈现多少个**离散位置**。
    ///
    /// 这是"帧数"的实际含义：60Hz 屏最多出 60 帧/秒，想更多只能把动作拉长。
    /// 30 帧在 60Hz 上约 500ms，每帧位移更小——不只是数着更顺，
    /// 远程/录屏这类按"变化区域"编码的链路也更容易跟上（每帧脏区更小）。
    /// 240Hz 屏上基准时长本身已远超此值，因此不会被人为拖慢。
    var minimumFrames: Int = 30
    /// 兜底刷新率：拿不到屏幕信息时按 60Hz 估。
    var fallbackRefreshRate: Double = 60

    /// 读取屏幕刷新率。返回 0 表示未知。
    ///
    /// 两路来源：`NSScreen.maximumFramesPerSecond` 最准；某些虚拟/远程显示器
    /// 这一步会给 0，于是回落到 `CGDisplayCopyDisplayMode` 的当前模式刷新率。
    static func refreshRate(for screen: NSScreen?) -> Double {
        if let override = ProcessInfo.processInfo.environment["SLP_REFRESH_RATE"],
           let value = Double(override), value > 0 {
            return value
        }
        guard let screen else { return 0 }
        let reported = Double(screen.maximumFramesPerSecond)
        if reported > 0 { return reported }
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let mode = CGDisplayCopyDisplayMode(CGDirectDisplayID(number.uint32Value)) else { return 0 }
        let modeRate = Double(mode.refreshRate)
        return modeRate > 0 ? modeRate : 0
    }

    /// 把基准时长抬到"至少 minimumFrames 帧"。
    ///
    /// **零时长原样返回**：那代表"减少动态效果"或测试态，语义是不要动画。
    /// 若也被抬到下限，减少动态效果就失效了（用户开了它，界面却还在慢慢动）。
    func resolve(base: Duration, refreshRate: Double) -> Duration {
        let baseSeconds = Self.seconds(base)
        guard baseSeconds > 0 else { return .zero }
        let rate = refreshRate > 0 ? refreshRate : fallbackRefreshRate
        let minimumSeconds = Double(minimumFrames) / rate
        return .seconds(max(baseSeconds, minimumSeconds))
    }

    /// 按距离给出基准时长：近处利落，远处多给一点，但仍在同一量级。
    func baseDuration(distance: CGFloat, diagonal: CGFloat) -> Duration {
        let fraction = min(max(distance / max(diagonal, 1), 0), 1)
        return .seconds(0.22 + Double(fraction) * 0.16)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
