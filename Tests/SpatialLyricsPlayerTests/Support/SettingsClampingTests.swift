import XCTest
@testable import SpatialLyricsPlayer

/// 设置值的钳制与"缺省 vs 零"的区分。
///
/// 审阅发现一个**影响真实体验**的 bug：
/// 旧实现用 `value == 0 ? 默认值 : value` 判断"没设置过"，
/// 而 `engineVolume` 把 0 当成"没设置"，返回 **1.0（满音量）**。
/// 也就是：用户把音量拉到 0，重启后变成最大声。
final class SettingsClampingTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "flow-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func store() -> UserDefaultsSettingsStore {
        UserDefaultsSettingsStore(defaults: defaults)
    }

    // MARK: - 音量：0 必须保持 0

    func testZeroVolumeIsPreserved() {
        defaults.set(0.0, forKey: "settings.engineVolume")
        XCTAssertEqual(store().engineVolume, 0, accuracy: 0.001,
                       "0 是合法音量（静音），不能被当成「没设置」重置成满音量")
    }

    /// 全新用户首启默认音量不是满音量：100% 会吓到戴耳机的人。
    /// 0.7 是 Spotify/Apple Music 的开箱默认水位。
    func testAbsentVolumeFallsBackToSafeDefault() {
        XCTAssertEqual(store().engineVolume, 0.7, accuracy: 0.001)
    }

    func testOutOfRangeVolumeIsClamped() {
        defaults.set(3.5, forKey: "settings.engineVolume")
        XCTAssertEqual(store().engineVolume, 1, accuracy: 0.001)

        defaults.set(-2.0, forKey: "settings.engineVolume")
        XCTAssertEqual(store().engineVolume, 0, accuracy: 0.001)
    }

    // MARK: - 透明度 / 字号 / 行距

    func testOpacityIsClampedAndKeepsValidValues() {
        defaults.set(0.5, forKey: "settings.floatingOpacity")
        XCTAssertEqual(store().floatingOpacity, 0.5, accuracy: 0.001)

        defaults.set(9.0, forKey: "settings.floatingOpacity")
        XCTAssertLessThanOrEqual(store().floatingOpacity, 1)

        defaults.set(0.0, forKey: "settings.floatingOpacity")
        XCTAssertGreaterThan(store().floatingOpacity, 0, "完全透明等于让界面消失")
    }

    func testFontSizeAndSpacingAreClamped() {
        defaults.set(-20.0, forKey: "settings.lyricFontSize")
        XCTAssertGreaterThanOrEqual(store().lyricFontSize, 10)

        defaults.set(500.0, forKey: "settings.lyricFontSize")
        XCTAssertLessThanOrEqual(store().lyricFontSize, 48)

        defaults.set(999.0, forKey: "settings.lyricLineSpacing")
        XCTAssertLessThanOrEqual(store().lyricLineSpacing, 40)
    }

    /// 写入时也要钳制，别把越界值存进盘里。
    func testSettersClampBeforePersisting() async {
        let store = store()
        await store.setEngineVolume(7.0)
        XCTAssertEqual(defaults.double(forKey: "settings.engineVolume"), 1, accuracy: 0.001)

        await store.setLyricFontSize(2.0)
        XCTAssertGreaterThanOrEqual(defaults.double(forKey: "settings.lyricFontSize"), 10)
    }
}

/// 两个实现必须**行为一致**：测试用内存实现断言出来的值，
/// 生产（UserDefaults 实现）也要得到同样的值，否则测试会给出假安全感。
final class SettingsParityTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "flow-parity-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testBothImplementationsClampIdentically() async {
        let memory = InMemorySettingsStore()
        let persisted = UserDefaultsSettingsStore(defaults: defaults)

        for value in [-5.0, 0.0, 0.5, 3.0] {
            await memory.setEngineVolume(value)
            await persisted.setEngineVolume(value)
            XCTAssertEqual(memory.engineVolume, persisted.engineVolume, accuracy: 0.001,
                           "音量 \(value) 两种实现结果不一致")
        }

        for value in [1.0, 12.0, 100.0] {
            await memory.setLyricFontSize(value)
            await persisted.setLyricFontSize(value)
            XCTAssertEqual(memory.lyricFontSize, persisted.lyricFontSize, accuracy: 0.001,
                           "字号 \(value) 两种实现结果不一致")
        }

        for value in [0.0, 0.6, 2.0] {
            await memory.setFloatingOpacity(value)
            await persisted.setFloatingOpacity(value)
            XCTAssertEqual(memory.floatingOpacity, persisted.floatingOpacity, accuracy: 0.001,
                           "透明度 \(value) 两种实现结果不一致")
        }
    }

    /// 静音在两种实现里都必须保住 0。
    func testMuteSurvivesInBothImplementations() async {
        let memory = InMemorySettingsStore()
        let persisted = UserDefaultsSettingsStore(defaults: defaults)

        await memory.setEngineVolume(0)
        await persisted.setEngineVolume(0)

        XCTAssertEqual(memory.engineVolume, 0, accuracy: 0.001)
        XCTAssertEqual(persisted.engineVolume, 0, accuracy: 0.001)
    }
}

/// 范围必须与界面滑块一致。
///
/// 第 129 节发现：`SettingsLimits` 里的字号范围是我按"看着合理"填的 10...48，
/// 而设置页滑块是 11...30。于是可能出现"存储层允许 40、界面只能显示 30"的矛盾。
/// 这条测试把两者钉在一起：以后谁改了一边，另一边必须同步。
final class SettingsLimitsParityTests: XCTestCase {

    func testLimitsMatchSliderRanges() {
        // 与 `SettingsView` 里的 `SettingsSlider(range:)` 一一对应
        XCTAssertEqual(SettingsLimits.lyricFontSize.lowerBound, 11)
        XCTAssertEqual(SettingsLimits.lyricFontSize.upperBound, 30)
        XCTAssertEqual(SettingsLimits.lyricLineSpacing.lowerBound, 0)
        XCTAssertEqual(SettingsLimits.lyricLineSpacing.upperBound, 24)
        XCTAssertEqual(SettingsLimits.floatingOpacity.lowerBound, 0.3, accuracy: 0.001)
        XCTAssertEqual(SettingsLimits.floatingOpacity.upperBound, 1)
        XCTAssertEqual(SettingsLimits.engineVolume.lowerBound, 0)
        XCTAssertEqual(SettingsLimits.engineVolume.upperBound, 1)
    }

    /// 设置页以外的地方如果也钳制，必须用同一份范围（不能各写一套数字）。
    @MainActor
    func testAppearanceUsesSharedLimits() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        container.appearance.setLyricFontSize(999)
        XCTAssertEqual(container.appearance.lyricFontSize, SettingsLimits.lyricFontSize.upperBound,
                       accuracy: 0.001)
    }
}
