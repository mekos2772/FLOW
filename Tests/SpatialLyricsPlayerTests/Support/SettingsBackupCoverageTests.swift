import XCTest
@testable import SpatialLyricsPlayer

/// 设置备份必须覆盖**全部**设置项。
///
/// 之前只备份了 11 项，而 `SettingsStoring` 有 22 项：音质、歌词排布、
/// 形态相关的四项、拔耳机暂停、隐藏 Dock、会议应用全都没进备份。
/// 用户导出再导入（或换机迁移）会静默丢掉一半设置，界面还显示"导入成功"。
@MainActor
final class SettingsBackupCoverageTests: XCTestCase {

    /// 逐项设置不同的值，导出→清空→导入，每一项都要回来。
    func testRoundTripCoversEverySetting() async {
        let source = InMemorySettingsStore()
        source.preferredQualityRaw = AudioQualityTier.hifi.rawValue
        await source.setLyricLayoutRaw(LyricLayout.editorial.rawValue)
        await source.setMeetingAppsRaw("com.apple.Keynote")
        await source.setPauseOnHeadphoneUnplug(true)
        await source.setHideDockIcon(true)
        await source.setAutoMorphEnabled(true)
        await source.setMorphTransitionSpeed(1.4)
        await source.setDefaultMorphologyRaw("capsule")
        await source.setAutoExpandPolicyRaw(AutoExpandPolicy.eager.rawValue)
        await source.setAutoCollapseOnDeactivate(true)
        await source.setEngineVolume(0.42)
        await source.setLoudnessNormalizationEnabled(false)
        await source.setEQPresetRaw(EqualizerPreset.custom.rawValue)
        await source.setEQBandsRaw("3.0,1.5,-2.0,4.5,-1.0")
        await source.setShowLyricTranslation(false)
        await source.setImmersiveSceneRaw(ImmersiveSceneKind.rain.rawValue)
        await source.setImmersiveResponseRaw(ImmersiveResponse.gentle.rawValue)
        await source.setImmersiveEntersFullScreen(false)
        await source.setImmersivePowerSaving(true)
        await source.setImmersiveBeatSyncRaw(ImmersiveBeatSync.strong.rawValue)

        let backup = SettingsBackup.snapshot(from: source)
        let data = try! SettingsBackup.encode(backup)

        let target = InMemorySettingsStore()
        let decoded = try! SettingsBackup.decode(data)
        await decoded.apply(to: target)

        XCTAssertEqual(target.preferredQualityRaw, AudioQualityTier.hifi.rawValue, "音质没被备份")
        XCTAssertEqual(target.lyricLayoutRaw, LyricLayout.editorial.rawValue, "歌词排布没被备份")
        XCTAssertEqual(target.meetingAppsRaw, "com.apple.Keynote", "会议应用没被备份")
        XCTAssertEqual(target.pauseOnHeadphoneUnplug, true, "拔耳机暂停没被备份")
        XCTAssertEqual(target.hideDockIcon, true, "隐藏 Dock 没被备份")
        XCTAssertEqual(target.autoMorphEnabled, true, "自动形变没被备份")
        XCTAssertEqual(target.morphTransitionSpeed, 1.4, accuracy: 0.001)
        XCTAssertEqual(target.defaultMorphologyRaw, "capsule")
        XCTAssertEqual(target.autoExpandPolicyRaw, AutoExpandPolicy.eager.rawValue)
        XCTAssertEqual(target.autoCollapseOnDeactivate, true)
        XCTAssertEqual(target.engineVolume, 0.42, accuracy: 0.001)
        XCTAssertEqual(target.loudnessNormalizationEnabled, false, "响度平衡开关没被备份")
        XCTAssertEqual(target.eqPresetRaw, EqualizerPreset.custom.rawValue, "均衡器预设没被备份")
        XCTAssertEqual(target.eqBandsRaw, "3.0,1.5,-2.0,4.5,-1.0", "均衡器频段没被备份")
        XCTAssertEqual(target.showLyricTranslation, false, "中文译文开关没被备份")
        XCTAssertEqual(target.immersiveSceneRaw, ImmersiveSceneKind.rain.rawValue, "沉浸场景没被备份")
        XCTAssertEqual(target.immersiveResponseRaw, ImmersiveResponse.gentle.rawValue, "沉浸幅度没被备份")
        XCTAssertEqual(target.immersiveEntersFullScreen, false, "沉浸全屏开关没被备份")
        XCTAssertEqual(target.immersivePowerSaving, true, "沉浸省电开关没被备份")
        XCTAssertEqual(target.immersiveBeatSyncRaw, ImmersiveBeatSync.strong.rawValue, "节拍联动没被备份")
    }

