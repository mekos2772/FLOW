import Foundation

/// FLOW Voice 模块装配容器：负责组装音色包、模型资产、三级缓存、任务队列与播放驱动。
enum VoiceContainer {
    struct Stack {
        let manager: VoiceManager
        let driver: VoicePlaybackDriver
        let assets: VoiceModelAssetsManager
        let presetStore: VoicePresetStore
    }

    static func rootDirectory(production: Bool) -> URL {
        if production,
           let appSupport = RuntimeSandbox.applicationSupportDirectory() {
            return appSupport.appendingPathComponent("FLOW/Voice", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-voice-tests/\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    static func attach(
        to coordinator: PlaybackCoordinator,
        playback: (any PlaybackControlling)? = nil,
        settings: any SettingsStoring,
        offline: OfflineLibraryManager,
        offlineResolver: (any OfflineAudioResolving)? = nil,
        registry: SourceRegistry,
        production: Bool
    ) -> Stack {
        let root = rootDirectory(production: production)
        let packStore = VoicePackStore(packsRoot: root.appendingPathComponent("Packs", isDirectory: true))
        let cache = VoiceCacheManager(rootURL: root)
        let assets = VoiceModelAssetsManager(voiceRoot: root)
        let presetStore = VoicePresetStore(directory: root)
        let discovery = VoiceModelDiscovery()

        let manager = VoiceManager(
            settings: settings,
            packStore: packStore,
            cache: cache,
            assets: assets,
            presetStore: presetStore,
            discovery: discovery
        )

        let resolver: @MainActor (Track) async -> URL? = { track in
            if let local = await offline.cachedAudioFileURL(for: track) {
                return local
            }
            if let source = registry.provider(for: track.sourceID) as? LocalLibrarySource {
                return source.audioFileURL(for: track)
            }
            return nil
        }

        let ensurer: @MainActor (Track) async -> URL? = { track in
            if let local = await offline.ensureCachedAudioFileURL(for: track, using: offlineResolver) {
                return local
            }
            if let source = registry.provider(for: track.sourceID) as? LocalLibrarySource {
                return source.audioFileURL(for: track)
            }
            return nil
        }

        let driver = VoicePlaybackDriver(voice: manager, inputResolver: resolver)
        manager.inputResolver = resolver
        manager.inputEnsurer = ensurer

        Task { [weak driver] in
            await offline.audioCache.setOnAudioCached { [weak driver] _ in
                Task { @MainActor in
                    await driver?.handleAudioCachedOnCurrentTrack()
                }
            }
        }

        coordinator.voiceRoutingSignature = { [weak driver] track in
            await driver?.activeRoutingSignature(for: track)
        }
        coordinator.voiceSessionFactory = { [weak driver] track, isPrewarm in
            guard let driver else { return nil }
            return try await driver.makeSessionIfAvailable(for: track, isPrewarm: isPrewarm)
        }

        if let playback {
            manager.onAttach = { [weak driver, weak playback] in
                guard let driver, let playback else { return }
                driver.startObserving(playback: playback)
            }
            manager.onVoiceContextChanged = { [weak driver, weak playback, weak coordinator] in
                guard let coordinator else { return }
                coordinator.cancelPrewarm()
                guard let driver, let playback else { return }
                Task { @MainActor in
                    await driver.reconcileActiveTrackRouting(playback: playback, coordinator: coordinator)
                }
            }
            manager.onPlayVersionRequested = { [weak driver, weak playback, weak coordinator] track, autoplay in
                guard let driver, let playback, let coordinator else { return }
                await driver.playRequestedVersion(
                    of: track,
                    playback: playback,
                    coordinator: coordinator,
                    autoplay: autoplay
                )
            }
            manager.onStartTrackRequested = { [weak driver, weak playback] track in
                guard let driver, let playback else { return }
                await driver.startTrack(track, playback: playback)
            }
        } else {
            manager.onVoiceContextChanged = { [weak coordinator] in
                coordinator?.cancelPrewarm()
            }
        }

        return Stack(manager: manager, driver: driver, assets: assets, presetStore: presetStore)
    }
}
