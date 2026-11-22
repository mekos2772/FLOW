import Foundation

/// 轻量设置存储。
///
/// 刻意保持极小的键集：这里是"用户偏好"，领域数据（曲目/队列/偏移/历史）走 SwiftData。
protocol SettingsStoring: Sendable {
    /// 通用首选音质档位（`AudioQualityTier.rawValue`）。空串表示自动。
    var preferredQualityRaw: String { get set }

    /// 「允许联网」。正式版（UserDefaults）默认允许，首次打开就能用在线功能；
    /// 测试用的内存实现默认关闭，保证单测不会意外联网——两者不同是有意的。
    var enableNetwork: Bool { get }
    var isPrivacyMode: Bool { get }
    var lyricFontSize: Double { get }
    var lyricLineSpacing: Double { get }
    var floatingOpacity: Double { get }
    var floatingAppearanceRaw: String { get }
    var lyricLayoutRaw: String { get }
    var defaultShape: LyricsShape { get }
    var autoAvoidEnabled: Bool { get }
    var engineVolume: Double { get }
    /// 睡眠定时到点时的淡出时长（毫秒）。0 表示不淡出，直接暂停。
    var fadeOutMillis: Int { get }
    /// 会议模式应用名单（逗号分隔的 bundle id）。空串表示该功能未启用。
    var meetingAppsRaw: String { get }
    /// 拔出耳机时是否自动暂停。默认开启。
    var pauseOnHeadphoneUnplug: Bool { get }
    /// 隐藏 Dock 图标（改成菜单栏常驻形态）。默认关闭。
    var hideDockIcon: Bool { get }
    /// 是否允许系统按空间自动变换形态。关闭后只有用户操作能改形态。
    var autoMorphEnabled: Bool { get }
    /// 形态过渡速度倍率（0.5…1.5）。1 表示按令牌默认时长。
    var morphTransitionSpeed: Double { get }
    /// 冷启动时默认落到的形态。
    var defaultMorphologyRaw: String { get }
    /// 自动展开积极度：conservative / balanced / eager。
    /// 决定"空间变多时多快恢复到更丰富的形态"（规格 规则 D）。
    var autoExpandPolicyRaw: String { get }
    /// 失去焦点时是否自动从完整形态收缩。
    ///
    /// 默认开启（桌面伴侣的核心直觉），但**必须可关**：
    /// 一边听歌一边在别处工作的人，一旦切走就看不到完整版面——
    /// 这个行为之前没有任何设置入口，属于"替用户做了不可撤销的决定"。
    var autoCollapseOnDeactivate: Bool { get }
    var loudnessNormalizationEnabled: Bool { get }
    var eqPresetRaw: String { get }
    var eqBandsRaw: String { get }
    var showLyricTranslation: Bool { get }
    /// 沉浸播放模式的场景（`ImmersiveSceneKind.rawValue`）。未知值读出时回落默认场景。
    var immersiveSceneRaw: String { get }
    /// 沉浸画面随音乐变化的幅度（`ImmersiveResponse.rawValue`）。
    var immersiveResponseRaw: String { get }
    /// 进入沉浸模式时是否顺带全屏。默认开启。
    var immersiveEntersFullScreen: Bool { get }
    /// 沉浸模式省电：降低帧率。默认关闭。
    var immersivePowerSaving: Bool { get }
    /// 沉浸画面跟节拍走的程度（`ImmersiveBeatSync.rawValue`）。未知值读出时回落默认档。
    var immersiveBeatSyncRaw: String { get }
    /// 播放页背景（`PlayerBackground.rawValue`）。未知值读出时回落纯色。
    var playerBackgroundRaw: String { get }
    /// FLOW Voice：AI 翻唱总开关。默认关。
    var voiceAIEnabled: Bool { get }
    /// 当前选中的音色包 ID；未选时 nil。
    var voiceSelectedPackID: String? { get }
    /// 音质模式 raw：`fast` / `balanced` / `best`。未知值回落 `balanced`。
    var voiceQualityMode: String { get }
    /// 是否在播放栏显示「音色」快捷入口（可随时关闭，或在卸载 FLOW Voice 后自动隐藏）。
    var voiceEntryVisible: Bool { get }
    /// 新手引导是否已经看过。只影响"要不要在第一次打开时自动显示"，
    /// 设置页随时可以重看，所以这个值没有"锁定"的含义。
    var hasSeenOnboarding: Bool { get }
    /// RVC 音色与底座模型下载镜像模式（默认 `"hfMirror"`）。
    var voiceMirrorModeRaw: String { get }
    /// 自定义 HuggingFace 镜像根域名（默认 `https://hf-mirror.com`）。
    var voiceCustomHFMirror: String { get }
    /// 自定义 GitHub 下载加速前缀（可选，默认空串）。
    var voiceCustomGitHubMirror: String { get }
    func setAutoCollapseOnDeactivate(_ value: Bool) async
    func setLoudnessNormalizationEnabled(_ value: Bool) async
    func setEQPresetRaw(_ value: String) async
    func setEQBandsRaw(_ value: String) async
    func setShowLyricTranslation(_ value: Bool) async
    func setImmersiveSceneRaw(_ value: String) async
    func setImmersiveResponseRaw(_ value: String) async
    func setImmersiveEntersFullScreen(_ value: Bool) async
    func setImmersivePowerSaving(_ value: Bool) async
    func setImmersiveBeatSyncRaw(_ value: String) async
    func setPlayerBackgroundRaw(_ value: String) async
    /// B 站音质档位（`BiliAudioQuality.rawValue`）。空串表示自动。

