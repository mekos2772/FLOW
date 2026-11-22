import CoreAudio
import Foundation

/// 监听默认输出设备变化，按 `AudioRoutePolicy` 决定是否暂停（P1「耳机拔出暂停」）。
///
/// 分类依据：`kAudioDevicePropertyTransportType`；内置输出再读 `kAudioDevicePropertyDataSource`
/// 判断是不是耳机口（四字符码 `hdpn`）。判定不了的一律归为 `.other`——
/// 宁可漏暂停，也不要在用户切到 AirPlay 时突然没声音。
@MainActor
final class AudioRouteMonitor {
    private let playback: any PlaybackControlling
    private var policy: AudioRoutePolicy
    private var previousKind: AudioRoutePolicy.OutputKind?
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    init(playback: any PlaybackControlling, policy: AudioRoutePolicy) {
        self.playback = playback
        self.policy = policy
    }

    func setPolicy(_ policy: AudioRoutePolicy) { self.policy = policy }

    func start() {
        previousKind = Self.currentOutputKind()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleDeviceChange() }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(systemObject, &address, DispatchQueue.main, block)
    }

    func stop() {
        guard let listenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(systemObject, &address, DispatchQueue.main, listenerBlock)
        self.listenerBlock = nil
    }

    private func handleDeviceChange() {
        let current = Self.currentOutputKind()
        let previous = previousKind
        previousKind = current
        guard policy.shouldPause(previous: previous, current: current) else { return }
        Task { await playback.pause() }
    }

    /// 读取当前默认输出设备并归类。失败返回 `.other`。
    static func currentOutputKind() -> AudioRoutePolicy.OutputKind {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return .other }

        var transport: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        var tAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &tAddress, 0, nil, &tSize, &transport) == noErr else {
            return .other
        }

        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .headphones
        case kAudioDeviceTransportTypeBuiltIn:
            return isHeadphoneJack(deviceID) ? .headphones : .builtInSpeaker
        case kAudioDeviceTransportTypeUSB:
            return .other  // USB 可能是声卡也可能是耳机，判定不了就不猜
        default:
            return .other
        }
    }

    /// 内置输出再问一次数据源：四字符码 `hdpn` 表示耳机口。
    private static func isHeadphoneJack(_ deviceID: AudioDeviceID) -> Bool {
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &source) == noErr else {
            return false
        }
        return source == Self.fourCharCode("hdpn")
    }

    /// 四字码按大端拼成 UInt32。
    ///
    /// 改成 internal 是为了能测：字节序写反时 `hdpn` 比较会静默失败，
    /// 表现为"拔了耳机却不暂停"——从界面上完全看不出来。
    static func fourCharCode(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) + UInt32($1) }
    }
}
