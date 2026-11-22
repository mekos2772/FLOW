import XCTest
@testable import SpatialLyricsPlayer

/// 偏好被写坏时的健壮性。
///
/// 真机演练（第 135 节）里往真实偏好塞了字符串/布尔等类型错误的值，App 正常启动。
/// 这里把当时依赖的行为固定成测试：类型不符必须回落默认值，而不是崩或产生 NaN。
final class CorruptedPreferencesTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "flow-corrupt-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testStringWhereNumberExpectedFallsBackToDefault() {
        defaults.set("not-a-number", forKey: "settings.lyricFontSize")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).lyricFontSize, 15,
                       accuracy: 0.001, "类型不符应当回落默认值，而不是 0 或 NaN")
    }

    func testBoolWhereNumberExpectedFallsBackToDefault() {
        defaults.set(true, forKey: "settings.floatingOpacity")
        let value = UserDefaultsSettingsStore(defaults: defaults).floatingOpacity
        XCTAssertTrue(value.isFinite, "不能出现 NaN/无限值")
        XCTAssertGreaterThanOrEqual(value, 0.3)
    }

    func testUnknownEnumRawValueFallsBack() {
        defaults.set("不存在的形态", forKey: "settings.defaultShape")
        let store = UserDefaultsSettingsStore(defaults: defaults)
        // 不崩即可：具体默认值由 LyricsShape 决定
        _ = store.defaultShape

        defaults.set("nonsense", forKey: "settings.lyricLayout")
        _ = store.lyricLayoutRaw
    }

    func testVolumeZeroSurvivesCorruptionOfOtherKeys() {
        defaults.set(0.0, forKey: "settings.engineVolume")
        defaults.set("garbage", forKey: "settings.lyricFontSize")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).engineVolume, 0, accuracy: 0.001)
    }
}