    func setEnableNetwork(_ value: Bool) async
    func setPrivacyMode(_ value: Bool) async
    func setLyricFontSize(_ value: Double) async
    func setLyricLineSpacing(_ value: Double) async
    func setFloatingOpacity(_ value: Double) async
    func setFloatingAppearanceRaw(_ value: String) async
    func setLyricLayoutRaw(_ value: String) async
    func setDefaultShape(_ shape: LyricsShape) async
    func setAutoAvoidEnabled(_ value: Bool) async
    func setFadeOutMillis(_ value: Int) async
    func setMeetingAppsRaw(_ value: String) async
    func setPauseOnHeadphoneUnplug(_ value: Bool) async
    func setHideDockIcon(_ value: Bool) async
    func setAutoMorphEnabled(_ value: Bool) async
    /// 首选音质档位。属性是 `{ get set }`，但备份恢复走异步 setter，
    /// 与其它设置保持同一种调用形态（也便于 Mock 实现）。
    func setPreferredQualityRaw(_ value: String) async

    func setMorphTransitionSpeed(_ value: Double) async
    func setDefaultMorphologyRaw(_ value: String) async
    func setAutoExpandPolicyRaw(_ value: String) async
    func setEngineVolume(_ value: Double) async
    func setVoiceAIEnabled(_ value: Bool) async
    func setVoiceSelectedPackID(_ value: String?) async
    func setVoiceQualityMode(_ value: String) async
    func setVoiceEntryVisible(_ value: Bool) async
    func setHasSeenOnboarding(_ value: Bool) async
    func setVoiceMirrorModeRaw(_ value: String) async
    func setVoiceCustomHFMirror(_ value: String) async
    func setVoiceCustomGitHubMirror(_ value: String) async
}

/// 设置项的合法范围。**两个实现共用同一份**。
///
/// 之前只有 `UserDefaultsSettingsStore` 钳制，`InMemorySettingsStore`（测试用）
/// 原样收发——于是测试可以断言出生产永远不会出现的值（比如透明度 9.0）。
/// 那种"测试通过、线上不符"的差异最难查。
enum SettingsLimits {
    /// 范围必须与**界面滑块**一致，否则会出现"存了 40、界面只能显示 30"这种矛盾。
    /// 之前这里是我按"看着合理"填的 10...48 / 0...40，与滑块（11...30 / 0...24）不一致。
    static let lyricFontSize: ClosedRange<Double> = 11...30
    static let lyricLineSpacing: ClosedRange<Double> = 0...24
    static let floatingOpacity: ClosedRange<Double> = 0.3...1
    static let engineVolume: ClosedRange<Double> = 0...1
    static let morphSpeed: ClosedRange<Double> = 0.5...1.5

    /// 到点淡出的**存储**范围（毫秒）。
    ///
    /// 它是界面选项（0/300/600/1000）的超集：导入的备份、旧版本写下的值
    /// 都可能落在这段区间里，所以夹紧要按这个范围来，而不是按界面能选的枚举。
    static let fadeOutMillis: ClosedRange<Int> = 0...3000

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// UserDefaults 实现。App 与测试都可复用，测试建议传独立 suite。
final class UserDefaultsSettingsStore: SettingsStoring, @unchecked Sendable {
    /// 读取一个带范围的数值。
    ///
    /// **不能**用 `value == 0 ? 默认值 : value` 判断"没设置过"：
    /// `0` 本身可能是合法值——最典型的就是音量。
    /// 旧实现里 `engineVolume` 读到 0 会返回 1（满音量），
    /// 也就是"用户把音量拉到 0，重启后变成最大声"。
    private func number(_ key: String, default fallback: Double, in range: ClosedRange<Double>) -> Double {
        guard let stored = defaults.object(forKey: key) as? Double else { return fallback }
        return min(max(stored, range.lowerBound), range.upperBound)
    }


