import Carbon.HIToolbox
import Foundation

/// 全局快捷键。
///
/// 用 Carbon 的 `RegisterEventHotKey`：这是沙盒应用可用的公开系统接口，
/// 不需要辅助功能授权，也不依赖任何第三方库。系统在 App 不在前台时仍会投递事件。
/// Carbon 的部分 API 已被标记弃用，但 `RegisterEventHotKey` 至今是 macOS 上
/// 唯一无需额外权限的全局热键公开方案，因此保留并在此说明。
@MainActor
final class HotkeyCenter {
    enum Action: UInt32, CaseIterable {
        case toggleInteractive = 1
        case cycleShape = 2
        case toggleVisibility = 3

        /// 持久化用的稳定键名（不要用 rawValue：那是 Carbon 的整数 id）。
        var storageKey: String {
            switch self {
            case .toggleInteractive: return "toggleInteractive"
            case .cycleShape: return "cycleShape"
            case .toggleVisibility: return "toggleVisibility"
            }
        }

        var title: String {
            switch self {
            case .toggleInteractive: return "鼠标穿透"
            case .cycleShape: return "切换形态"
            case .toggleVisibility: return "显示 / 隐藏"
            }
        }
    }

    /// 全进程单例。Carbon 回调是 C 函数指针，无法捕获上下文，只能通过它回到实例。
    static let shared = HotkeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    /// 每个 action 各自的 Carbon 引用。
    ///
    /// 之前用一个数组存所有引用，`unregister(action)` 又把**全部**引用注销掉，
    /// 于是连续注册三个快捷键时，每注册一个就把前面那个静默注销了——
    /// 结果只有最后注册的那个能用（实测 ⌥⌘K / ⌥⌘L 全是死的）。
    private var refsByAction: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    /// 注册快捷键。同一 action 重复注册时先注销旧的。
    @discardableResult
    func register(_ action: Action,
                  keyCode: UInt32,
                  carbonModifiers: UInt32,
                  handler: @escaping @MainActor () -> Void) -> Bool {
        // 只注销这一个 action 的旧绑定，其它快捷键必须保留。
        unregister(action)

        installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x534C5052), id: action.rawValue) // 'SLPR'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }

        refsByAction[action.rawValue] = ref
        handlers[action.rawValue] = handler
        return true
    }

    func unregister(_ action: Action) {
        handlers[action.rawValue] = nil
        if let ref = refsByAction.removeValue(forKey: action.rawValue) {
            UnregisterEventHotKey(ref)
        }
    }

    /// 当前真正注册成功的快捷键数量（供设置界面与测试核对，避免"文档说有、实际没生效"）。
    var registeredActionCount: Int { refsByAction.count }

    func isRegistered(_ action: Action) -> Bool { refsByAction[action.rawValue] != nil }

    func unregisterAll() {
        handlers.removeAll()
        for (_, ref) in refsByAction { UnregisterEventHotKey(ref) }
        refsByAction.removeAll()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let identifier = hotKeyID.id
                Task { @MainActor in
                    HotkeyCenter.shared.fire(identifier)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }
}

/// 常用组合键的 Carbon 修饰符。
enum HotkeyModifiers {
    static let controlOption = UInt32(controlKey) | UInt32(optionKey)
    static let controlOptionShift = controlOption | UInt32(shiftKey)
    static let commandOption = UInt32(cmdKey) | UInt32(optionKey)
}

/// 常用虚拟键码（来自 Carbon 的 kVK_* 常量）。
enum HotkeyKeyCode {
    static let l: UInt32 = 37
    static let k: UInt32 = 40
    static let h: UInt32 = 4
}
