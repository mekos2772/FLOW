import AppKit
import XCTest
@testable import SpatialLyricsPlayer

/// 右上角三档：档位推导与切换路径。
@MainActor
final class PlayerModeTests: XCTestCase {
    func testCurrentModeFromMorphology() {
        XCTAssertEqual(PlayerMode.current(morphology: .expanded, isImmersive: false), .normal)
        XCTAssertEqual(PlayerMode.current(morphology: .expanded, isImmersive: true), .immersive)
        for floating in [PlayerMorphology.capsule, .compact, .edge, .dormant] {
            XCTAssertEqual(PlayerMode.current(morphology: floating, isImmersive: false), .floating)
        }
    }

    func testEverySwitchPath() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.expanded)
        XCTAssertEqual(controller.playerMode, .normal)

        controller.setPlayerMode(.immersive)
        XCTAssertTrue(controller.model.isImmersive)
        XCTAssertEqual(controller.playerMode, .immersive)

        controller.setPlayerMode(.normal)
        XCTAssertFalse(controller.model.isImmersive)
        XCTAssertEqual(controller.morphology, .expanded)

        controller.setPlayerMode(.floating)
        XCTAssertEqual(controller.morphology, .capsule, "悬浮 = 桌面歌词胶囊")
        XCTAssertEqual(controller.playerMode, .floating)

        controller.setPlayerMode(.normal)
        XCTAssertEqual(controller.morphology, .expanded, "从悬浮回到普通")

        // 沉浸直接切悬浮：先退出沉浸，再收成胶囊（测试宿主不进全屏，不用等全屏退出）。
        controller.setPlayerMode(.immersive)
        controller.setPlayerMode(.floating)
        XCTAssertFalse(controller.model.isImmersive)
        XCTAssertEqual(controller.morphology, .capsule)
        controller.hide()
    }

    func testModeLabelsAreLocalizedKeys() {
        XCTAssertEqual(PlayerMode.allCases.map(\.displayName), ["普通", "悬浮", "沉浸"])
    }
}

/// 播放页背景：场景背景和沉浸共用，版面比例随窗口走。
@MainActor
final class PlayerBackgroundTests: XCTestCase {
    private let suiteName = "flow-background-\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsPersistenceAndCorruptFallback() async {
        let durable = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(durable.playerBackgroundRaw, PlayerBackground.solid.rawValue, "默认保持原来的纯色版面")
        XCTAssertEqual(InMemorySettingsStore().playerBackgroundRaw, PlayerBackground.solid.rawValue)

        await durable.setPlayerBackgroundRaw(PlayerBackground.ridge.rawValue)
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).playerBackgroundRaw, "ridge")
        await durable.setPlayerBackgroundRaw("aurora")
        XCTAssertEqual(durable.playerBackgroundRaw, "solid", "认不出的值写入时就回落")
        defaults.set(7, forKey: "settings.playerBackground")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).playerBackgroundRaw, "solid")
    }

    func testChoosingSceneBackgroundAlsoSetsImmersiveScene() {
        let appearance = AppearanceSettings(settings: InMemorySettingsStore())
        appearance.setImmersiveScene(.silk)
        appearance.setPlayerBackground(.rain)
        XCTAssertEqual(appearance.playerBackground, .rain)
        XCTAssertEqual(appearance.immersiveScene, .rain, "普通页切到沉浸时还是同一幅画")
        appearance.setPlayerBackground(.artwork)
        XCTAssertEqual(appearance.immersiveScene, .rain, "纯色、封面取色不动沉浸场景")
        XCTAssertNil(PlayerBackground.solid.scene)
        XCTAssertEqual(PlayerBackground(scene: .light), .light)
    }

    func testBackupRestoresBackground() async throws {
        let source = InMemorySettingsStore()
        await source.setPlayerBackgroundRaw(PlayerBackground.light.rawValue)
        let data = try SettingsBackup.encode(SettingsBackup.snapshot(from: source))
        let target = InMemorySettingsStore()
        await (try SettingsBackup.decode(data)).apply(to: target)
        XCTAssertEqual(target.playerBackgroundRaw, "light")

        var older = SettingsBackup.snapshot(from: target)
        older.playerBackgroundRaw = nil
        let fresh = InMemorySettingsStore()
        await fresh.setPlayerBackgroundRaw("silk")
        await older.apply(to: fresh)
        XCTAssertEqual(fresh.playerBackgroundRaw, "silk", "旧备份没有这一项时保留当前值")
        older.playerBackgroundRaw = "disco"
        await older.apply(to: fresh)
        XCTAssertEqual(fresh.playerBackgroundRaw, "silk", "坏值不写入")
    }

    /// 默认窗口是基准；窗口变大时封面、歌词区、字号一起放大，夹在 0.9–1.7。
    func testLayoutScaleFollowsWindow() {
        XCTAssertEqual(ExpandedPlayerView.layoutScale(for: CGSize(width: 815, height: 427)), 0.9, accuracy: 0.001)
        XCTAssertEqual(ExpandedPlayerView.layoutScale(for: CGSize(width: 790, height: 480)), 1, accuracy: 0.001)
        XCTAssertEqual(ExpandedPlayerView.layoutScale(for: CGSize(width: 1211, height: 688)), 688.0 / 480, accuracy: 0.001)
        XCTAssertEqual(ExpandedPlayerView.layoutScale(for: CGSize(width: 1820, height: 950)), 1.7, accuracy: 0.001)
    }

    func testGalleryThumbnailsRenderEveryScene() throws {
        guard ImmersiveShaderLibrary.shared.device != nil else { throw XCTSkip("没有 Metal 设备") }
        for scene in ImmersiveSceneKind.allCases {
            let image = try XCTUnwrap(BackgroundThumbnails.shared.image(for: scene, palette: .dusk), "\(scene) 缩略图渲染失败")
            XCTAssertEqual(image.size, NSSize(width: 120, height: 75))
        }
    }

    /// 沉浸页和播放页的场景背景前后脚出现、消失：谁最后离开谁才关掉电平分析。
    func testMeterStaysOnWhileAnyConsumerRemains() {
        let meter = AudioFeatureMeter()
        meter.acquire()
        meter.acquire()
        meter.release()
        XCTAssertTrue(meter.isEnabled)
        meter.release()
        XCTAssertFalse(meter.isEnabled)
        meter.release()
        XCTAssertFalse(meter.isEnabled, "多释放一次不能变成负数")
    }

    func testNewlineAwareLineEstimate() {
        XCTAssertEqual(LyricScrollLayout.estimatedLines("几句是非\n也无法将我的热情冷却", width: 600, fontSize: 40), 2)
        XCTAssertEqual(LyricScrollLayout.estimatedLines("几句是非 也无法将我的热情冷却", width: 600, fontSize: 40), 1)
    }
}
