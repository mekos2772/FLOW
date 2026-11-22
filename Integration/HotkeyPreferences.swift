import AppKit
import Carbon.HIToolbox
import Foundation

/// 一个可注册的全局快捷键组合。
///
/// 用 Carbon 的 keyCode + 修饰键表示：`RegisterEventHotKey` 只认这套，
/// 而 NSEvent 直接给的就是 keyCode 与 `ModifierFlags`，中间只差一次换算。
struct HotkeyCombo: Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon 修饰键（`controlKey` / `optionKey` / `cmdKey` / `shiftKey` 的位或）。
    var carbonModifiers: UInt32

    /// 界面上显示的组合（`⌃⌥K`）。
    var display: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        text += Self.keyName(keyCode)
        return text
    }

    /// 至少要有一个「重」修饰键，否则单独一个字母会成为全局热键，把打字全吃掉。
    var isUsable: Bool {
        carbonModifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    /// 把 `NSEvent` 的 keyCode/修饰键换算成 Carbon 表示。
    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init?(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        var carbon: UInt32 = 0
        if modifierFlags.contains(.control) { carbon |= UInt32(controlKey) }
        if modifierFlags.contains(.option) { carbon |= UInt32(optionKey) }
        if modifierFlags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if modifierFlags.contains(.command) { carbon |= UInt32(cmdKey) }
        // 只按 ⇧ 不算：存下去读回来会被判不可用、悄悄退回默认，还把原来的自定义键覆盖掉。
        guard carbon & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        self.init(keyCode: UInt32(keyCode), carbonModifiers: carbon)
    }

    /// 常见键的名字。没收录的按键直接显示 keyCode，总比空着强。
    static func keyName(_ keyCode: UInt32) -> String {
        if let name = names[keyCode] { return name }
        return "键\(keyCode)"
    }

    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 41: ";", 45: "N", 46: "M",
        36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

/// 三个全局快捷键的用户绑定，存在独立的 UserDefaults 键里。
///
/// 没有并进 `SettingsStoring`：那个协议已经有二十多个成员、两套实现，
/// 快捷键只是一小簇键值，单独一个类型更容易测，也不必动协议。
///
/// 没存过就回落到内置默认（三个 `⌃⌥` 组合）。
struct HotkeyPreferences {
    let defaults: UserDefaults
    var suitePrefix = "hotkey."

    init(defaults: UserDefaults = RuntimeSandbox.defaults) {
        self.defaults = defaults
    }

    func combo(for action: HotkeyCenter.Action) -> HotkeyCombo {
        let key = suitePrefix + action.storageKey
        guard let raw = defaults.string(forKey: key),
              let parsed = Self.parse(raw),
              parsed.isUsable else {
            return Self.defaultCombo(for: action)
        }
        return parsed
    }

    func set(_ combo: HotkeyCombo?, for action: HotkeyCenter.Action) {
        let key = suitePrefix + action.storageKey
        guard let combo else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set("\(combo.keyCode):\(combo.carbonModifiers)", forKey: key)
    }

    /// 恢复内置默认。
    func reset(_ action: HotkeyCenter.Action) {
        defaults.removeObject(forKey: suitePrefix + action.storageKey)
    }

    static func defaultsCombo(for action: HotkeyCenter.Action) -> HotkeyCombo { defaultCombo(for: action) }

    private static func defaultCombo(for action: HotkeyCenter.Action) -> HotkeyCombo {
        switch action {
        case .cycleShape: return HotkeyCombo(keyCode: HotkeyKeyCode.k,
                                             carbonModifiers: HotkeyModifiers.controlOption)
        case .toggleInteractive: return HotkeyCombo(keyCode: HotkeyKeyCode.l,
                                                    carbonModifiers: HotkeyModifiers.controlOption)
        case .toggleVisibility: return HotkeyCombo(keyCode: HotkeyKeyCode.h,
                                                   carbonModifiers: HotkeyModifiers.controlOption)
        }
    }

    static func parse(_ raw: String) -> HotkeyCombo? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let code = UInt32(parts[0]),
              let modifiers = UInt32(parts[1]) else { return nil }
        return HotkeyCombo(keyCode: code, carbonModifiers: modifiers)
    }
}