    private enum Key {
        static let enableNetwork = "settings.enableNetwork"
        static let preferredQuality = "settings.preferredQuality"
        static let legacyBiliQuality = "settings.biliQuality"
        static let privacyMode = "settings.privacyMode"
        static let lyricFontSize = "settings.lyricFontSize"
        static let lyricLineSpacing = "settings.lyricLineSpacing"
        static let floatingOpacity = "settings.floatingOpacity"
        static let floatingAppearance = "settings.floatingAppearance"
        static let lyricLayout = "settings.lyricLayout"
        static let defaultShape = "settings.defaultShape"
        static let autoAvoid = "settings.autoAvoid"
        static let engineVolume = "settings.engineVolume"
        static let fadeOutMillis = "settings.fadeOutMillis"
        static let meetingAppsRaw = "settings.meetingApps"
        static let pauseOnUnplug = "settings.pauseOnHeadphoneUnplug"
        static let hideDockIcon = "settings.hideDockIcon"
        static let autoMorph = "settings.autoMorph"
        static let morphSpeed = "settings.morphSpeed"
        static let defaultMorphology = "settings.defaultMorphology"
        static let autoExpandPolicy = "settings.autoExpandPolicy"
        static let autoCollapseOnDeactivate = "settings.autoCollapseOnDeactivate"
        static let loudnessNormalizationEnabled = "settings.loudnessNormalizationEnabled"
        static let eqPresetRaw = "settings.eqPreset"
        static let eqBandsRaw = "settings.eqBands"
        static let showLyricTranslation = "settings.showLyricTranslation"
        static let immersiveScene = "settings.immersiveScene"
        static let immersiveResponse = "settings.immersiveResponse"
        static let immersiveEntersFullScreen = "settings.immersiveEntersFullScreen"
        static let immersivePowerSaving = "settings.immersivePowerSaving"
        static let immersiveBeatSync = "settings.immersiveBeatSync"
        static let playerBackground = "settings.playerBackground"
        static let voiceAIEnabled = "settings.voiceAIEnabled"
        static let voiceSelectedPack = "settings.voiceSelectedPack"
        static let voiceQualityMode = "settings.voiceQualityMode"
        static let voiceEntryVisible = "settings.voiceEntryVisible"
        static let hasSeenOnboarding = "settings.hasSeenOnboarding"
        static let voiceMirrorModeRaw = "settings.voiceMirrorModeRaw"
        static let voiceCustomHFMirror = "settings.voiceCustomHFMirror"
        static let voiceCustomGitHubMirror = "settings.voiceCustomGitHubMirror"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = RuntimeSandbox.defaults) {
        self.defaults = defaults
    }

    /// 仅供测试：验证"写回真的落到 UserDefaults"时用同一个 suite 再读一次。
    var defaultsForTesting: UserDefaults { defaults }


    var preferredQualityRaw: String {
        get {
            lock.withLock {
                defaults.string(forKey: Key.preferredQuality)
                    ?? defaults.string(forKey: Key.legacyBiliQuality)
                    ?? ""
            }
        }
        set { lock.withLock { defaults.set(newValue, forKey: Key.preferredQuality) } }
    }

    var enableNetwork: Bool {
        lock.lock(); defer { lock.unlock() }
        // 联网为默认允许状态；用户可在「网络与隐私」随时显式关闭。
        if defaults.object(forKey: Key.enableNetwork) == nil { return true }
        return defaults.bool(forKey: Key.enableNetwork)
    }


    var isPrivacyMode: Bool {
        lock.lock(); defer { lock.unlock() }
        return defaults.bool(forKey: Key.privacyMode)
    }

    var lyricFontSize: Double {
        lock.lock(); defer { lock.unlock() }
        return number(Key.lyricFontSize, default: 15, in: SettingsLimits.lyricFontSize)
    }

    var lyricLineSpacing: Double {
        lock.lock(); defer { lock.unlock() }
        return number(Key.lyricLineSpacing, default: 8, in: SettingsLimits.lyricLineSpacing)
    }

    var floatingOpacity: Double {
        lock.lock(); defer { lock.unlock() }
        return number(Key.floatingOpacity, default: 0.95, in: SettingsLimits.floatingOpacity)
    }

    var floatingAppearanceRaw: String {
        lock.withLock { defaults.string(forKey: Key.floatingAppearance) ?? FloatingAppearanceMode.background.rawValue }
    }

    func setFloatingAppearanceRaw(_ value: String) async {
        lock.withLock { defaults.set(value, forKey: Key.floatingAppearance) }
    }

    var lyricLayoutRaw: String {
        lock.withLock { defaults.string(forKey: Key.lyricLayout) ?? LyricLayout.appleMusic.rawValue }
    }

    func setLyricLayoutRaw(_ value: String) async {
        lock.withLock { defaults.set(value, forKey: Key.lyricLayout) }
    }

    var defaultShape: LyricsShape {
        lock.lock(); defer { lock.unlock() }
        guard let raw = defaults.string(forKey: Key.defaultShape) else { return .capsule }
        return LyricsShape(rawValue: raw) ?? .capsule
    }

    var autoAvoidEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        guard defaults.object(forKey: Key.autoAvoid) != nil else { return true }
        return defaults.bool(forKey: Key.autoAvoid)
    }

    var engineVolume: Double {
        lock.lock(); defer { lock.unlock() }
        // 0 是合法值（静音）。默认 0.7 而不是 1.0：全新用户首启不该被满音量吓到，
        // 尤其是戴耳机的场景。0.7 与 Spotify/Apple Music 的开箱默认接近。
        return number(Key.engineVolume, default: 0.7, in: SettingsLimits.engineVolume)
    }

    var fadeOutMillis: Int {
        lock.lock(); defer { lock.unlock() }
        guard defaults.object(forKey: Key.fadeOutMillis) != nil else { return 600 }  // 未设置过时的默认值
        return min(max(defaults.integer(forKey: Key.fadeOutMillis),
                       SettingsLimits.fadeOutMillis.lowerBound), SettingsLimits.fadeOutMillis.upperBound)
    }

    var meetingAppsRaw: String {
        lock.lock(); defer { lock.unlock() }
        return defaults.string(forKey: Key.meetingAppsRaw) ?? ""
    }

    var pauseOnHeadphoneUnplug: Bool {
        lock.lock(); defer { lock.unlock() }
        guard defaults.object(forKey: Key.pauseOnUnplug) != nil else { return true }
        return defaults.bool(forKey: Key.pauseOnUnplug)
    }

