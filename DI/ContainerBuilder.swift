import Foundation

/// 组装工厂。三个模式：真跑、测试（内存库）、预览。
enum ContainerBuilder {
    enum Mode: Sendable {
        case app
        /// 本地数据库打不开时的运行方式：**一切照常，只是不落库**。
        /// 设置仍读写真实的偏好，在线音源照常可用；队列、收藏、历史只活在这次运行里。
        case degraded
        case testing(inMemory: Bool)
        case preview
    }

    @MainActor
    static func make(_ mode: Mode) throws -> AppContainer {
        let clock = SystemPlaybackClock()

        let persistence: PersistenceController
        let settings: any SettingsStoring

        switch mode {
        case .app:
            persistence = try PersistenceController(inMemory: false)
            settings = UserDefaultsSettingsStore()
        case .degraded:
            persistence = try PersistenceController(inMemory: true)
            settings = UserDefaultsSettingsStore()
        case let .testing(inMemory):
            persistence = try PersistenceController(inMemory: inMemory)
            settings = InMemorySettingsStore()
        case .preview:
            persistence = try PersistenceController(inMemory: true)
            settings = InMemorySettingsStore()
        }

        let registry = SourceRegistry()
        let isProduction: Bool
        switch mode {
        case .app, .degraded: isProduction = true
        case .testing, .preview: isProduction = false
        }
        if isProduction {
            MusicCatalogResolver.shared.attach(registry: registry)
        }
        let sourceManager = SourceManager(
            registry: registry,
            networkEnabledProvider: { settings.enableNetwork },
            preferredQualityProvider: { AudioQualityTier(rawValue: settings.preferredQualityRaw) },
            externalPluginsDirectories: isProduction ? nil : [],
            streamingAssetBuilder: StreamingResourceLoaderBridge.makeAsset,
            hlsAssetBuilder: HLSResourceLoaderBridge.makeAsset
        )
        if !isProduction {
            sourceManager.registerSource(
                MockPlaybackSource(behavior: .healthy, clock: clock),
                isBuiltIn: true,
                originLabel: String(localized: "测试模拟源")
            )
        }

        let offlineAudioCache: MediaAudioCache
        if isProduction {
            offlineAudioCache = .shared
        } else {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("flow-test-offline-\(UUID().uuidString)", isDirectory: true)
            offlineAudioCache = MediaAudioCache(
                directory: tempRoot.appendingPathComponent("cache", isDirectory: true),
                offlineDirectory: tempRoot.appendingPathComponent("offline", isDirectory: true)
            )
        }
        let manifestURL = isProduction
            ? RuntimeSandbox.applicationSupportDirectory()?.appendingPathComponent("FLOW/OfflineAudio/manifest.json")
            : nil
        let offline = OfflineLibraryManager(
            audioCache: offlineAudioCache,
            manifestURL: manifestURL,
            qualityProvider: { AudioQualityTier(rawValue: settings.preferredQualityRaw) ?? .auto },
            networkAllowed: { settings.enableNetwork }
        )

        let coordinator = PlaybackCoordinator(registry: registry)
        // 关闭联网时仅本地源注册；优先走本地离线/缓存直连构造会话，找不到再报"联网已关闭"。
        coordinator.isNetworkEnabled = { settings.enableNetwork }
        coordinator.offlineSessionFactory = { [weak offline] track in
            guard let offline else { return nil }
            let quality = AudioQualityTier(rawValue: settings.preferredQualityRaw) ?? .auto
            return try await offline.offlineSession(for: track, quality: quality, onStreamPicked: nil)
        }
        coordinator.offlinePrewarmSessionFactory = { [weak offline] track in
            guard let offline else { return nil }
            let quality = AudioQualityTier(rawValue: settings.preferredQualityRaw) ?? .auto
            return try await offline.offlineSession(for: track, quality: quality, onStreamPicked: nil)
        }
        let engine = PlaybackEngine(clock: clock, coordinator: coordinator)
        let placementStore = SwiftDataPlacementStore(modelContainer: persistence.container)
        let offsetStore = SwiftDataLyricsOffsetStore(modelContainer: persistence.container)
        let bindingDirectory: URL?
        if case .app = mode {
            bindingDirectory = RuntimeSandbox.applicationSupportDirectory()?
                .appendingPathComponent("FLOW/LyricBindings", isDirectory: true)
        } else {
            bindingDirectory = nil
        }
        let lyricBindings = LyricBindingStore(directory: bindingDirectory)
        // 歌词走源：手动绑定优先于 B 站稿件字幕 / 自动外部歌词，离线关闭联网时兜底读本地缓存与 AMLL TTML。
        let lyricEngine = LyricEngine(
            loader: SourceAwareLyricsLoader(registry: registry,
                                            bindingStore: lyricBindings,
                                            externalAggregator: ExternalLyricsAggregator(),
                                            networkAllowed: { settings.enableNetwork },
                                            offlineFallback: { [weak offline] track in
                await offline?.offlineLyrics(for: track)
            }),
            offsets: offsetStore
        )
        let lyricVariants = LyricVariantCoordinator(
            bindingStore: lyricBindings,
            lyricEngine: lyricEngine,
            networkAllowed: { settings.enableNetwork }
        )
        // 手动"换一版歌词"要直接替换歌词引擎里的文档并持久化绑定。
        let libraryStore = SwiftDataLibraryStore(modelContainer: persistence.container)
        let playlistStore = SwiftDataPlaylistStore(modelContainer: persistence.container)
        let sessionPersistence = PlaybackSessionPersistence(
            engine: engine,
            persistence: persistence,
            tracks: persistence.makeTrackRepository()
        )
        let nowPlayingBridge = MediaPlayerNowPlayingBridge()
        let systemMedia = SystemMediaIntegration(bridge: nowPlayingBridge, playback: engine, library: libraryStore)
        // 控制中心封面：集成层不直接认识源，用注册表回查。
        systemMedia.sourceProvider = { id in registry.provider(for: id) }
        systemMedia.isNetworkEnabled = { settings.enableNetwork }
        // 这里必须用按模式选出来的 settings（.app 走 UserDefaults，测试走内存）。
        // 曾经误用了一个新建的 InMemorySettingsStore，导致外观/隐私设置永远读到默认值：
        // 迷你模式恢复不了、置顶失效、字号行距不持久——全部由这一行引起。
        let privacy = PrivacyState(settings: settings)
        // 隐私态必须投影到系统"正在播放"：否则 App 内隐藏了歌名，
        // 锁屏/控制中心照常显示真实标题（用户开隐私模式就是为了不让别人看到）。
        systemMedia.isPrivacyMasked = { [weak privacy] in privacy?.isMasking ?? false }
        let appearance = AppearanceSettings(settings: settings)
        let widgetBridge = WidgetBridge(playback: engine, lyricEngine: lyricEngine, privacy: privacy)
        // 形态窗口：五种形态的唯一载体。旧的 FloatingPanelController 已完成迁移。
        let overlay = MorphWindowController(playback: engine,
                                            lyricEngine: lyricEngine,
                                            privacy: privacy,
                                            appearance: appearance,
                                            placements: placementStore,
                                            trackRepository: persistence.makeTrackRepository(),
                                            preferences: UserDefaultsMorphPreferenceStore())

        let (networkMonitor, relatedRadio, playbackRecovery) = Self.makeRuntimeDrivers(
            engine: engine,
            sourceManager: sourceManager,
            clock: clock
        )

        // FLOW Voice：原生 Swift + ONNX Runtime AI 翻唱子系统。
        let voiceStack = VoiceContainer.attach(
            to: coordinator,
            playback: engine,
            settings: settings,
            offline: offline,
            offlineResolver: sourceManager,
            registry: registry,
            production: isProduction
        )

        let container = AppContainer(
            sourceRegistry: registry,
            sourceManager: sourceManager,
            playback: engine,
            playbackEngine: engine,
            settings: settings,
            tracks: persistence.makeTrackRepository(),
            persistence: persistence,
            clock: clock,
            nowPlaying: nowPlayingBridge,
            floatingLyrics: overlay,
            morph: overlay,
            lyricEngine: lyricEngine,
            lyricBindings: lyricBindings,
            lyricVariants: lyricVariants,
            sessionPersistence: sessionPersistence,
            library: libraryStore,
            playlists: playlistStore,
            offline: offline,
            systemMedia: systemMedia,
            privacy: privacy,
            appearance: appearance,
            widgetBridge: widgetBridge,
            networkMonitor: networkMonitor,
            relatedRadio: relatedRadio,
            playbackRecovery: playbackRecovery,
            voice: voiceStack.manager,
            voiceDriver: voiceStack.driver
        )
        // 容器构造完成后回填给窗口层：视图树里的 `\.app` 靠它注入。
        overlay.appContainer = container
        if isProduction {
            appearance.syncAudioEffects()
            relatedRadio.start()
            playbackRecovery.start()
            Task { @MainActor in
                await sourceManager.restoreStandardSources()
                await voiceStack.manager.attach()
            }
        }
        Self.wirePrivacy(privacy, systemMedia: systemMedia, widgetBridge: widgetBridge, overlay: overlay)
        return container
    }

