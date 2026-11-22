import XCTest
@testable import SpatialLyricsPlayer

/// 沉浸播放模式的六项设置：默认值、持久化、坏值回落、外观快照即时更新、备份恢复。
///
/// 场景与幅度存的是原始字符串；改名、降级或手工改偏好都可能留下认不出的值，
/// 读出来必须落回默认场景，而不是让沉浸画面拿到一个不存在的着色器函数名。
@MainActor
final class ImmersiveSettingsTests: XCTestCase {

    // XCTest 每个测试方法新建一个实例，所以每个测试各有一个独立 suite。
    // 用 `let` 而不是在 `setUp` 里赋值：`setUp`/`tearDown` 不在主 actor 上，改主 actor 隔离的属性会报并发警告。
    private let suiteName = "flow-immersive-\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// 异步持久化没有完成回调；轮询到写入可见为止，最多等一秒。
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<50 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testDefaults() {
        let durable = UserDefaultsSettingsStore(defaults: defaults)
        let memory = InMemorySettingsStore()

        for store in [durable as any SettingsStoring, memory as any SettingsStoring] {
            XCTAssertEqual(store.immersiveSceneRaw, ImmersiveSceneKind.default.rawValue)
            XCTAssertEqual(store.immersiveResponseRaw, ImmersiveResponse.standard.rawValue)
            XCTAssertTrue(store.immersiveEntersFullScreen, "没写过键时默认进入全屏")
            XCTAssertFalse(store.immersivePowerSaving, "省电默认关闭")
            XCTAssertEqual(store.immersiveBeatSyncRaw, ImmersiveBeatSync.standard.rawValue, "节拍联动默认适中")

            let appearance = AppearanceSettings(settings: store)
            XCTAssertEqual(appearance.immersiveScene, .default)
            XCTAssertEqual(appearance.immersiveResponse, .standard)
            XCTAssertTrue(appearance.immersiveEntersFullScreen)
            XCTAssertFalse(appearance.immersivePowerSaving)
            XCTAssertEqual(appearance.immersiveBeatSync, .standard)
        }
    }

    func testRoundTripThroughUserDefaults() async {
        let writer = UserDefaultsSettingsStore(defaults: defaults)
        await writer.setImmersiveSceneRaw(ImmersiveSceneKind.ridge.rawValue)
        await writer.setImmersiveResponseRaw(ImmersiveResponse.gentle.rawValue)
        await writer.setImmersiveEntersFullScreen(false)
        await writer.setImmersivePowerSaving(true)
        await writer.setImmersiveBeatSyncRaw(ImmersiveBeatSync.strong.rawValue)

        // 换一个实例读同一个 suite：确认真的落到了 UserDefaults，而不是进程内缓存。
        let reader = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(reader.immersiveSceneRaw, ImmersiveSceneKind.ridge.rawValue)
        XCTAssertEqual(reader.immersiveResponseRaw, ImmersiveResponse.gentle.rawValue)
        XCTAssertFalse(reader.immersiveEntersFullScreen)
        XCTAssertTrue(reader.immersivePowerSaving)
        XCTAssertEqual(reader.immersiveBeatSyncRaw, ImmersiveBeatSync.strong.rawValue)

        let appearance = AppearanceSettings(settings: reader)
        XCTAssertEqual(appearance.immersiveScene, .ridge)
        XCTAssertEqual(appearance.immersiveResponse, .gentle)
        XCTAssertFalse(appearance.immersiveEntersFullScreen)
        XCTAssertTrue(appearance.immersivePowerSaving)
        XCTAssertEqual(appearance.immersiveBeatSync, .strong)
    }