    var hideDockIcon: Bool {
        lock.lock(); defer { lock.unlock() }
        return defaults.bool(forKey: Key.hideDockIcon)
    }

    var autoMorphEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        guard defaults.object(forKey: Key.autoMorph) != nil else { return true }
        return defaults.bool(forKey: Key.autoMorph)
    }

    var morphTransitionSpeed: Double {
        lock.lock(); defer { lock.unlock() }
        guard defaults.object(forKey: Key.morphSpeed) != nil else { return 1 }
        return min(max(defaults.double(forKey: Key.morphSpeed), 0.5), 1.5)
    }

    var defaultMorphologyRaw: String {
        lock.lock(); defer { lock.unlock() }
        return defaults.string(forKey: Key.defaultMorphology) ?? PlayerMorphology.expanded.rawValue
    }

    var autoExpandPolicyRaw: String {
        lock.lock(); defer { lock.unlock() }
        return defaults.string(forKey: Key.autoExpandPolicy) ?? "balanced"
    }

    var autoCollapseOnDeactivate: Bool {
        lock.lock(); defer { lock.unlock() }
        // 默认关闭：不是所有人都喜欢切走后自动浮出窗口，需在主页或设置里开启。
        guard defaults.object(forKey: Key.autoCollapseOnDeactivate) != nil else { return false }
        return defaults.bool(forKey: Key.autoCollapseOnDeactivate)
    }

    var loudnessNormalizationEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        guard defaults.object(forKey: Key.loudnessNormalizationEnabled) != nil else { return true }
        return defaults.bool(forKey: Key.loudnessNormalizationEnabled)
    }

    var eqPresetRaw: String {
        lock.withLock { defaults.string(forKey: Key.eqPresetRaw) ?? EqualizerPreset.off.rawValue }
    }

    var eqBandsRaw: String {
        lock.withLock {
            let stored = defaults.string(forKey: Key.eqBandsRaw) ?? ""
            return stored.isEmpty ? EqualizerSpec.serializeBands(EqualizerPreset.off.defaultGainsDB) : stored
        }
    }

    func setAutoCollapseOnDeactivate(_ value: Bool) async {
        lock.withLock { defaults.set(value, forKey: Key.autoCollapseOnDeactivate) }
    }

    func setLoudnessNormalizationEnabled(_ value: Bool) async {
        lock.withLock { defaults.set(value, forKey: Key.loudnessNormalizationEnabled) }
    }

    func setEQPresetRaw(_ value: String) async {
        let valid = EqualizerPreset(rawValue: value)?.rawValue ?? EqualizerPreset.off.rawValue
        lock.withLock { defaults.set(valid, forKey: Key.eqPresetRaw) }
    }

    func setEQBandsRaw(_ value: String) async {
        let serialized = EqualizerSpec.serializeBands(EqualizerSpec.parseBands(value))
        lock.withLock { defaults.set(serialized, forKey: Key.eqBandsRaw) }
    }

    var showLyricTranslation: Bool {
        lock.withLock {
            defaults.object(forKey: Key.showLyricTranslation) as? Bool ?? true
        }
    }

    func setShowLyricTranslation(_ value: Bool) async {
        lock.withLock { defaults.set(value, forKey: Key.showLyricTranslation) }
    }

    // 场景与幅度读出时也要校验：偏好可能被旧版本或手工改坏，
    // 原样交出去会让视图层各自兜底，兜法一不一致就出现"设置页显示流光、画面却是别的"。
    var immersiveSceneRaw: String {
        lock.withLock {
            let stored = defaults.string(forKey: Key.immersiveScene) ?? ""
            return (ImmersiveSceneKind(rawValue: stored) ?? .default).rawValue
        }
    }

    func setImmersiveSceneRaw(_ value: String) async {
        let valid = (ImmersiveSceneKind(rawValue: value) ?? .default).rawValue
        lock.withLock { defaults.set(valid, forKey: Key.immersiveScene) }
    }

    var immersiveResponseRaw: String {
        lock.withLock {
            let stored = defaults.string(forKey: Key.immersiveResponse) ?? ""
            return (ImmersiveResponse(rawValue: stored) ?? .default).rawValue
        }
    }

    func setImmersiveResponseRaw(_ value: String) async {
        let valid = (ImmersiveResponse(rawValue: value) ?? .default).rawValue
        lock.withLock { defaults.set(valid, forKey: Key.immersiveResponse) }
    }

    var immersiveEntersFullScreen: Bool {
        lock.withLock {
            defaults.object(forKey: Key.immersiveEntersFullScreen) as? Bool ?? true
        }
    }

    func setImmersiveEntersFullScreen(_ value: Bool) async {
        lock.withLock { defaults.set(value, forKey: Key.immersiveEntersFullScreen) }
    }

    var immersivePowerSaving: Bool {
        lock.withLock {
            defaults.object(forKey: Key.immersivePowerSaving) as? Bool ?? false
        }
    }

    func setImmersivePowerSaving(_ value: Bool) async {
        lock.withLock { defaults.set(value, forKey: Key.immersivePowerSaving) }
    }

    var immersiveBeatSyncRaw: String {
        lock.withLock {
            let stored = defaults.string(forKey: Key.immersiveBeatSync) ?? ""
            return (ImmersiveBeatSync(rawValue: stored) ?? .default).rawValue
        }
    }

    func setImmersiveBeatSyncRaw(_ value: String) async {
        let valid = (ImmersiveBeatSync(rawValue: value) ?? .default).rawValue
        lock.withLock { defaults.set(valid, forKey: Key.immersiveBeatSync) }
    }

    var playerBackgroundRaw: String {
        lock.withLock {
            let stored = defaults.string(forKey: Key.playerBackground) ?? ""
            return (PlayerBackground(rawValue: stored) ?? .default).rawValue
        }
    }

    func setPlayerBackgroundRaw(_ value: String) async {
        let valid = (PlayerBackground(rawValue: value) ?? .default).rawValue
        lock.withLock { defaults.set(valid, forKey: Key.playerBackground) }
    }

    var voiceAIEnabled: Bool {
        lock.withLock { defaults.object(forKey: Key.voiceAIEnabled) as? Bool ?? false }
    }

    func setVoiceAIEnabled(_ value: Bool) async {
        lock.withLock { defaults.set(value, forKey: Key.voiceAIEnabled) }
    }

    var voiceSelectedPackID: String? {
        lock.withLock { defaults.string(forKey: Key.voiceSelectedPack) }
    }

    func setVoiceSelectedPackID(_ value: String?) async {
        lock.withLock {
            if let value { defaults.set(value, forKey: Key.voiceSelectedPack) }
            else { defaults.removeObject(forKey: Key.voiceSelectedPack) }
        }
    }

    var voiceQualityMode: String {
        lock.withLock {
            let stored = defaults.string(forKey: Key.voiceQualityMode) ?? ""
            return VoiceManager.VoiceQualityMode(rawValue: stored)?.rawValue ?? VoiceManager.VoiceQualityMode.balanced.rawValue
        }
    }

    func setVoiceQualityMode(_ value: String) async {
        let valid = (VoiceManager.VoiceQualityMode(rawValue: value) ?? .balanced).rawValue
        lock.withLock { defaults.set(valid, forKey: Key.voiceQualityMode) }
    }

    var voiceEntryVisible: Bool {
        lock.withLock { defaults.object(forKey: Key.voiceEntryVisible) as? Bool ?? true }
    }

    func setVoiceEntryVisible(_ value: Bool) async {
        lock.withLock { defaults.set(value, forKey: Key.voiceEntryVisible) }
    }

    var hasSeenOnboarding: Bool {
        lock.withLock { defaults.bool(forKey: Key.hasSeenOnboarding) }
    }

    func setHasSeenOnboarding(_ value: Bool) async {
        lock.withLock { defaults.set(value, forKey: Key.hasSeenOnboarding) }
    }

    var voiceMirrorModeRaw: String {
        lock.withLock {
            guard let raw = defaults.string(forKey: Key.voiceMirrorModeRaw),
                  VoiceMirrorMode(rawValue: raw) != nil else {
                return VoiceMirrorMode.hfMirror.rawValue
            }
            return raw
        }
    }

    func setVoiceMirrorModeRaw(_ value: String) async {
        let valid = (VoiceMirrorMode(rawValue: value) ?? .hfMirror).rawValue
        lock.withLock { defaults.set(valid, forKey: Key.voiceMirrorModeRaw) }
    }

    var voiceCustomHFMirror: String {
        lock.withLock {
            VoiceModelMirrorConfig.normalizedBaseURLString(
                defaults.string(forKey: Key.voiceCustomHFMirror) ?? "",
                fallback: VoiceModelMirrorConfig.defaultHFMirrorBase
            )
        }
    }

    func setVoiceCustomHFMirror(_ value: String) async {
        let normalized = VoiceModelMirrorConfig.normalizedBaseURLString(
            value,
            fallback: VoiceModelMirrorConfig.defaultHFMirrorBase
        )
        lock.withLock { defaults.set(normalized, forKey: Key.voiceCustomHFMirror) }
    }

    var voiceCustomGitHubMirror: String {
        lock.withLock {
            VoiceModelMirrorConfig.normalizedOptionalPrefix(
                defaults.string(forKey: Key.voiceCustomGitHubMirror) ?? ""
            )
        }
    }

    func setVoiceCustomGitHubMirror(_ value: String) async {
        let normalized = VoiceModelMirrorConfig.normalizedOptionalPrefix(value)
        lock.withLock { defaults.set(normalized, forKey: Key.voiceCustomGitHubMirror) }
    }

    func setAutoMorphEnabled(_ value: Bool) async {
        lock.withLock { defaults.set(value, forKey: Key.autoMorph) }
    }

    func setPreferredQualityRaw(_ value: String) async {
        lock.withLock { defaults.set(value, forKey: Key.preferredQuality) }
    }

    func setMorphTransitionSpeed(_ value: Double) async {
        lock.withLock {
            defaults.set(SettingsLimits.clamp(value, to: SettingsLimits.morphSpeed), forKey: Key.morphSpeed)
        }
    }

    func setDefaultMorphologyRaw(_ value: String) async {
        lock.withLock { defaults.set(value, forKey: Key.defaultMorphology) }
    }

    func setAutoExpandPolicyRaw(_ value: String) async {
        lock.withLock { defaults.set(value, forKey: Key.autoExpandPolicy) }
    }


    func setEnableNetwork(_ value: Bool) async {
        lock.withLock { defaults.set(value, forKey: Key.enableNetwork) }
    }

    func setPrivacyMode(_ value: Bool) async {
        lock.withLock { defaults.set(value, forKey: Key.privacyMode) }
    }

    func setLyricFontSize(_ value: Double) async {
        lock.withLock { defaults.set(SettingsLimits.clamp(value, to: SettingsLimits.lyricFontSize), forKey: Key.lyricFontSize) }
    }

    func setLyricLineSpacing(_ value: Double) async {
        lock.withLock { defaults.set(SettingsLimits.clamp(value, to: SettingsLimits.lyricLineSpacing), forKey: Key.lyricLineSpacing) }
    }

    func setFloatingOpacity(_ value: Double) async {
        lock.withLock { defaults.set(SettingsLimits.clamp(value, to: SettingsLimits.floatingOpacity), forKey: Key.floatingOpacity) }
    }

    func setDefaultShape(_ shape: LyricsShape) async {
        lock.withLock { defaults.set(shape.rawValue, forKey: Key.defaultShape) }
    }

    func setAutoAvoidEnabled(_ value: Bool) async {
        lock.withLock { defaults.set(value, forKey: Key.autoAvoid) }
    }

    func setEngineVolume(_ value: Double) async {
        lock.withLock { defaults.set(SettingsLimits.clamp(value, to: SettingsLimits.engineVolume), forKey: Key.engineVolume) }
    }

    func setFadeOutMillis(_ value: Int) async {
        lock.withLock {
            defaults.set(min(max(value, SettingsLimits.fadeOutMillis.lowerBound),
                             SettingsLimits.fadeOutMillis.upperBound), forKey: Key.fadeOutMillis)
        }
    }

    func setMeetingAppsRaw(_ value: String) async {
        lock.withLock { defaults.set(value, forKey: Key.meetingAppsRaw) }
    }

    func setPauseOnHeadphoneUnplug(_ value: Bool) async {
        lock.withLock { defaults.set(value, forKey: Key.pauseOnUnplug) }
    }

    func setHideDockIcon(_ value: Bool) async {
        lock.withLock { defaults.set(value, forKey: Key.hideDockIcon) }
    }
}

