import Foundation

/// 设置备份 / 恢复（P1，规格 14「高级」）。
///
/// 只做「快照 ↔ JSON」的编解码与取值夹紧，不碰文件系统——
/// 落盘由调用方用 NSSavePanel / NSOpenPanel 完成，这样这段逻辑可以纯测试。
struct SettingsBackup: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int = currentVersion
    var enableNetwork: Bool
    var privacyMode: Bool
    var lyricFontSize: Double
    var lyricLineSpacing: Double
    var floatingOpacity: Double
    /// 可选以兼容没有此外观字段的 v1 备份。
    var floatingAppearanceRaw: String? = nil
    var defaultShape: String
    var autoAvoidEnabled: Bool
    var engineVolume: Double
    var fadeOutMillis: Int

    // MARK: - v2 补齐的字段
    //
    // 之前只备份了 11 项，而 `SettingsStoring` 有 22 项：音质、歌词排布、
    // 形态相关的四项、拔耳机暂停、隐藏 Dock、会议应用**全都没进备份**。
    // 用户导出再导入（或换机迁移）会静默丢掉一半设置，而且界面看起来"导入成功"。
    // 全部设为可选，这样 v1 文件仍然能读。
    var biliQualityRaw: String? = nil
    var preferredQualityRaw: String? = nil
    var lyricLayoutRaw: String? = nil
    var meetingAppsRaw: String? = nil
    var pauseOnHeadphoneUnplug: Bool? = nil
    var hideDockIcon: Bool? = nil
    var autoMorphEnabled: Bool? = nil
    var morphTransitionSpeed: Double? = nil
    var defaultMorphologyRaw: String? = nil
    var autoExpandPolicyRaw: String? = nil
    var autoCollapseOnDeactivate: Bool? = nil
    var loudnessNormalizationEnabled: Bool? = nil
    var eqPresetRaw: String? = nil
    var eqBandsRaw: String? = nil
    var showLyricTranslation: Bool? = nil
    // 沉浸播放模式。同样可选：之前导出的 v2 文件里没有这几项。
    var immersiveSceneRaw: String? = nil
    var immersiveResponseRaw: String? = nil
    var immersiveEntersFullScreen: Bool? = nil
    var immersivePowerSaving: Bool? = nil
    var immersiveBeatSyncRaw: String? = nil
    var playerBackgroundRaw: String? = nil
    var voiceAIEnabled: Bool? = nil
    var voiceSelectedPackID: String? = nil
    var voiceQualityModeRaw: String? = nil
    var voiceEntryVisible: Bool? = nil
    var voiceMirrorModeRaw: String? = nil
    var voiceCustomHFMirror: String? = nil
    var voiceCustomGitHubMirror: String? = nil

    enum RestoreError: Error, Equatable, LocalizedError {
        case unsupportedVersion(Int)   // 来自更新版本的文件，拒绝而不是猜
        case malformed                 // 不是合法 JSON

        /// 同 `LaunchAtLogin.Failure`：设置页会把 `localizedDescription` 显示出来，
        /// 不实现 `LocalizedError` 就是一句系统通用串。
        var errorDescription: String? {
            switch self {
            case let .unsupportedVersion(version):
                return "这个文件来自更新的版本（v\(version)），当前版本无法导入。"
            case .malformed:
                return "文件内容不是有效的设置备份（JSON 解析失败）。"
            }
        }
    }
}

extension SettingsBackup {

