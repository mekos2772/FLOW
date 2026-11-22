import SwiftData
import XCTest
@testable import SpatialLyricsPlayer

@MainActor
final class FloatingPlacementTests: XCTestCase {

    private func makeStore() throws -> (SwiftDataPlacementStore, PersistenceController) {
        let persistence = try PersistenceController(inMemory: true)
        return (SwiftDataPlacementStore(modelContainer: persistence.container), persistence)
    }

    func testSnapshotRoundTripsThroughSwiftData() async throws {
        let (store, _) = try makeStore()

        let snapshot = PlacementSnapshot(
            displayID: "DISPLAY-A",
            originX: 320,
            originY: 640,
            width: 380,
            height: 46,
            shape: .doubleLine,
            isLocked: true,
            isClickThrough: false,
            opacity: 0.8,
            showsBackground: false
        )
        await store.save(snapshot)

        let loaded = await store.load()
        XCTAssertEqual(loaded, snapshot)
    }

    func testSecondSaveOverwritesInsteadOfDuplicating() async throws {
        let (store, persistence) = try makeStore()

        var snapshot = PlacementSnapshot(
            displayID: "DISPLAY-A",
            originX: 0, originY: 0, width: 380, height: 46,
            shape: .capsule, isLocked: false, isClickThrough: true,
            opacity: 0.95, showsBackground: true
        )
        await store.save(snapshot)

        snapshot.originX = 200
        snapshot.shape = .board
        await store.save(snapshot)

        let loaded = await store.load()
        XCTAssertEqual(loaded?.originX, 200)
        XCTAssertEqual(loaded?.shape, .board)

        let context = ModelContext(persistence.container)
        let records = try context.fetch(FetchDescriptor<PlacementRecord>())
        XCTAssertEqual(records.count, 1, "同一 scope 必须覆盖而不是插入新行")
    }

    func testLoadReturnsNilWhenNothingSaved() async throws {
        let (store, _) = try makeStore()
        let loaded = await store.load()
        XCTAssertNil(loaded)
    }

    func testClearRemovesRecord() async throws {
        let (store, _) = try makeStore()
        await store.save(PlacementSnapshot(
            displayID: "D", originX: 1, originY: 2, width: 3, height: 4,
            shape: .edge, isLocked: false, isClickThrough: true,
            opacity: 1, showsBackground: true
        ))
        await store.clear()
        let loaded = await store.load()
        XCTAssertNil(loaded)
    }

    func testControllerStartsInsideSafeZone() async throws {
        let (store, persistence) = try makeStore()
        let clock = TestPlaybackClock()
        let registry = SourceRegistry()
        registry.register(MockPlaybackSource(behavior: .healthy, clock: clock))
        let engine = PlaybackEngine(clock: clock, coordinator: PlaybackCoordinator(registry: registry))

        let controller = MorphWindowController(
            playback: engine,
            lyricEngine: makeLyricEngine(persistence),
            privacy: PrivacyState(settings: InMemorySettingsStore()),
            appearance: AppearanceSettings(settings: InMemorySettingsStore()),
            placements: store,
            trackRepository: persistence.makeTrackRepository(),
            preferences: InMemoryMorphPreferenceStore(),
            tuning: MorphTestSupport.instantTuning
        )
        controller.resetToDefaultPosition()

        let zone = ScreenGeometryResolver.mainScreenGeometry().safeZone
        XCTAssertTrue(zone.contains(controller.currentFrame), "默认位置必须落在安全区内")
    }

    func testShapeSwitchKeepsSizeConsistent() async throws {
        let (store, persistence) = try makeStore()
        let clock = TestPlaybackClock()
        let registry = SourceRegistry()
        registry.register(MockPlaybackSource(behavior: .healthy, clock: clock))
        let engine = PlaybackEngine(clock: clock, coordinator: PlaybackCoordinator(registry: registry))

        let controller = MorphWindowController(
            playback: engine,
            lyricEngine: makeLyricEngine(persistence),
            privacy: PrivacyState(settings: InMemorySettingsStore()),
            appearance: AppearanceSettings(settings: InMemorySettingsStore()),
            placements: store,
            trackRepository: persistence.makeTrackRepository(),
            preferences: InMemoryMorphPreferenceStore(),
            tuning: MorphTestSupport.instantTuning
        )
        controller.resetToDefaultPosition()
        controller.setMorphology(.capsule)
        let before = controller.currentFrame

        controller.setFloatingShape(.board)
        let after = controller.currentFrame

        // 变宽本身会让重心移动：窗口在屏幕右侧时还会被安全区夹一下。
        // 这里断言的是"没有无关跳动"——位移不超过宽度变化的量。
        let growth = abs(after.width - before.width)
        XCTAssertTrue(abs(after.midX - before.midX) <= growth + 3,
                      "横向重心跳变超出尺寸变化：before=\(before) after=\(after) growth=\(growth)")
        XCTAssertGreaterThan(after.height, before.height, "歌词板比单行胶囊高")
    }

    func testToggleLockAndInteractiveAreIndependent() async throws {
        let (store, persistence) = try makeStore()
        let clock = TestPlaybackClock()
        let registry = SourceRegistry()
        registry.register(MockPlaybackSource(behavior: .healthy, clock: clock))
        let engine = PlaybackEngine(clock: clock, coordinator: PlaybackCoordinator(registry: registry))

        let controller = MorphWindowController(
            playback: engine,
            lyricEngine: makeLyricEngine(persistence),
            privacy: PrivacyState(settings: InMemorySettingsStore()),
            appearance: AppearanceSettings(settings: InMemorySettingsStore()),
            placements: store,
            trackRepository: persistence.makeTrackRepository(),
            preferences: InMemoryMorphPreferenceStore(),
            tuning: MorphTestSupport.instantTuning
        )
        controller.setMorphology(.capsule)
        XCTAssertTrue(controller.isInteractive, "悬浮形态默认可点：点击胶囊要能展开")
        XCTAssertFalse(controller.isLocked)

        controller.toggleInteractive()
        XCTAssertFalse(controller.isInteractive)

        controller.toggleLock()
        XCTAssertTrue(controller.isLocked)
        XCTAssertFalse(controller.isInteractive, "锁定位置与穿透是独立维度，不能互相改写")
    }
}