    /// 创建联网监测、关联电台与播放恢复驱动（主容器与兜底容器共用）。
    @MainActor
    private static func makeRuntimeDrivers(
        engine: PlaybackEngine,
        sourceManager: SourceManager,
        clock: any PlaybackClock
    ) -> (NetworkConnectivityMonitor, RelatedRadioDriver, PlaybackRecoveryDriver) {
        let networkMonitor = NetworkConnectivityMonitor()
        let relatedRadio = RelatedRadioDriver(
            playback: engine,
            relatedProvider: { [weak sourceManager] track, limit in
                guard let provider = await MainActor.run(body: {
                    sourceManager?.relatedProvider(for: track.sourceID)
                }) else { return [] }
                return try await provider.relatedTracks(for: track, limit: limit)
            }
        )
        let playbackRecovery = PlaybackRecoveryDriver(
            playback: engine,
            network: networkMonitor,
            clock: clock,
            onEvictCache: { track in
                await MediaAudioCache.shared.evict(cacheKey: TrackIdentity.storageKey(track.identity))
            }
        )
        return (networkMonitor, relatedRadio, playbackRecovery)
    }

    /// 遮罩状态一变，所有"推出去的内容"立刻重推。
    @MainActor
    private static func wirePrivacy(_ privacy: PrivacyState,
                                    systemMedia: SystemMediaIntegration,
                                    widgetBridge: WidgetBridge,
                                    overlay: MorphWindowController) {
        privacy.onMaskingChanged.append { [weak systemMedia] in systemMedia?.republish() }
        privacy.onMaskingChanged.append { [weak widgetBridge] in widgetBridge?.republish() }
        privacy.onMaskingChanged.append { [weak overlay] in overlay?.privacyDidChange() }
    }

