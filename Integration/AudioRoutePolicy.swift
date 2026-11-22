import Foundation

/// 输出设备变化时是否该暂停（P1「耳机拔出暂停」）。
///
/// 纯判断，不碰 CoreAudio：设备监听的实现负责把"变化前后的设备"翻译成这里的枚举，
/// 这样"拔耳机该不该暂停"能用测试固定下来，不必真的插拔一次。
struct AudioRoutePolicy: Equatable, Sendable {
    enum OutputKind: Equatable, Sendable {
        case headphones     // 有线耳机 / 蓝牙耳机
        case builtInSpeaker // 内置扬声器或外接音箱
        case other          // AirPlay、虚拟声卡等，无法可靠判定
    }

    /// 是否在"从耳机切到非耳机"时自动暂停。
    var pauseOnHeadphoneUnplug: Bool

    static let disabled = AudioRoutePolicy(pauseOnHeadphoneUnplug: false)

    /// - Parameters:
    ///   - previous: 变化前的默认输出设备类型；首次读取时为 nil。
    ///   - current: 变化后的默认输出设备类型。
    func shouldPause(previous: OutputKind?, current: OutputKind) -> Bool {
        guard pauseOnHeadphoneUnplug else { return false }
        guard previous == .headphones, current != .headphones else { return false }
        return true
    }
}