/// 测试用的纯内存设置。
final class InMemorySettingsStore: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _enableNetwork: Bool
    private var _privacyMode: Bool
    private var _lyricFontSize: Double
    private var _lyricLineSpacing: Double
    private var _floatingOpacity: Double
    private var _floatingAppearance: String = FloatingAppearanceMode.background.rawValue
    private var _lyricLayout: String = LyricLayout.appleMusic.rawValue
    private var _defaultShape: LyricsShape = .capsule
    private var _autoAvoidEnabled: Bool = true
    private var _engineVolume: Double = 0.7
    private var _fadeOutMillis: Int = 600
    private var _meetingAppsRaw: String = ""
    private var _pauseOnUnplug: Bool = true
    private var _hideDockIcon: Bool = false
    private var _autoMorph: Bool = true
    private var _morphSpeed: Double = 1
    private var _defaultMorphology: String = PlayerMorphology.expanded.rawValue
    private var _autoExpandPolicy: String = "balanced"
    private var _preferredQuality: String = ""
    private var _autoCollapseOnDeactivate: Bool = false
    private var _loudnessNormalizationEnabled: Bool = true
    private var _eqPresetRaw: String = EqualizerPreset.off.rawValue
    private var _eqBandsRaw: String = EqualizerSpec.serializeBands(EqualizerPreset.off.defaultGainsDB)
    private var _showLyricTranslation: Bool = true
    private var _immersiveScene: String = ImmersiveSceneKind.default.rawValue
    private var _immersiveResponse: String = ImmersiveResponse.default.rawValue
    private var _immersiveEntersFullScreen: Bool = true
    private var _immersivePowerSaving: Bool = false
    private var _immersiveBeatSync: String = ImmersiveBeatSync.default.rawValue
    private var _playerBackground: String = PlayerBackground.default.rawValue
    private var _voiceAIEnabled: Bool = false
    private var _voiceSelectedPackID: String? = nil
    private var _voiceQualityMode: String = "balanced"
    private var _voiceEntryVisible: Bool = true
    /// 测试默认「已经看过」：引导层会盖住整窗，渲染/交互用例不该被它挡住。
    /// 要测引导本身就把 `hasSeenOnboarding: false` 传进来。
    private var _hasSeenOnboarding: Bool = true
    private var _voiceMirrorModeRaw: String = VoiceMirrorMode.hfMirror.rawValue
    private var _voiceCustomHFMirror: String = VoiceModelMirrorConfig.defaultHFMirrorBase
    private var _voiceCustomGitHubMirror: String = ""

    init(enableNetwork: Bool = false,
         privacyMode: Bool = false,
         lyricFontSize: Double = 15,
         lyricLineSpacing: Double = 8,
         floatingOpacity: Double = 0.95,
         hasSeenOnboarding: Bool = true) {
        _enableNetwork = enableNetwork
        _privacyMode = privacyMode
        _lyricFontSize = lyricFontSize
        _lyricLineSpacing = lyricLineSpacing
        _floatingOpacity = floatingOpacity
        _hasSeenOnboarding = hasSeenOnboarding
    }


    var enableNetwork: Bool { lock.lock(); defer { lock.unlock() }; return _enableNetwork }
    var isPrivacyMode: Bool { lock.lock(); defer { lock.unlock() }; return _privacyMode }
    var lyricFontSize: Double { lock.lock(); defer { lock.unlock() }
        return SettingsLimits.clamp(_lyricFontSize, to: SettingsLimits.lyricFontSize) }
    var lyricLineSpacing: Double { lock.lock(); defer { lock.unlock() }
        return SettingsLimits.clamp(_lyricLineSpacing, to: SettingsLimits.lyricLineSpacing) }
    var floatingOpacity: Double { lock.lock(); defer { lock.unlock() }
        return SettingsLimits.clamp(_floatingOpacity, to: SettingsLimits.floatingOpacity) }
    var floatingAppearanceRaw: String { lock.withLock { _floatingAppearance } }
    func setFloatingAppearanceRaw(_ value: String) async { lock.withLock { _floatingAppearance = value } }
    var lyricLayoutRaw: String { lock.withLock { _lyricLayout } }
    func setLyricLayoutRaw(_ value: String) async { lock.withLock { _lyricLayout = value } }
    var defaultShape: LyricsShape { lock.lock(); defer { lock.unlock() }; return _defaultShape }
    var autoAvoidEnabled: Bool { lock.lock(); defer { lock.unlock() }; return _autoAvoidEnabled }
    var engineVolume: Double { lock.lock(); defer { lock.unlock() }
        return SettingsLimits.clamp(_engineVolume, to: SettingsLimits.engineVolume) }
    var fadeOutMillis: Int { lock.lock(); defer { lock.unlock() }; return _fadeOutMillis }
    var meetingAppsRaw: String { lock.lock(); defer { lock.unlock() }; return _meetingAppsRaw }
    var pauseOnHeadphoneUnplug: Bool { lock.lock(); defer { lock.unlock() }; return _pauseOnUnplug }
    var hideDockIcon: Bool { lock.lock(); defer { lock.unlock() }; return _hideDockIcon }
    var autoMorphEnabled: Bool { lock.lock(); defer { lock.unlock() }; return _autoMorph }
    var morphTransitionSpeed: Double { lock.lock(); defer { lock.unlock() }; return _morphSpeed }
    var defaultMorphologyRaw: String { lock.lock(); defer { lock.unlock() }; return _defaultMorphology }
    var autoExpandPolicyRaw: String { lock.lock(); defer { lock.unlock() }; return _autoExpandPolicy }
    var autoCollapseOnDeactivate: Bool { lock.lock(); defer { lock.unlock() }; return _autoCollapseOnDeactivate }
    var loudnessNormalizationEnabled: Bool { lock.lock(); defer { lock.unlock() }; return _loudnessNormalizationEnabled }
    var eqPresetRaw: String { lock.lock(); defer { lock.unlock() }; return _eqPresetRaw }
    var eqBandsRaw: String { lock.lock(); defer { lock.unlock() }; return _eqBandsRaw }
    var showLyricTranslation: Bool { lock.lock(); defer { lock.unlock() }; return _showLyricTranslation }
    var immersiveSceneRaw: String { lock.withLock { _immersiveScene } }
    var immersiveResponseRaw: String { lock.withLock { _immersiveResponse } }
    var immersiveEntersFullScreen: Bool { lock.withLock { _immersiveEntersFullScreen } }
    var immersivePowerSaving: Bool { lock.withLock { _immersivePowerSaving } }
    var immersiveBeatSyncRaw: String { lock.withLock { _immersiveBeatSync } }
    var playerBackgroundRaw: String { lock.withLock { _playerBackground } }
    var voiceAIEnabled: Bool { lock.withLock { _voiceAIEnabled } }
    var voiceSelectedPackID: String? { lock.withLock { _voiceSelectedPackID } }
    var voiceQualityMode: String { lock.withLock { _voiceQualityMode } }
    var voiceEntryVisible: Bool { lock.withLock { _voiceEntryVisible } }
    var hasSeenOnboarding: Bool { lock.withLock { _hasSeenOnboarding } }
    var voiceMirrorModeRaw: String { lock.withLock { _voiceMirrorModeRaw } }
    var voiceCustomHFMirror: String { lock.withLock { _voiceCustomHFMirror } }
    var voiceCustomGitHubMirror: String { lock.withLock { _voiceCustomGitHubMirror } }
    var preferredQualityRaw: String {
        get { lock.lock(); defer { lock.unlock() }; return _preferredQuality }
        set { lock.lock(); defer { lock.unlock() }; _preferredQuality = newValue }
    }

    func setEnableNetwork(_ value: Bool) async { lock.withLock { _enableNetwork = value } }
    func setPrivacyMode(_ value: Bool) async { lock.withLock { _privacyMode = value } }
    func setLyricFontSize(_ value: Double) async {
        lock.withLock { _lyricFontSize = SettingsLimits.clamp(value, to: SettingsLimits.lyricFontSize) }
    }
    func setLyricLineSpacing(_ value: Double) async {
        lock.withLock { _lyricLineSpacing = SettingsLimits.clamp(value, to: SettingsLimits.lyricLineSpacing) }
    }
    func setFloatingOpacity(_ value: Double) async {
        lock.withLock { _floatingOpacity = SettingsLimits.clamp(value, to: SettingsLimits.floatingOpacity) }
    }
    func setDefaultShape(_ shape: LyricsShape) async { lock.withLock { _defaultShape = shape } }
    func setAutoAvoidEnabled(_ value: Bool) async { lock.withLock { _autoAvoidEnabled = value } }
    func setAutoCollapseOnDeactivate(_ value: Bool) async { lock.withLock { _autoCollapseOnDeactivate = value } }
    func setLoudnessNormalizationEnabled(_ value: Bool) async { lock.withLock { _loudnessNormalizationEnabled = value } }
    func setEQPresetRaw(_ value: String) async {
        let valid = EqualizerPreset(rawValue: value)?.rawValue ?? EqualizerPreset.off.rawValue
        lock.withLock { _eqPresetRaw = valid }
    }
    func setEQBandsRaw(_ value: String) async {
        let serialized = EqualizerSpec.serializeBands(EqualizerSpec.parseBands(value))
        lock.withLock { _eqBandsRaw = serialized }
    }
    func setShowLyricTranslation(_ value: Bool) async { lock.withLock { _showLyricTranslation = value } }
    // 与 `UserDefaultsSettingsStore` 同一套校验：未知值落成默认场景 / 默认幅度。
    func setImmersiveSceneRaw(_ value: String) async {
        let valid = (ImmersiveSceneKind(rawValue: value) ?? .default).rawValue
        lock.withLock { _immersiveScene = valid }
    }
    func setImmersiveResponseRaw(_ value: String) async {
        let valid = (ImmersiveResponse(rawValue: value) ?? .default).rawValue
        lock.withLock { _immersiveResponse = valid }
    }
    func setImmersiveEntersFullScreen(_ value: Bool) async { lock.withLock { _immersiveEntersFullScreen = value } }
    func setImmersivePowerSaving(_ value: Bool) async { lock.withLock { _immersivePowerSaving = value } }
    func setImmersiveBeatSyncRaw(_ value: String) async {
        let valid = (ImmersiveBeatSync(rawValue: value) ?? .default).rawValue
        lock.withLock { _immersiveBeatSync = valid }
    }

    func setPlayerBackgroundRaw(_ value: String) async {
        let valid = (PlayerBackground(rawValue: value) ?? .default).rawValue
        lock.withLock { _playerBackground = valid }
    }
    func setVoiceAIEnabled(_ value: Bool) async { lock.withLock { _voiceAIEnabled = value } }
    func setVoiceSelectedPackID(_ value: String?) async { lock.withLock { _voiceSelectedPackID = value } }
    func setVoiceQualityMode(_ value: String) async {
        let valid = (VoiceManager.VoiceQualityMode(rawValue: value) ?? .balanced).rawValue
        lock.withLock { _voiceQualityMode = valid }
    }
    func setVoiceEntryVisible(_ value: Bool) async { lock.withLock { _voiceEntryVisible = value } }
    func setHasSeenOnboarding(_ value: Bool) async { lock.withLock { _hasSeenOnboarding = value } }
    func setVoiceMirrorModeRaw(_ value: String) async {
        let valid = (VoiceMirrorMode(rawValue: value) ?? .hfMirror).rawValue
        lock.withLock { _voiceMirrorModeRaw = valid }
    }
    func setVoiceCustomHFMirror(_ value: String) async {
        let normalized = VoiceModelMirrorConfig.normalizedBaseURLString(
            value,
            fallback: VoiceModelMirrorConfig.defaultHFMirrorBase
        )
        lock.withLock { _voiceCustomHFMirror = normalized }
    }
    func setVoiceCustomGitHubMirror(_ value: String) async {
        let normalized = VoiceModelMirrorConfig.normalizedOptionalPrefix(value)
        lock.withLock { _voiceCustomGitHubMirror = normalized }
    }
    func setEngineVolume(_ value: Double) async {
        lock.withLock { _engineVolume = SettingsLimits.clamp(value, to: SettingsLimits.engineVolume) }
    }
    func setFadeOutMillis(_ value: Int) async {
        // 与 `UserDefaultsSettingsStore` 保持**同一套夹紧**。
        // 之前这里直接赋值：降级模式（内存存储）下导入 99999 ms 的备份会原样存下，
        // 到点淡出变得离谱地长——两个实现对同一份输入的边界不一致。
        lock.withLock {
            _fadeOutMillis = min(max(value, SettingsLimits.fadeOutMillis.lowerBound),
                                 SettingsLimits.fadeOutMillis.upperBound)
        }
    }
    func setMeetingAppsRaw(_ value: String) async { lock.withLock { _meetingAppsRaw = value } }
    func setPauseOnHeadphoneUnplug(_ value: Bool) async { lock.withLock { _pauseOnUnplug = value } }
    func setHideDockIcon(_ value: Bool) async { lock.withLock { _hideDockIcon = value } }
    func setAutoMorphEnabled(_ value: Bool) async { lock.withLock { _autoMorph = value } }
    func setPreferredQualityRaw(_ value: String) async { lock.withLock { _preferredQuality = value } }
    func setMorphTransitionSpeed(_ value: Double) async {
        lock.withLock { _morphSpeed = SettingsLimits.clamp(value, to: SettingsLimits.morphSpeed) }
    }
    func setDefaultMorphologyRaw(_ value: String) async { lock.withLock { _defaultMorphology = value } }
    func setAutoExpandPolicyRaw(_ value: String) async { lock.withLock { _autoExpandPolicy = value } }
}