    /// 兜底容器。持久化不可用时（磁盘只读、库损坏）仍要能起一个可运行的空壳。
    @MainActor
    static func makeFallback() -> AppContainer {
        let clock = SystemPlaybackClock()
        let registry = SourceRegistry()
        let fallbackSettings = InMemorySettingsStore()
        let sourceManager = SourceManager(
            registry: registry,
            networkEnabledProvider: { fallbackSettings.enableNetwork },
            preferredQualityProvider: { AudioQualityTier(rawValue: fallbackSettings.preferredQualityRaw) },
            externalPluginsDirectories: []
        )
        sourceManager.registerSource(
            MockPlaybackSource(behavior: .healthy, clock: clock),
            isBuiltIn: true,
            originLabel: String(localized: "测试模拟源")
        )
        let engine = PlaybackEngine(clock: clock, coordinator: PlaybackCoordinator(registry: registry))

        let persistence: PersistenceController
        do {
            persistence = try PersistenceController(inMemory: true)
        } catch {
            preconditionFailure("内存 ModelContainer 不可用：\(error)")
        }

        let placementStore = SwiftDataPlacementStore(modelContainer: persistence.container)
        let offsetStore = SwiftDataLyricsOffsetStore(modelContainer: persistence.container)
        let lyricBindings = LyricBindingStore(directory: nil)
        // 歌词走源：B 站稿件的字幕 / 外部歌词库都挂在源上，本地加载器只做兜底。
        let lyricEngine = LyricEngine(loader: SourceAwareLyricsLoader(registry: registry, bindingStore: lyricBindings),
                                      offsets: offsetStore)
        // 手动换歌词要直接替换歌词引擎的文档（引擎建好之后再挂）。
        let libraryStore = SwiftDataLibraryStore(modelContainer: persistence.container)
        let playlistStore = SwiftDataPlaylistStore(modelContainer: persistence.container)
        let sessionPersistence = PlaybackSessionPersistence(
            engine: engine,
            persistence: persistence,
            tracks: persistence.makeTrackRepository()
        )
        let nowPlayingBridge = MediaPlayerNowPlayingBridge()
        let systemMedia = SystemMediaIntegration(bridge: nowPlayingBridge, playback: engine, library: libraryStore)
        // 控制中心封面：集成层不直接认识源，用注册表回查。
        systemMedia.sourceProvider = { id in registry.provider(for: id) }
        let lyricVariants = LyricVariantCoordinator(
            bindingStore: lyricBindings,
            lyricEngine: lyricEngine,
            networkAllowed: { fallbackSettings.enableNetwork }
        )
        let offline = OfflineLibraryManager(
            audioCache: MediaAudioCache(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("flow-fallback-offline-\(UUID().uuidString)", isDirectory: true)
            ),
            manifestURL: nil,
            qualityProvider: { AudioQualityTier(rawValue: fallbackSettings.preferredQualityRaw) ?? .auto },
            networkAllowed: { fallbackSettings.enableNetwork }
        )
        systemMedia.isNetworkEnabled = { fallbackSettings.enableNetwork }
        let privacy = PrivacyState(settings: fallbackSettings)
        // 隐私态必须投影到系统"正在播放"：否则 App 内隐藏了歌名，
        // 锁屏/控制中心照常显示真实标题（用户开隐私模式就是为了不让别人看到）。
        systemMedia.isPrivacyMasked = { [weak privacy] in privacy?.isMasking ?? false }
        let appearance = AppearanceSettings(settings: fallbackSettings)
        let widgetBridge = WidgetBridge(playback: engine, lyricEngine: lyricEngine, privacy: privacy)
        // 形态窗口：五种形态的唯一载体。旧的 FloatingPanelController 已完成迁移。
        let overlay = MorphWindowController(playback: engine,
                                            lyricEngine: lyricEngine,
                                            privacy: privacy,
                                            appearance: appearance,
                                            placements: placementStore,
                                            trackRepository: persistence.makeTrackRepository(),
                                            preferences: InMemoryMorphPreferenceStore())
        let (networkMonitor, relatedRadio, playbackRecovery) = Self.makeRuntimeDrivers(
            engine: engine,
            sourceManager: sourceManager,
            clock: clock
        )

        let container = AppContainer(
            sourceRegistry: registry,
            sourceManager: sourceManager,
            playback: engine,
            playbackEngine: engine,
            settings: fallbackSettings,
            tracks: persistence.makeTrackRepository(),
            persistence: persistence,
            clock: clock,
            nowPlaying: nowPlayingBridge,
            floatingLyrics: overlay,
            morph: overlay,
            lyricEngine: lyricEngine,
            lyricBindings: lyricBindings,
            lyricVariants: lyricVariants,
            sessionPersistence: sessionPersistence,
            library: libraryStore,
            playlists: playlistStore,
            offline: offline,
            systemMedia: systemMedia,
            privacy: privacy,
            appearance: appearance,
            widgetBridge: widgetBridge,
            networkMonitor: networkMonitor,
            relatedRadio: relatedRadio,
            playbackRecovery: playbackRecovery
        )
        overlay.appContainer = container
        Self.wirePrivacy(privacy, systemMedia: systemMedia, widgetBridge: widgetBridge, overlay: overlay)
        container.degradedReason = "本地数据库不可用：本次运行使用临时设置与示例曲库，收藏与历史不会被保存。"
        return container
    }
}
