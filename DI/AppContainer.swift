import Foundation

/// 依赖容器。全工程唯一的组装点。
///
/// 表现层只拿到协议：`PlaybackControlling`、`LyricsProviding`、`SettingsStoring`。
/// 换源只改 `ContainerBuilder` 里的一行注册，播放层/歌词层/UI 一行不动。
@MainActor
final class AppContainer {
    let sourceRegistry: SourceRegistry
    let sourceManager: SourceManager
    let playback: any PlaybackControlling
    let playbackEngine: PlaybackEngine
    let settings: any SettingsStoring
    let tracks: any TrackRepository
    let persistence: PersistenceController
    /// 非 nil 表示这次运行是**降级模式**（容器构建失败，用内存设置 + 模拟源顶着）。
    /// 必须在界面上如实告知：否则用户会以为"App 坏了"或"怎么全是示例曲目"。
    var degradedReason: String?
    let clock: any PlaybackClock
    let nowPlaying: any NowPlayingBridging
    let floatingLyrics: any FloatingLyricsControlling
    /// 形态系统的唯一入口。主窗口、菜单栏、快捷设置都只认这个协议。
    let morph: any MorphControlling
    let lyricEngine: LyricEngine
    let lyricBindings: LyricBindingStore
    let lyricVariants: LyricVariantCoordinator
    let library: any LibraryStoring
    /// FLOW 自己的歌单（不是平台收藏夹）。
    let playlists: any PlaylistStoring
    let offline: OfflineLibraryManager
    let systemMedia: SystemMediaIntegration
    let privacy: PrivacyState
    let appearance: AppearanceSettings
    let widgetBridge: WidgetBridge
    let sessionPersistence: PlaybackSessionPersistence
    let networkMonitor: NetworkConnectivityMonitor
    let relatedRadio: RelatedRadioDriver
    let playbackRecovery: PlaybackRecoveryDriver
    /// 睡眠定时驱动器。`SleepTimerDriver` 是 @MainActor，构造发生在 MainActor 上，
    /// 所以由 AppDelegate 启动时挂进来，而不是塞进 init 参数表。
    private(set) var sleepTimer: SleepTimerDriver?
    /// 输出设备监听（耳机拔出暂停）。@MainActor，同样由启动时挂载。
    private(set) var audioRouteMonitor: AudioRouteMonitor?
    /// FLOW Voice：AI 翻唱门面（导入音色/选音色/开 AI 播放）。fallback 容器可为 nil。
    let voice: VoiceManager?
    /// FLOW Voice 播放驱动：必须随容器强持有至销毁，否则 `VoiceContainer` 中所有 `[weak driver]` 回调会在初始化后立即释放失效。
    let voiceDriver: VoicePlaybackDriver?

    /// 收藏 / 取消收藏一首歌。返回操作之后是否处于收藏状态。
    ///
    /// **所有界面都走这里**，不要直接调 `library.toggleFavorite(identity)`：
    /// 收藏表只存身份，歌名和封面要靠曲目库还原。在列表里右键收藏一首**没播过**的歌时，
    /// 曲目库里根本没有它——星标点亮了，收藏抽屉里却永远看不到这一行，重启后也一样。
    @discardableResult
    func toggleFavorite(_ track: Track) async -> Bool {
        try? await tracks.save(track)
        return await library.toggleFavorite(track.identity)
    }

    @discardableResult
    func downloadOffline(_ track: Track) async -> Bool {
        try? await tracks.save(track)
        let saved = await offline.download(track, using: sourceManager)
        if saved, let resolved = offline.savedTrack(for: track.identity) {
            try? await tracks.save(resolved)
        }
        return saved
    }

    @discardableResult
    func downloadOffline(_ items: [Track]) async -> Int {
        for item in items { try? await tracks.save(item) }
        return await offline.downloadAll(items, using: sourceManager)
    }

    func removeOffline(_ track: Track) async {
        await offline.remove(track)
    }

    /// 次级内容（队列/设置抽屉）打开时通知形态系统：禁止自动收缩。
    func noteAuxiliaryActivity(_ isActive: Bool) {
        morph.noteAuxiliaryActivity(isActive)
    }

    /// 切换「显示中文译文」并同步设置快照与悬浮窗口视图。
    func setShowLyricTranslation(_ enabled: Bool) {
        floatingLyrics.applyShowLyricTranslation(enabled)
    }

