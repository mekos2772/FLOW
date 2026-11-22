import XCTest
@testable import SpatialLyricsPlayer

/// 两个设置存储在**边界行为**上必须一致。
///
/// `UserDefaultsSettingsStore` 与 `InMemorySettingsStore` 是同一份协议的两个实现；
/// 降级模式用的恰恰是内存实现。之前内存实现对 `fadeOutMillis` **不夹紧**，
/// 于是"导入一个 99999 ms 的备份"在降级模式下会原样存下，到点淡出变得离谱地长。
///
/// 这条测试把六个数值型 setter 的越界行为逐一对齐。
final class SettingsStoreParityTests: XCTestCase {

    func testNumericSettersClampIdentically() async {
        let defaults = UserDefaults(suiteName: "flow-parity-\(UUID().uuidString)")!
        let durable = UserDefaultsSettingsStore(defaults: defaults)
        let memory = InMemorySettingsStore()

        for store in [durable as any SettingsStoring, memory as any SettingsStoring] {
            await store.setLyricFontSize(999)
            await store.setLyricLineSpacing(-9)
            await store.setFloatingOpacity(5)
            await store.setEngineVolume(3)
            await store.setFadeOutMillis(99_999)
            await store.setMorphTransitionSpeed(9)

            XCTAssertEqual(store.lyricFontSize, SettingsLimits.lyricFontSize.upperBound)
            XCTAssertEqual(store.lyricLineSpacing, 0)
            XCTAssertEqual(store.floatingOpacity, 1)
            XCTAssertEqual(store.engineVolume, 1)
            XCTAssertEqual(store.fadeOutMillis, SettingsLimits.fadeOutMillis.upperBound)
            XCTAssertEqual(store.morphTransitionSpeed, SettingsLimits.morphSpeed.upperBound)
        }

        defaults.removePersistentDomain(forName: defaults.description)
    }

    func testAudioEffectsSettingsValidateIdentically() async {
        let suite = "flow-parity-eq-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let durable = UserDefaultsSettingsStore(defaults: defaults)
        let memory = InMemorySettingsStore()

        for store in [durable as any SettingsStoring, memory as any SettingsStoring] {
            XCTAssertTrue(store.loudnessNormalizationEnabled)
            XCTAssertTrue(store.showLyricTranslation)
            XCTAssertEqual(store.eqPresetRaw, EqualizerPreset.off.rawValue)

            await store.setLoudnessNormalizationEnabled(false)
            await store.setShowLyricTranslation(false)
            await store.setEQPresetRaw("vocal")
            XCTAssertEqual(store.eqPresetRaw, EqualizerPreset.vocal.rawValue)

            await store.setEQPresetRaw("invalid-preset")
            XCTAssertEqual(store.eqPresetRaw, EqualizerPreset.off.rawValue)

            await store.setEQBandsRaw("40,-40,2.5,NaN,inf")
            XCTAssertFalse(store.loudnessNormalizationEnabled)
            XCTAssertFalse(store.showLyricTranslation)
            XCTAssertEqual(store.eqBandsRaw, "12.0,-12.0,2.5,0.0,0.0")

            await store.setEQBandsRaw("40,bad,1")
            XCTAssertEqual(store.eqBandsRaw, "0.0,0.0,0.0,0.0,0.0")
        }

        defaults.removePersistentDomain(forName: suite)
    }
}
