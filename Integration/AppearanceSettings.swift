import Foundation
import Observation

/// 外观与歌词样式设置。
///
/// 与 `PrivacyState` 一样，是"业务设置 + 可观察快照"的组合：
/// 视图读这里的值，写入走 `SettingsStoring`，避免每个视图各自去读 UserDefaults。
@MainActor
@Observable
final class AppearanceSettings {
    private(set) var lyricFontSize: Double = 0
    private(set) var lyricLineSpacing: Double = 0
    private(set) var floatingOpacity: Double = 1
    private(set) var floatingAppearance: FloatingAppearanceMode = .background
    private(set) var lyricLayout: LyricLayout = .appleMusic
    private(set) var defaultShape: LyricsShape = .capsule
    private(set) var autoAvoidEnabled: Bool = true
    private(set) var autoMorphEnabled: Bool = true
    private(set) var morphTransitionSpeed: Double = 1
    private(set) var defaultMorphology: PlayerMorphology = .expanded
    private(set) var autoExpandPolicyRaw: String = ""
    /// 失去焦点时是否自动从完整形态收缩（悬浮模式）。默认关闭，可在主页或设置里开启。
    private(set) var autoCollapseOnDeactivate: Bool = false
    private(set) var engineVolume: Double = 1
    private(set) var fadeOutMillis: Int = 0
    private(set) var loudnessNormalizationEnabled: Bool = false
    private(set) var eqPreset: EqualizerPreset = .off
    private(set) var eqBands: [Double] = []
    private(set) var showLyricTranslation: Bool = true
    /// 沉浸播放模式：场景、随音乐变化的幅度、进入时是否全屏、省电（降帧率）、
    /// 节拍联动的程度。
    private(set) var immersiveScene: ImmersiveSceneKind = .default
    private(set) var immersiveResponse: ImmersiveResponse = .default
    private(set) var immersiveEntersFullScreen: Bool = true
    private(set) var immersivePowerSaving: Bool = false
    private(set) var immersiveBeatSync: ImmersiveBeatSync = .default
    /// 播放页背景：纯色、封面取色，或和沉浸共用的动态场景。
    private(set) var playerBackground: PlayerBackground = .default
    private let settings: any SettingsStoring
    private var audioEffectsPersistTask: Task<Void, Never>?

    init(settings: any SettingsStoring) {
        self.settings = settings
        load()
    }

    /// 导入设置备份后重新读取：外观快照只在启动时读一次，不重读的话设置页显示旧值，
    /// 之后再动一下均衡还会把旧值整组写回去。
    func reloadFromStore() {
        load()
        syncAudioEffects()
    }

    private func load() {
        lyricFontSize = SettingsLimits.clamp(settings.lyricFontSize, to: SettingsLimits.lyricFontSize)
        lyricLineSpacing = SettingsLimits.clamp(settings.lyricLineSpacing, to: SettingsLimits.lyricLineSpacing)
        floatingOpacity = SettingsLimits.clamp(settings.floatingOpacity, to: SettingsLimits.floatingOpacity)
        floatingAppearance = FloatingAppearanceMode(rawValue: settings.floatingAppearanceRaw) ?? .background
        lyricLayout = LyricLayout(rawValue: settings.lyricLayoutRaw) ?? .appleMusic
        defaultShape = settings.defaultShape
        autoAvoidEnabled = settings.autoAvoidEnabled
        autoMorphEnabled = settings.autoMorphEnabled
        morphTransitionSpeed = SettingsLimits.clamp(settings.morphTransitionSpeed, to: SettingsLimits.morphSpeed)
        defaultMorphology = PlayerMorphology(rawValue: settings.defaultMorphologyRaw) ?? .expanded
        autoExpandPolicyRaw = settings.autoExpandPolicyRaw
        autoCollapseOnDeactivate = settings.autoCollapseOnDeactivate
        engineVolume = SettingsLimits.clamp(settings.engineVolume, to: SettingsLimits.engineVolume)
        fadeOutMillis = min(max(settings.fadeOutMillis, 0), 3000)
        loudnessNormalizationEnabled = settings.loudnessNormalizationEnabled
        eqPreset = EqualizerPreset(rawValue: settings.eqPresetRaw) ?? .off
        eqBands = EqualizerSpec.parseBands(settings.eqBandsRaw)
        showLyricTranslation = settings.showLyricTranslation
        immersiveScene = ImmersiveSceneKind(rawValue: settings.immersiveSceneRaw) ?? .default
        immersiveResponse = ImmersiveResponse(rawValue: settings.immersiveResponseRaw) ?? .default
        immersiveEntersFullScreen = settings.immersiveEntersFullScreen
        immersivePowerSaving = settings.immersivePowerSaving
        immersiveBeatSync = ImmersiveBeatSync(rawValue: settings.immersiveBeatSyncRaw) ?? .default
        playerBackground = PlayerBackground(rawValue: settings.playerBackgroundRaw) ?? .default
        }

    var effectiveEQBands: [Double] {
        eqPreset == .custom ? eqBands : eqPreset.defaultGainsDB
    }

    func syncAudioEffects() {
        AudioEffectsHub.shared.configure(
            loudnessEnabled: loudnessNormalizationEnabled,
            bandGainsDB: effectiveEQBands
        )
    }

    func setAutoMorphEnabled(_ value: Bool) {
        autoMorphEnabled = value
        Task { [settings] in await settings.setAutoMorphEnabled(value) }
    }

    func setMorphTransitionSpeed(_ value: Double) {
        morphTransitionSpeed = min(max(value, 0.5), 1.5)
        let stored = morphTransitionSpeed
        Task { [settings] in await settings.setMorphTransitionSpeed(stored) }
    }

