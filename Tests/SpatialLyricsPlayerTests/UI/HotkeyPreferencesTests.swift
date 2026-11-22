import Carbon.HIToolbox
import XCTest
@testable import SpatialLyricsPlayer

/// 全局快捷键的用户绑定。
final class HotkeyPreferencesTests: XCTestCase {

    private func makeStore() -> HotkeyPreferences {
        let suite = "hotkey.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return HotkeyPreferences(defaults: defaults)
    }

    func testDefaultsAreTheBuiltInCombos() {
        let store = makeStore()
        XCTAssertEqual(store.combo(for: .cycleShape).display, "⌃⌥K")
        XCTAssertEqual(store.combo(for: .toggleInteractive).display, "⌃⌥L")
        XCTAssertEqual(store.combo(for: .toggleVisibility).display, "⌃⌥H")
    }

    func testSavedComboRoundTrips() {
        let store = makeStore()
        let combo = HotkeyCombo(keyCode: HotkeyKeyCode.k,
                                carbonModifiers: UInt32(cmdKey | optionKey))
        store.set(combo, for: .cycleShape)
        XCTAssertEqual(store.combo(for: .cycleShape), combo)
        XCTAssertEqual(store.combo(for: .cycleShape).display, "⌥⌘K")
        // 其它两项不受影响。
        XCTAssertEqual(store.combo(for: .toggleVisibility).display, "⌃⌥H")
    }

    func testResetFallsBackToDefault() {
        let store = makeStore()
        store.set(HotkeyCombo(keyCode: 0, carbonModifiers: UInt32(cmdKey)), for: .cycleShape)
        store.reset(.cycleShape)
        XCTAssertEqual(store.combo(for: .cycleShape).display, "⌃⌥K")
    }

    func testComboWithoutHeavyModifierIsRejected() {
        // 只有 shift 不算：单个字母会成为全局热键，把打字吃掉。
        XCTAssertFalse(HotkeyCombo(keyCode: 0, carbonModifiers: UInt32(shiftKey)).isUsable)
        XCTAssertTrue(HotkeyCombo(keyCode: 0, carbonModifiers: UInt32(optionKey)).isUsable)
    }

    func testCorruptStoredValueFallsBack() {
        let suite = "hotkey.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("not-a-combo", forKey: "hotkey.cycleShape")
        let store = HotkeyPreferences(defaults: defaults)
        XCTAssertEqual(store.combo(for: .cycleShape).display, "⌃⌥K", "坏数据不该让快捷键消失")
    }

    func testDisplayShowsModifierOrderAndKeyName() {
        let combo = HotkeyCombo(keyCode: HotkeyKeyCode.k,
                                carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(combo.display, "⌃⌥⇧⌘K")
    }
}