    func testCorruptedRawValuesFallBackToDefaults() {
        defaults.set("aurora", forKey: "settings.immersiveScene")       // 不存在的场景
        defaults.set(7, forKey: "settings.immersiveResponse")           // 类型不符
        defaults.set("yes", forKey: "settings.immersiveEntersFullScreen")
        defaults.set("garbage", forKey: "settings.immersivePowerSaving")
        defaults.set("disco", forKey: "settings.immersiveBeatSync")      // 不存在的档位

        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(store.immersiveSceneRaw, ImmersiveSceneKind.default.rawValue)
        XCTAssertEqual(store.immersiveResponseRaw, ImmersiveResponse.default.rawValue)
        XCTAssertTrue(store.immersiveEntersFullScreen, "类型不符应当回落默认值")
        XCTAssertFalse(store.immersivePowerSaving, "类型不符应当回落默认值")
        XCTAssertEqual(store.immersiveBeatSyncRaw, ImmersiveBeatSync.default.rawValue)

        let appearance = AppearanceSettings(settings: store)
        XCTAssertEqual(appearance.immersiveScene, .default)
        XCTAssertEqual(appearance.immersiveResponse, .default)
        XCTAssertEqual(appearance.immersiveBeatSync, .default)

        defaults.set(3, forKey: "settings.immersiveBeatSync")           // 类型不符
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).immersiveBeatSyncRaw,
                       ImmersiveBeatSync.default.rawValue)
    }

    /// 两个实现对未知原始值的处理必须一致：降级模式用的是内存实现。
    func testUnknownRawValuesAreRejectedByBothStores() async {
        let durable = UserDefaultsSettingsStore(defaults: defaults)
        let memory = InMemorySettingsStore()

        for store in [durable as any SettingsStoring, memory as any SettingsStoring] {
            await store.setImmersiveSceneRaw(ImmersiveSceneKind.rain.rawValue)
            await store.setImmersiveResponseRaw(ImmersiveResponse.off.rawValue)
            XCTAssertEqual(store.immersiveSceneRaw, ImmersiveSceneKind.rain.rawValue)
            XCTAssertEqual(store.immersiveResponseRaw, ImmersiveResponse.off.rawValue)

            await store.setImmersiveSceneRaw("aurora")
            await store.setImmersiveResponseRaw("wild")
            XCTAssertEqual(store.immersiveSceneRaw, ImmersiveSceneKind.default.rawValue)
            XCTAssertEqual(store.immersiveResponseRaw, ImmersiveResponse.default.rawValue)

            await store.setImmersiveBeatSyncRaw(ImmersiveBeatSync.off.rawValue)
            XCTAssertEqual(store.immersiveBeatSyncRaw, ImmersiveBeatSync.off.rawValue)
            await store.setImmersiveBeatSyncRaw("disco")
            XCTAssertEqual(store.immersiveBeatSyncRaw, ImmersiveBeatSync.default.rawValue)
        }
    }

    func testAppearanceSettersUpdateImmediatelyAndPersist() async {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let appearance = AppearanceSettings(settings: store)

        appearance.setImmersiveScene(.light)
        appearance.setImmersiveResponse(.off)
        appearance.setImmersiveEntersFullScreen(false)
        appearance.setImmersivePowerSaving(true)
        appearance.setImmersiveBeatSync(.subtle)

        // 可观察值必须同步更新：设置页的 Picker / 开关靠它立刻回显。
        XCTAssertEqual(appearance.immersiveScene, .light)
        XCTAssertEqual(appearance.immersiveResponse, .off)
        XCTAssertFalse(appearance.immersiveEntersFullScreen)
        XCTAssertTrue(appearance.immersivePowerSaving)
        XCTAssertEqual(appearance.immersiveBeatSync, .subtle)

        let reader = UserDefaultsSettingsStore(defaults: store.defaultsForTesting)
        await waitUntil {
            reader.immersiveSceneRaw == ImmersiveSceneKind.light.rawValue
                && reader.immersiveResponseRaw == ImmersiveResponse.off.rawValue
                && !reader.immersiveEntersFullScreen
                && reader.immersivePowerSaving
                && reader.immersiveBeatSyncRaw == ImmersiveBeatSync.subtle.rawValue
        }
        XCTAssertEqual(reader.immersiveSceneRaw, ImmersiveSceneKind.light.rawValue, "场景没有持久化")
        XCTAssertEqual(reader.immersiveResponseRaw, ImmersiveResponse.off.rawValue, "幅度没有持久化")
        XCTAssertFalse(reader.immersiveEntersFullScreen, "全屏开关没有持久化")
        XCTAssertTrue(reader.immersivePowerSaving, "省电开关没有持久化")
        XCTAssertEqual(reader.immersiveBeatSyncRaw, ImmersiveBeatSync.subtle.rawValue, "节拍联动没有持久化")
    }

    /// 导出→导入要带回节拍联动；旧备份没有这一项时不能把当前值清掉，
    /// 坏的档位名不能写进去。
    func testBackupRestoresBeatSync() async throws {
        let source = InMemorySettingsStore()
        await source.setImmersiveBeatSyncRaw(ImmersiveBeatSync.off.rawValue)
        let data = try SettingsBackup.encode(SettingsBackup.snapshot(from: source))

        let target = UserDefaultsSettingsStore(defaults: defaults)
        let decoded = try SettingsBackup.decode(data)
        await decoded.apply(to: target)
        XCTAssertEqual(target.immersiveBeatSyncRaw, ImmersiveBeatSync.off.rawValue)
        let appearance = AppearanceSettings(settings: target)
        XCTAssertEqual(appearance.immersiveBeatSync, .off)

        // 这一项加入之前导出的文件：字段缺失，保留当前值。
        var older = SettingsBackup.snapshot(from: target)
        older.immersiveBeatSyncRaw = nil
        let fresh = InMemorySettingsStore()
        await fresh.setImmersiveBeatSyncRaw(ImmersiveBeatSync.strong.rawValue)
        await older.apply(to: fresh)
        XCTAssertEqual(fresh.immersiveBeatSyncRaw, ImmersiveBeatSync.strong.rawValue)

        var tampered = older
        tampered.immersiveBeatSyncRaw = "disco"
        await tampered.apply(to: fresh)
        XCTAssertEqual(fresh.immersiveBeatSyncRaw, ImmersiveBeatSync.strong.rawValue, "坏档位名不写入")
    }
}