    func setAutoExpandPolicy(_ policy: AutoExpandPolicy) {
        autoExpandPolicyRaw = policy.rawValue
        Task { [settings] in await settings.setAutoExpandPolicyRaw(policy.rawValue) }
    }

    /// 主页与状态栏共用的“悬浮模式”开关视图语义。
    var isFloatingModeEnabled: Bool { autoCollapseOnDeactivate }

    func setFloatingModeEnabled(_ value: Bool) {
        setAutoCollapseOnDeactivate(value)
        if value, !autoMorphEnabled {
            setAutoMorphEnabled(true)
        }
    }

    func setAutoCollapseOnDeactivate(_ value: Bool) {
        autoCollapseOnDeactivate = value
        Task { [settings] in await settings.setAutoCollapseOnDeactivate(value) }
    }

    func setDefaultMorphology(_ morphology: PlayerMorphology) {
        defaultMorphology = morphology
        Task { [settings] in await settings.setDefaultMorphologyRaw(morphology.rawValue) }
    }

    func setFadeOutMillis(_ value: Int) {
        fadeOutMillis = min(max(value, 0), 3000)
        Task { [settings] in await settings.setFadeOutMillis(fadeOutMillis) }
    }

    func setLyricFontSize(_ value: Double) {
        lyricFontSize = min(max(value, 11), 30)
        Task { [settings] in await settings.setLyricFontSize(lyricFontSize) }
    }

    func setLyricLineSpacing(_ value: Double) {
        lyricLineSpacing = min(max(value, 0), 24)
        Task { [settings] in await settings.setLyricLineSpacing(lyricLineSpacing) }
    }

    func setDefaultShape(_ shape: LyricsShape) {
        defaultShape = shape
        Task { [settings] in await settings.setDefaultShape(shape) }
    }

    func setAutoAvoidEnabled(_ value: Bool) {
        autoAvoidEnabled = value
        Task { [settings] in await settings.setAutoAvoidEnabled(value) }
    }

    func setEngineVolume(_ value: Double) {
        engineVolume = min(max(value, 0), 1)
        Task { [settings] in await settings.setEngineVolume(engineVolume) }
    }

    func setLyricLayout(_ value: LyricLayout) {
        lyricLayout = value
        Task { [settings] in await settings.setLyricLayoutRaw(value.rawValue) }
    }

    func setShowLyricTranslation(_ value: Bool) {
        showLyricTranslation = value
        Task { [settings] in await settings.setShowLyricTranslation(value) }
    }

    func setImmersiveScene(_ value: ImmersiveSceneKind) {
        immersiveScene = value
        Task { [settings] in await settings.setImmersiveSceneRaw(value.rawValue) }
    }

    func setImmersiveResponse(_ value: ImmersiveResponse) {
        immersiveResponse = value
        Task { [settings] in await settings.setImmersiveResponseRaw(value.rawValue) }
    }

    func setImmersiveEntersFullScreen(_ value: Bool) {
        immersiveEntersFullScreen = value
        Task { [settings] in await settings.setImmersiveEntersFullScreen(value) }
    }

    func setImmersivePowerSaving(_ value: Bool) {
        immersivePowerSaving = value
        Task { [settings] in await settings.setImmersivePowerSaving(value) }
    }

    func setImmersiveBeatSync(_ value: ImmersiveBeatSync) {
        immersiveBeatSync = value
        Task { [settings] in await settings.setImmersiveBeatSyncRaw(value.rawValue) }
    }

    /// 选了动态场景就顺手把沉浸也换成它：从普通切到沉浸时还是同一幅画，只是铺满。
    func setPlayerBackground(_ value: PlayerBackground) {
        playerBackground = value
        Task { [settings] in await settings.setPlayerBackgroundRaw(value.rawValue) }
        if let scene = value.scene, scene != immersiveScene { setImmersiveScene(scene) }
    }

    func setFloatingAppearance(_ value: FloatingAppearanceMode) {
        floatingAppearance = value
        Task { [settings] in await settings.setFloatingAppearanceRaw(value.rawValue) }
    }

    func setFloatingOpacity(_ value: Double) {
        floatingOpacity = min(max(value, 0.3), 1)
        Task { [settings] in await settings.setFloatingOpacity(floatingOpacity) }
    }

    func setLoudnessNormalizationEnabled(_ value: Bool) {
        loudnessNormalizationEnabled = value
        commitAudioEffects()
    }

    func setEQPreset(_ preset: EqualizerPreset) {
        eqPreset = preset
        if preset != .custom {
            eqBands = preset.defaultGainsDB
        }
        commitAudioEffects()
    }

    func setEQBand(index: Int, gainDB: Double) {
        guard (0..<EqualizerSpec.bandCount).contains(index) else { return }
        var updated = effectiveEQBands
        updated[index] = EqualizerSpec.clampGain(gainDB)
        eqBands = updated
        eqPreset = .custom
        commitAudioEffects()
    }

    func resetEQ() {
        eqPreset = .off
        eqBands = EqualizerPreset.off.defaultGainsDB
        commitAudioEffects()
    }

    private func commitAudioEffects() {
        syncAudioEffects()
        let loudness = loudnessNormalizationEnabled
        let presetRaw = eqPreset.rawValue
        let bandsRaw = EqualizerSpec.serializeBands(eqBands)
        let previous = audioEffectsPersistTask
        audioEffectsPersistTask = Task { [settings] in
            await previous?.value
            await settings.setLoudnessNormalizationEnabled(loudness)
            await settings.setEQPresetRaw(presetRaw)
            await settings.setEQBandsRaw(bandsRaw)
        }
    }
}