    /// 备份里夹带非法枚举值时应保留目标设置原值，不写脏数据。
    func testInvalidEnumValuesInBackupAreIgnored() async {
        var backup = SettingsBackup.snapshot(from: InMemorySettingsStore())
        backup.preferredQualityRaw = "30280"
        backup.biliQualityRaw = "30280"
        backup.lyricLayoutRaw = "doubleLine"
        backup.defaultMorphologyRaw = "nonexistent"
        backup.autoExpandPolicyRaw = "always"
        backup.eqPresetRaw = "superBass999"
        backup.immersiveSceneRaw = "aurora"
        backup.immersiveResponseRaw = "wild"
        backup.immersiveBeatSyncRaw = "disco"

        let target = InMemorySettingsStore()
        target.preferredQualityRaw = AudioQualityTier.high.rawValue
        await target.setLyricLayoutRaw(LyricLayout.appleMusic.rawValue)
        await target.setDefaultMorphologyRaw(PlayerMorphology.compact.rawValue)
        await target.setAutoExpandPolicyRaw(AutoExpandPolicy.conservative.rawValue)
        await target.setEQPresetRaw(EqualizerPreset.vocal.rawValue)
        await target.setImmersiveSceneRaw(ImmersiveSceneKind.ridge.rawValue)
        await target.setImmersiveResponseRaw(ImmersiveResponse.off.rawValue)
        await target.setImmersiveBeatSyncRaw(ImmersiveBeatSync.subtle.rawValue)

        await backup.apply(to: target)

        XCTAssertEqual(target.preferredQualityRaw, AudioQualityTier.high.rawValue)
        XCTAssertEqual(target.lyricLayoutRaw, LyricLayout.appleMusic.rawValue)
        XCTAssertEqual(target.defaultMorphologyRaw, PlayerMorphology.compact.rawValue)
        XCTAssertEqual(target.autoExpandPolicyRaw, AutoExpandPolicy.conservative.rawValue)
        XCTAssertEqual(target.eqPresetRaw, EqualizerPreset.vocal.rawValue)
        XCTAssertEqual(target.immersiveSceneRaw, ImmersiveSceneKind.ridge.rawValue)
        XCTAssertEqual(target.immersiveResponseRaw, ImmersiveResponse.off.rawValue)
        XCTAssertEqual(target.immersiveBeatSyncRaw, ImmersiveBeatSync.subtle.rawValue)
    }

    /// v1 文件（没有这些字段）导入时，不能把当前设置清成默认值。
    func testV1FileDoesNotClearNewFields() async throws {
        let json = """
        {"version":1,"enableNetwork":true,"privacyMode":false,"lyricFontSize":15,
         "lyricLineSpacing":8,"floatingOpacity":1,"defaultShape":"capsule",
         "autoAvoidEnabled":true,"engineVolume":0.5,"fadeOutMillis":600}
        """
        let backup = try SettingsBackup.decode(Data(json.utf8))

        let target = InMemorySettingsStore()
        await target.setHideDockIcon(true)
        await target.setMorphTransitionSpeed(1.3)
        await target.setLoudnessNormalizationEnabled(false)
        await target.setEQPresetRaw(EqualizerPreset.warm.rawValue)
        await target.setEQBandsRaw("2.0,1.0,0.0,-1.0,-2.0")
        await target.setShowLyricTranslation(false)
        await target.setImmersiveSceneRaw(ImmersiveSceneKind.light.rawValue)
        await target.setImmersiveResponseRaw(ImmersiveResponse.gentle.rawValue)
        await target.setImmersiveEntersFullScreen(false)
        await target.setImmersivePowerSaving(true)
        await target.setImmersiveBeatSyncRaw(ImmersiveBeatSync.off.rawValue)
        await backup.apply(to: target)

        XCTAssertTrue(target.hideDockIcon, "v1 文件没有这个字段，不该把它改掉")
        XCTAssertEqual(target.morphTransitionSpeed, 1.3, accuracy: 0.001)
        XCTAssertFalse(target.loudnessNormalizationEnabled)
        XCTAssertEqual(target.eqPresetRaw, EqualizerPreset.warm.rawValue)
        XCTAssertEqual(target.eqBandsRaw, "2.0,1.0,0.0,-1.0,-2.0")
        XCTAssertFalse(target.showLyricTranslation)
        XCTAssertEqual(target.immersiveSceneRaw, ImmersiveSceneKind.light.rawValue)
        XCTAssertEqual(target.immersiveResponseRaw, ImmersiveResponse.gentle.rawValue)
        XCTAssertFalse(target.immersiveEntersFullScreen)
        XCTAssertTrue(target.immersivePowerSaving)
        XCTAssertEqual(target.immersiveBeatSyncRaw, ImmersiveBeatSync.off.rawValue)
    }
}