    /// 从当前设置生成快照。
    @MainActor
    static func snapshot(from settings: any SettingsStoring) -> SettingsBackup {
        SettingsBackup(enableNetwork: settings.enableNetwork,
                       privacyMode: settings.isPrivacyMode,
                       lyricFontSize: settings.lyricFontSize,
                       lyricLineSpacing: settings.lyricLineSpacing,
                       floatingOpacity: settings.floatingOpacity,
                       floatingAppearanceRaw: settings.floatingAppearanceRaw,
                       defaultShape: settings.defaultShape.rawValue,
                       autoAvoidEnabled: settings.autoAvoidEnabled,
                       engineVolume: settings.engineVolume,
                       fadeOutMillis: settings.fadeOutMillis,
                       preferredQualityRaw: settings.preferredQualityRaw,
                       lyricLayoutRaw: settings.lyricLayoutRaw,
                       meetingAppsRaw: settings.meetingAppsRaw,
                       pauseOnHeadphoneUnplug: settings.pauseOnHeadphoneUnplug,
                       hideDockIcon: settings.hideDockIcon,
                       autoMorphEnabled: settings.autoMorphEnabled,
                       morphTransitionSpeed: settings.morphTransitionSpeed,
                       defaultMorphologyRaw: settings.defaultMorphologyRaw,
                       autoExpandPolicyRaw: settings.autoExpandPolicyRaw,
                       autoCollapseOnDeactivate: settings.autoCollapseOnDeactivate,
                       loudnessNormalizationEnabled: settings.loudnessNormalizationEnabled,
                       eqPresetRaw: settings.eqPresetRaw,
                       eqBandsRaw: settings.eqBandsRaw,
                       showLyricTranslation: settings.showLyricTranslation,
                       immersiveSceneRaw: settings.immersiveSceneRaw,
                       immersiveResponseRaw: settings.immersiveResponseRaw,
                       immersiveEntersFullScreen: settings.immersiveEntersFullScreen,
                       immersivePowerSaving: settings.immersivePowerSaving,
                       immersiveBeatSyncRaw: settings.immersiveBeatSyncRaw,
                       playerBackgroundRaw: settings.playerBackgroundRaw,
                       voiceAIEnabled: settings.voiceAIEnabled,
                       voiceSelectedPackID: settings.voiceSelectedPackID,
                       voiceQualityModeRaw: settings.voiceQualityMode,
                       voiceEntryVisible: settings.voiceEntryVisible,
                       voiceMirrorModeRaw: settings.voiceMirrorModeRaw,
                       voiceCustomHFMirror: settings.voiceCustomHFMirror,
                       voiceCustomGitHubMirror: settings.voiceCustomGitHubMirror)
    }