    /// 切换「允许联网」开关并实时同步在线源注册表。
    /// 导入设置备份后，把只在启动时读过一次的设置重新推到运行时：
    /// 外观/均衡/隐私快照、音量、音质、淡出时长、耳机策略与 Voice。Dock 图标由界面层负责。
    func reloadSettingsAfterImport() async {
        await setEnableNetwork(settings.enableNetwork)
        setShowLyricTranslation(settings.showLyricTranslation)
        appearance.reloadFromStore()
        privacy.reloadFromStore()
        playback.setVolume(Float(settings.engineVolume))
        sleepTimer?.fadeOutDuration = .milliseconds(appearance.fadeOutMillis)
        audioRouteMonitor?.setPolicy(AudioRoutePolicy(pauseOnHeadphoneUnplug: settings.pauseOnHeadphoneUnplug))
        // 空串是"自动"的常态值（从没选过音质）。之前只在能解析出档位时才推送，
        // 于是导入一份"自动"备份后，已经注册的源还停在上一档。自动也要显式推一次。
        await sourceManager.applyPreferredQuality(AudioQualityTier(rawValue: settings.preferredQualityRaw) ?? .auto)
        voice?.reloadSettings()
    }

    func setEnableNetwork(_ enabled: Bool) async {
        await settings.setEnableNetwork(enabled)
        sourceManager.syncNetworkState()
        voice?.networkSettingChanged()
    }

    /// 供设置页「复制诊断」与「关于」共用。
    func diagnosticsReport() -> String {
        DiagnosticsReport.render(DiagnosticsReport.Facts(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            schemaVersion: PersistenceController.currentSchemaVersion,
            accessibilityState: {
                switch floatingLyrics.accessibilityPermission {
                case .granted: return "已授权"
                case .notGranted: return "未授权"
                case .unavailable: return "不可用"
                case .unknown: return "未知"
                }
            }(),
            queueCount: playback.queueSnapshot.items.count,
            floatingShape: morph.morphology.displayName,
            privacyModeEnabled: privacy.isEnabled,
            sleepTimerArmed: sleepTimer?.isArmed ?? false,
            storageState: Self.storageState(for: persistence),
            runtimeMode: degradedReason == nil ? "正常" : "降级（临时设置，不写盘）",
            widgetShared: SharedStateStore.isSharedContainerAvailable
                ? "可用" : "不可用（未签名或缺少 App Group，小组件读不到数据）"
        ))
    }

    /// 把存储恢复状态翻成一句人话。用户需要知道"数据被从备份恢复过"。
    static func storageState(for persistence: PersistenceController) -> String {
        if persistence.restoredFromBackup { return "本次启动已从备份恢复（可能缺少最近的改动）" }
        if persistence.recoveredFromCorruption {
            let name = persistence.quarantinedFileName ?? "未知文件"
            return "检测到数据库损坏，已隔离为 \(name)，当前为空库"
        }
        return "正常"
    }

    func attachSleepTimer(_ driver: SleepTimerDriver) {
        sleepTimer = driver
    }

    func attachAudioRouteMonitor(_ monitor: AudioRouteMonitor) {
        audioRouteMonitor = monitor
    }

    init(sourceRegistry: SourceRegistry,
         sourceManager: SourceManager,
         playback: any PlaybackControlling,
         playbackEngine: PlaybackEngine,
         settings: any SettingsStoring,
         tracks: any TrackRepository,
         persistence: PersistenceController,
         clock: any PlaybackClock,
         nowPlaying: any NowPlayingBridging,
         floatingLyrics: any FloatingLyricsControlling,
         morph: any MorphControlling,
         lyricEngine: LyricEngine,
         lyricBindings: LyricBindingStore,
         lyricVariants: LyricVariantCoordinator,
         sessionPersistence: PlaybackSessionPersistence,
         library: any LibraryStoring,
         playlists: any PlaylistStoring,
         offline: OfflineLibraryManager,
         systemMedia: SystemMediaIntegration,
         privacy: PrivacyState,
         appearance: AppearanceSettings,
         widgetBridge: WidgetBridge,
         networkMonitor: NetworkConnectivityMonitor,
         relatedRadio: RelatedRadioDriver,
         playbackRecovery: PlaybackRecoveryDriver,
         voice: VoiceManager? = nil,
         voiceDriver: VoicePlaybackDriver? = nil) {
        self.sourceRegistry = sourceRegistry
        self.sourceManager = sourceManager
        self.playback = playback
        self.playbackEngine = playbackEngine
        self.settings = settings
        self.tracks = tracks
        self.persistence = persistence
        self.clock = clock
        self.nowPlaying = nowPlaying
        self.floatingLyrics = floatingLyrics
        self.morph = morph
        self.lyricEngine = lyricEngine
        self.lyricBindings = lyricBindings
        self.lyricVariants = lyricVariants
        self.sessionPersistence = sessionPersistence
        self.library = library
        self.playlists = playlists
        self.offline = offline
        self.systemMedia = systemMedia
        self.privacy = privacy
        self.appearance = appearance
        self.widgetBridge = widgetBridge
        self.networkMonitor = networkMonitor
        self.relatedRadio = relatedRadio
        self.playbackRecovery = playbackRecovery
        self.voice = voice
        self.voiceDriver = voiceDriver
    }
}
