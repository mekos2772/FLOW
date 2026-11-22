import AppKit
import Foundation
@testable import SpatialLyricsPlayer

/// 形态窗口测试的公共构造。
///
/// 统一用零时长动画：测试断言的是"最终状态与窗口契约"，
/// 不该被 0.4s 的缓动挡住。
@MainActor
enum MorphTestSupport {
    /// 测试用调参：所有动画时长归零。
    static var instantTuning: MorphologyTuning {
        MorphologyTuning(
            autoCollapseDelay: .milliseconds(10),
            interactionGrace: .milliseconds(10),
            morphologyCooldown: .zero,
            expandDuration: .zero,
            collapseDuration: .zero,
            morphDuration: .zero,
            dormantDuration: .zero
        )
    }

    struct Harness {
        let controller: MorphWindowController
        let persistence: PersistenceController
        let engine: PlaybackEngine
        let preferences: InMemoryMorphPreferenceStore
    }

    static func make(seed: MorphPreferenceSnapshot = MorphPreferenceSnapshot(),
                     settings: InMemorySettingsStore = InMemorySettingsStore(),
                     obstacleProvider: ObstacleProvider = ObstacleProvider()) throws -> Harness {
        let persistence = try PersistenceController(inMemory: true)
        let clock = TestPlaybackClock()
        let registry = SourceRegistry()
        registry.register(MockPlaybackSource(behavior: .healthy, clock: clock))
        let engine = PlaybackEngine(clock: clock, coordinator: PlaybackCoordinator(registry: registry))
        let preferences = InMemoryMorphPreferenceStore(seed: seed)
        let controller = MorphWindowController(
            playback: engine,
            lyricEngine: makeLyricEngine(persistence),
            privacy: PrivacyState(settings: settings),
            appearance: AppearanceSettings(settings: settings),
            placements: SwiftDataPlacementStore(modelContainer: persistence.container),
            trackRepository: persistence.makeTrackRepository(),
            preferences: preferences,
            tuning: instantTuning,
            obstacleProvider: obstacleProvider
        )
        return Harness(controller: controller, persistence: persistence, engine: engine, preferences: preferences)
    }
}