    static func encode(_ backup: SettingsBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    /// 解码并校验版本。未来版本直接拒绝——旧版本猜新字段的默认值是错误的来源。
    static func decode(_ data: Data) throws -> SettingsBackup {
        let backup: SettingsBackup
        do {
            backup = try JSONDecoder().decode(SettingsBackup.self, from: data)
        } catch {
            throw RestoreError.malformed
        }
        guard backup.version <= currentVersion else {
            throw RestoreError.unsupportedVersion(backup.version)
        }
        return backup
    }

    /// 写回设置。所有数值在这里再夹一次——备份文件可能被手工改过。
    @MainActor
    func apply(to settings: any SettingsStoring) async {
        await settings.setEnableNetwork(enableNetwork)
        await settings.setPrivacyMode(privacyMode)
        await settings.setLyricFontSize(min(max(lyricFontSize, 11), 30))
        await settings.setLyricLineSpacing(min(max(lyricLineSpacing, 0), 24))
        await settings.setFloatingOpacity(min(max(floatingOpacity, 0.3), 1))
        if let raw = floatingAppearanceRaw, let mode = FloatingAppearanceMode(rawValue: raw) {
            await settings.setFloatingAppearanceRaw(mode.rawValue)
        }
        await settings.setAutoAvoidEnabled(autoAvoidEnabled)
        await settings.setEngineVolume(min(max(engineVolume, 0), 1))
        await settings.setFadeOutMillis(min(max(fadeOutMillis, SettingsLimits.fadeOutMillis.lowerBound),
                                             SettingsLimits.fadeOutMillis.upperBound))
        if let shape = LyricsShape(rawValue: defaultShape) {
            await settings.setDefaultShape(shape)  // 未知形态保留原值，不写脏数据
        }

        // v2 字段：只有备份里真的带了、且能解析为合法选项才写，避免"用 v1 文件导入"把新设置清掉或写入非法枚举值。
        if let preferred = preferredQualityRaw ?? biliQualityRaw, !preferred.isEmpty {
            if AudioQualityTier(rawValue: preferred) != nil {
                await settings.setPreferredQualityRaw(preferred)
            }
        } else if let empty = preferredQualityRaw ?? biliQualityRaw, empty.isEmpty {
            await settings.setPreferredQualityRaw(empty)
        }
        if let value = lyricLayoutRaw, LyricLayout(rawValue: value) != nil {
            await settings.setLyricLayoutRaw(value)
        }
        if let value = meetingAppsRaw { await settings.setMeetingAppsRaw(value) }
        if let value = pauseOnHeadphoneUnplug { await settings.setPauseOnHeadphoneUnplug(value) }
        if let value = hideDockIcon { await settings.setHideDockIcon(value) }
        if let value = autoMorphEnabled { await settings.setAutoMorphEnabled(value) }
        if let value = morphTransitionSpeed {
            await settings.setMorphTransitionSpeed(min(max(value, 0.5), 1.5))
        }
        if let value = defaultMorphologyRaw, PlayerMorphology(rawValue: value) != nil {
            await settings.setDefaultMorphologyRaw(value)
        }
        if let value = autoExpandPolicyRaw, AutoExpandPolicy(rawValue: value) != nil {
            await settings.setAutoExpandPolicyRaw(value)
        }
        if let value = autoCollapseOnDeactivate { await settings.setAutoCollapseOnDeactivate(value) }
        if let value = loudnessNormalizationEnabled { await settings.setLoudnessNormalizationEnabled(value) }
        if let value = eqPresetRaw, EqualizerPreset(rawValue: value) != nil {
            await settings.setEQPresetRaw(value)
        }
        if let value = eqBandsRaw {
            await settings.setEQBandsRaw(EqualizerSpec.serializeBands(EqualizerSpec.parseBands(value)))
        }
        if let value = showLyricTranslation { await settings.setShowLyricTranslation(value) }
        if let value = immersiveSceneRaw, ImmersiveSceneKind(rawValue: value) != nil {
            await settings.setImmersiveSceneRaw(value)
        }
        if let value = immersiveResponseRaw, ImmersiveResponse(rawValue: value) != nil {
            await settings.setImmersiveResponseRaw(value)
        }
        if let value = immersiveEntersFullScreen { await settings.setImmersiveEntersFullScreen(value) }
        if let value = immersivePowerSaving { await settings.setImmersivePowerSaving(value) }
        if let value = immersiveBeatSyncRaw, ImmersiveBeatSync(rawValue: value) != nil {
            await settings.setImmersiveBeatSyncRaw(value)
        }
        if let value = playerBackgroundRaw, PlayerBackground(rawValue: value) != nil {
            await settings.setPlayerBackgroundRaw(value)
        }
        if let value = voiceAIEnabled { await settings.setVoiceAIEnabled(value) }
        if let value = voiceSelectedPackID { await settings.setVoiceSelectedPackID(value) }
        if let value = voiceQualityModeRaw, VoiceManager.VoiceQualityMode(rawValue: value) != nil {
            await settings.setVoiceQualityMode(value)
        }
        if let value = voiceEntryVisible { await settings.setVoiceEntryVisible(value) }
        if let value = voiceMirrorModeRaw, VoiceMirrorMode(rawValue: value) != nil {
            await settings.setVoiceMirrorModeRaw(value)
        }
        if let value = voiceCustomHFMirror { await settings.setVoiceCustomHFMirror(value) }
        if let value = voiceCustomGitHubMirror { await settings.setVoiceCustomGitHubMirror(value) }
    }
}
