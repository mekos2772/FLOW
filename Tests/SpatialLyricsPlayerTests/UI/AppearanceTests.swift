import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

// 外观与配色：默认值、对比度令牌、封面取色、壁纸色调联动。

/// 外观类设置的默认值。
///
/// 这些值有实际后果：不透明度如果是 0，用户会以为应用坏了；
/// 字号如果是 0，歌词会渲染成看不见。`UserDefaults.bool/double` 在键不存在时返回 0，
/// 所以默认值必须由代码显式兜住，而不是靠"键不存在就得到合理值"。
@MainActor
final class AppearanceTests: XCTestCase {

    func testFreshStoreGivesUsableOpacity() {
        let appearance = AppearanceSettings(settings: InMemorySettingsStore())
        XCTAssertGreaterThanOrEqual(appearance.floatingOpacity, 0.3, "默认不透明度必须可见")
        XCTAssertLessThanOrEqual(appearance.floatingOpacity, 1.0)
    }

    func testFreshStoreGivesPositiveLyricTypography() {
        let appearance = AppearanceSettings(settings: InMemorySettingsStore())
        XCTAssertGreaterThan(appearance.lyricFontSize, 0, "字号为 0 会让歌词不可见")
        XCTAssertGreaterThanOrEqual(appearance.lyricLineSpacing, 0, "行距不能为负")
    }

    func testFreshStoreDefaultsToCapsuleShape() {
        let appearance = AppearanceSettings(settings: InMemorySettingsStore())
        XCTAssertEqual(appearance.defaultShape, .capsule, "首次启动应从最紧凑的形态开始")
    }

}

/// 「悬浮模式 / 切到别的应用时收缩」默认关闭，主页与设置里可主动开启并持久化。
///
/// 不是所有人都喜欢桌面悬浮歌词：如果默认开启，用户刚切去别的应用，1020×640 的主窗口就会
/// 自己缩成迷你条浮在角落。默认关闭能让应用先按常规桌面播放器工作，再按需在主页打开悬浮模式。
@MainActor
final class AutoCollapseOnDeactivateTests: XCTestCase {

    private func makeStore() -> UserDefaultsSettingsStore {
        let suite = UserDefaults(suiteName: "flow-autocollapse-\(UUID().uuidString)")!
        return UserDefaultsSettingsStore(defaults: suite)
    }

    func testDefaultsToDisabled() {
        let settings = InMemorySettingsStore()
        XCTAssertFalse(settings.autoCollapseOnDeactivate, "默认应当关闭：不是所有人都喜欢悬浮")
        XCTAssertFalse(makeStore().autoCollapseOnDeactivate, "没写过键时也必须是关闭")
        XCTAssertFalse(AppearanceSettings(settings: settings).isFloatingModeEnabled)
    }

    func testTurningOnPersists() async {
        let settings = InMemorySettingsStore()
        await settings.setAutoCollapseOnDeactivate(true)
        XCTAssertTrue(settings.autoCollapseOnDeactivate)
        XCTAssertTrue(AppearanceSettings(settings: settings).autoCollapseOnDeactivate,
                      "外观快照必须读到开启后的值")
        await settings.setAutoCollapseOnDeactivate(false)
        XCTAssertFalse(settings.autoCollapseOnDeactivate)
    }

    func testFloatingModeTogglePersistsAndRestoresAutoMorph() async {
        let store = makeStore()
        let appearance = AppearanceSettings(settings: store)
        appearance.setAutoMorphEnabled(false)
        try? await Task.sleep(for: .milliseconds(100))
        appearance.setFloatingModeEnabled(true)
        XCTAssertTrue(appearance.isFloatingModeEnabled)
        XCTAssertTrue(appearance.autoCollapseOnDeactivate)
        XCTAssertTrue(appearance.autoMorphEnabled, "主页打开悬浮模式时应一并恢复自动形态切换")
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(UserDefaultsSettingsStore(defaults: store.defaultsForTesting).autoCollapseOnDeactivate,
                      "必须是持久化的，不是进程内缓存")

        appearance.setFloatingModeEnabled(false)
        XCTAssertFalse(appearance.isFloatingModeEnabled)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(UserDefaultsSettingsStore(defaults: store.defaultsForTesting).autoCollapseOnDeactivate)
    }
}
/// 灰阶令牌在「提高对比度」下的行为。
///
/// 纯黑白界面没有颜色可以做层级，灰阶是唯一的层级手段——
/// 系统开了"提高对比度"却不变亮，等于用户说看不清却没被听见。
@MainActor
final class ContrastTokenTests: XCTestCase {

    private func alpha(_ color: Color) -> CGFloat {
        NSColor(color).alphaComponent
    }

    func testSecondaryTextBrightensUnderIncreasedContrast() {
        let normal = alpha(FlowColor.secondaryText(scheme: .light, contrast: .standard))
        let high = alpha(FlowColor.secondaryText(scheme: .light, contrast: .increased))
        XCTAssertGreaterThan(high, normal, "提高对比度时次级文字必须更实")
    }

    func testNeighborTextBrightensUnderIncreasedContrast() {
        let normal = alpha(FlowColor.neighborText(contrast: .standard))
        let high = alpha(FlowColor.neighborText(contrast: .increased))
        XCTAssertGreaterThan(high, normal)
    }

    func testLyricNeighborBrightensUnderIncreasedContrast() {
        let normal = alpha(FlowColor.lyricNeighbor(scheme: .dark, contrast: .standard))
        let high = alpha(FlowColor.lyricNeighbor(scheme: .dark, contrast: .increased))
        XCTAssertGreaterThan(high, normal)
    }

    /// 深色模式下的次级文字要比浅色模式更亮（同样的 α 在黑底上更糊）。
    func testDarkSecondaryIsLighterThanLightSecondary() {
        let dark = alpha(FlowColor.secondaryText(scheme: .dark, contrast: .standard))
        let light = alpha(FlowColor.secondaryText(scheme: .light, contrast: .standard))
        XCTAssertLessThan(dark, light, "浅色模式需要更实的黑，所以 α 更大")
    }
}
final class ArtworkPaletteTests: XCTestCase {

    func testHSBRoundTripKeepsChannels() {
        for sample in [(0.9, 0.2, 0.3), (0.1, 0.1, 0.1), (1.0, 1.0, 1.0), (0.0, 0.0, 0.0)] {
            let original = ArtworkPalette.Color(red: sample.0, green: sample.1, blue: sample.2)
            let hsb = ArtworkPalette.rgbToHSB(original)
            let back = ArtworkPalette.hsbToRGB(h: hsb.h, s: hsb.s, b: hsb.b)
            XCTAssertEqual(back.red, original.red, accuracy: 1e-9)
            XCTAssertEqual(back.green, original.green, accuracy: 1e-9)
            XCTAssertEqual(back.blue, original.blue, accuracy: 1e-9)
        }
    }

    func testAdjustedCapsSaturationAndBrightness() {
        let vivid = ArtworkPalette.Color(red: 1, green: 0, blue: 0)   // 纯红，饱和度 1
        let muted = ArtworkPalette.adjusted(vivid, saturation: 0.35, brightness: 0.62)
        let hsb = ArtworkPalette.rgbToHSB(muted)

        XCTAssertLessThanOrEqual(hsb.s, 0.35 + 1e-9, "饱和度必须压到上限以内")
        XCTAssertLessThanOrEqual(hsb.b, 0.62 + 1e-9, "亮度必须压到上限以内")
        XCTAssertEqual(hsb.h, 0.0, accuracy: 1e-6, "色相不能跑偏")
    }

    func testAverageColorOfSolidImage() {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()

        let average = ArtworkPalette.averageColor(of: image)
        XCTAssertNotNil(average, "纯色图必须取到颜色")
        XCTAssertEqual(average!.red, 0.2, accuracy: 0.02)
        XCTAssertEqual(average!.green, 0.4, accuracy: 0.02)
        XCTAssertEqual(average!.blue, 0.6, accuracy: 0.02)
    }

    func testNilImageFallsBack() {
        XCTAssertNil(ArtworkPalette.ambient(from: nil), "没有封面时交给调用方回退系统色")
    }
}
@MainActor
final class BackgroundAppearanceTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 200, height: 100)

    private func request(_ frame: CGRect, layout: WallpaperLayout = .stretch,
                         screen: CGRect? = nil) -> WallpaperSampleRequest {
        WallpaperSampleRequest(url: URL(fileURLWithPath: "/tmp/flow-wallpaper-fixture.png"),
                               screenFrame: screen ?? self.screen, windowFrame: frame, layout: layout)
    }

    private func image(width: Int = 200, height: Int = 100,
                       paint: (CGContext) -> Void) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        paint(context)
        return try XCTUnwrap(context.makeImage())
    }

    private func sample(_ image: CGImage, _ request: WallpaperSampleRequest,
                        originalSize: CGSize? = nil) throws -> BackgroundSample {
        try XCTUnwrap(WallpaperLuminanceSampler.sample(image: image,
            originalSize: originalSize ?? CGSize(width: image.width, height: image.height), request: request))
    }

    private func luma(_ image: CGImage, _ request: WallpaperSampleRequest,
                      originalSize: CGSize? = nil) throws -> Double {
        try sample(image, request, originalSize: originalSize).meanLuma
    }

    /// 均匀背景的采样（反差 ≈ 0），用于验证阈值。
    private func flat(_ value: Double) -> BackgroundSample {
        BackgroundSample(meanLuma: value, contrast: 0)
    }

    func testMissingWallpaperFillColorUsesNumericBlackWithoutReadingGrayComponents() {
        let fill = WallpaperLuminance.fillComponents(nil)
        XCTAssertEqual(fill.red, 0)
        XCTAssertEqual(fill.green, 0)
        XCTAssertEqual(fill.blue, 0)
    }

    func testGrayscaleWallpaperFillConvertsToRGB() {
        let fill = WallpaperLuminance.fillComponents(NSColor(white: 0.65, alpha: 1))
        XCTAssertEqual(fill.red, fill.green, accuracy: 0.001)
        XCTAssertEqual(fill.green, fill.blue, accuracy: 0.001)
        XCTAssertGreaterThan(fill.red, 0.5)
    }

    func testRGBWallpaperFillPreservesComponents() {
        let fill = WallpaperLuminance.fillComponents(NSColor(deviceRed: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        XCTAssertEqual(fill.red, 0.2, accuracy: 0.001)
        XCTAssertEqual(fill.green, 0.4, accuracy: 0.001)
        XCTAssertEqual(fill.blue, 0.7, accuracy: 0.001)
    }

    func testFirstSampleChoosesLightAndDarkImmediately() {
        var policy = BackgroundAppearancePolicy()
        let now = ContinuousClock().now
        XCTAssertNil(policy.observe(flat(0.9), now: now))
        XCTAssertEqual(policy.tone, .light)
        policy.reset()
        XCTAssertNil(policy.observe(flat(0.15), now: now))
        XCTAssertEqual(policy.tone, .dark)
    }

    /// 核心行为：中间灰度与明暗混杂的背景**都不判色**，交给系统外观。
    ///
    /// 这条是"颜色不统一"的直接修复：壁纸上有亮控件卡 + 深色照片时，
    /// 平均亮度落在中间，此前会被判成浅色，得到一张与整机外观相反的白卡。
    func testAmbiguousBackgroundFollowsSystemInsteadOfFlickering() {
        var policy = BackgroundAppearancePolicy()
        let now = ContinuousClock().now
        // 深色起步
        _ = policy.observe(flat(0.10), now: now)
        XCTAssertEqual(policy.tone, .dark)
        // 中间灰度：不保持深色，也不翻成浅色——直接交回系统。
        for value in [0.50, 0.57, 0.63, 0.55] {
            XCTAssertNil(policy.observe(flat(value), now: now))
            XCTAssertNil(policy.tone, "中间灰度必须交回系统，不能硬判成某一侧")
        }
        // 浅色起步同理
        policy.reset()
        _ = policy.observe(flat(0.90), now: now)
        XCTAssertEqual(policy.tone, .light)
        for value in [0.45, 0.52, 0.60] {
            XCTAssertNil(policy.observe(flat(value), now: now))
            XCTAssertNil(policy.tone)
        }
    }

    /// 明暗混杂（高反差）即使够亮也不判浅色。
    func testHighContrastBackgroundIsTreatedAsAmbiguous() {
        let busy = BackgroundSample(meanLuma: 0.78, contrast: 0.30)
        XCTAssertNil(BackgroundAppearancePolicy.classification(of: busy),
                     "一半亮一半暗的壁纸，平均值不能代表观感")
        let flatBright = BackgroundSample(meanLuma: 0.80, contrast: 0.05)
        XCTAssertEqual(BackgroundAppearancePolicy.classification(of: flatBright), .light)
        let flatDark = BackgroundSample(meanLuma: 0.20, contrast: 0.06)
        XCTAssertEqual(BackgroundAppearancePolicy.classification(of: flatDark), .dark)
    }

    func testOppositeToneMustRemainStable() {
        var policy = BackgroundAppearancePolicy()
        let now = ContinuousClock().now
        _ = policy.observe(flat(0.1), now: now)
        XCTAssertEqual(policy.observe(flat(0.9), now: now), .milliseconds(280))
        _ = policy.observe(flat(0.9), now: now.advanced(by: .milliseconds(270)))
        XCTAssertEqual(policy.tone, .dark)
        XCTAssertNil(policy.observe(flat(0.9), now: now.advanced(by: .milliseconds(280))))
        XCTAssertEqual(policy.tone, .light)
    }

    func testReturningToOriginalBackgroundResetsPendingSwitch() {
        var policy = BackgroundAppearancePolicy()
        let now = ContinuousClock().now
        _ = policy.observe(flat(0.9), now: now)
        _ = policy.observe(flat(0.1), now: now)
        _ = policy.observe(flat(0.9), now: now.advanced(by: .milliseconds(150)))
        XCTAssertEqual(policy.observe(flat(0.1), now: now.advanced(by: .milliseconds(200))), .milliseconds(280))
        XCTAssertEqual(policy.tone, .light)
    }

    func testUnavailableAndInvalidSamplesReturnToSystem() {
        for value: Double? in [nil, .nan, .infinity, -0.1, 1.1] {
            var policy = BackgroundAppearancePolicy()
            let now = ContinuousClock().now
            _ = policy.observe(flat(0.9), now: now)
            let invalid = value.map { BackgroundSample(meanLuma: $0, contrast: 0) }
            XCTAssertNil(policy.observe(invalid, now: now))
            XCTAssertNil(policy.tone)
        }
    }

    func testLocalSamplingDistinguishesBrightAndDarkHalf() throws {
        let image = try image { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        }
        XCTAssertLessThan(try luma(image, request(CGRect(x: 10, y: 10, width: 60, height: 50))), 0.05)
        XCTAssertGreaterThan(try luma(image, request(CGRect(x: 120, y: 10, width: 60, height: 50))), 0.95)
    }

    func testVerticalSamplingUsesAppKitBottomOrigin() throws {
        let image = try image { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 50, width: 200, height: 50))
        }
        XCTAssertLessThan(try luma(image, request(CGRect(x: 10, y: 5, width: 50, height: 30))), 0.05)
        XCTAssertGreaterThan(try luma(image, request(CGRect(x: 10, y: 65, width: 50, height: 30))), 0.95)
    }

    func testSecondaryDisplayOriginDoesNotChangeSampling() throws {
        let image = try image { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        }
        let secondary = screen.offsetBy(dx: -1200, dy: 800)
        let area = CGRect(x: -1080, y: 810, width: 60, height: 50)
        XCTAssertGreaterThan(try luma(image, request(area, screen: secondary)), 0.95)
    }

    func testAspectFillUsesCenteredCropInsteadOfStretchingWholeImage() throws {
        let square = CGRect(x: 0, y: 0, width: 100, height: 100)
        let request = request(CGRect(x: 10, y: 10, width: 80, height: 80), layout: .fill, screen: square)
        XCTAssertEqual(request.imageRect(imageSize: CGSize(width: 200, height: 100)),
                       CGRect(x: -50, y: 0, width: 200, height: 100))
        let image = try image { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 50, y: 0, width: 100, height: 100))
        }
        XCTAssertGreaterThan(try luma(image, request), 0.95)
    }

    func testFitSamplesConfiguredLetterboxFillColor() throws {
        let image = try image { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        var request = request(CGRect(x: 5, y: 2, width: 80, height: 15), layout: .fit,
                              screen: CGRect(x: 0, y: 0, width: 100, height: 100))
        request.fillRed = 1; request.fillGreen = 1; request.fillBlue = 1
        XCTAssertGreaterThan(try luma(image, request), 0.95)
    }

    func testOutsideScreenHasNoSample() throws {
        let image = try image { _ in }
        XCTAssertNil(WallpaperLuminanceSampler.sample(image: image, originalSize: screen.size,
            request: request(CGRect(x: 400, y: 400, width: 20, height: 20))))
    }

    func testBackgroundModeIsDefaultAndManualPreferencePersists() async {
        let settings = InMemorySettingsStore()
        XCTAssertEqual(AppearanceSettings(settings: settings).floatingAppearance, .background)
        await settings.setFloatingAppearanceRaw("dark")
        XCTAssertEqual(AppearanceSettings(settings: settings).floatingAppearance, .dark)
        await settings.setFloatingAppearanceRaw("unknown")
        XCTAssertEqual(AppearanceSettings(settings: settings).floatingAppearance, .background)
    }

    func testManualPanelToneResetsWhenExpandedWithoutChangingAppAppearance() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        let appAppearance = NSApp.appearance?.name
        controller.setMorphology(.dormant)
        controller.applyFloatingAppearance(.light)
        XCTAssertEqual(controller.model.floatingTone, .light)
        XCTAssertEqual(controller.debugPanel.appearance?.name, .aqua)
        controller.applyFloatingAppearance(.dark)
        XCTAssertEqual(controller.debugPanel.appearance?.name, .darkAqua)
        controller.applyFloatingAppearance(.system)
        XCTAssertNil(controller.debugPanel.appearance)
        controller.applyFloatingAppearance(.dark)
        controller.expand()
        XCTAssertNil(controller.model.floatingTone)
        XCTAssertNil(controller.debugPanel.appearance)
        XCTAssertEqual(NSApp.appearance?.name, appAppearance)
        controller.hide()
    }

    func testBackupCarriesModeAndOldBackupRemainsReadable() async throws {
        let settings = InMemorySettingsStore()
        await settings.setFloatingAppearanceRaw("light")
        let snapshot = SettingsBackup.snapshot(from: settings)
        let decoded = try SettingsBackup.decode(SettingsBackup.encode(snapshot))
        let restored = InMemorySettingsStore()
        await decoded.apply(to: restored)
        XCTAssertEqual(restored.floatingAppearanceRaw, "light")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: SettingsBackup.encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "floatingAppearanceRaw")
        let legacy = try SettingsBackup.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.floatingAppearanceRaw)
    }

    func testUserDefaultsStoresAndReloadsExplicitMode() async throws {
        let name = "flow-background-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(settings.floatingAppearanceRaw, "background")
        await settings.setFloatingAppearanceRaw("light")
        let reloaded = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(AppearanceSettings(settings: reloaded).floatingAppearance, .light)
    }

    func testFileSamplerDecodesLocallyAndInvalidatesCachedPixels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flow-background-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            if directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
               directory.lastPathComponent.hasPrefix("flow-background-") {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let url = directory.appendingPathComponent("wallpaper.png")
        let sampler = WallpaperLuminanceSampler()
        var sample = request(CGRect(x: 10, y: 65, width: 50, height: 30))
        sample.url = url
        let split = try image { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 50, width: 200, height: 50))
        }
        func save(_ image: CGImage) throws {
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        try save(split)
        let first = await sampler.sample(for: sample)
        XCTAssertGreaterThan(try XCTUnwrap(first).meanLuma, 0.95)
        try save(image { _ in })
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        let changed = await sampler.sample(for: sample)
        XCTAssertLessThan(try XCTUnwrap(changed).meanLuma, 0.05)
        sample.url = directory.appendingPathComponent("missing.png")
        let missing = await sampler.sample(for: sample)
        XCTAssertNil(missing)
    }

    func testCenterLayoutUsesOriginalDimensionsAndClipsToScreen() {
        let area = request(screen, layout: .center)
        XCTAssertEqual(area.imageRect(imageSize: CGSize(width: 40, height: 20)),
                       CGRect(x: 80, y: 40, width: 40, height: 20))
    }

    func testActualFloatingRootRendersOppositeSchemesOverSystemSetting() throws {
        for tone in [BackgroundTone.light, .dark] {
            let model = MorphPresentationModel()
            model.morphology = .capsule
            model.floatingTone = tone
            let view = MorphRootView(model: model, actions: .init(), edge: .top,
                                     floatingShape: .board, appContainer: nil)
                .frame(width: 318, height: 200)
                .environment(\.colorScheme, tone == .light ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let color = try XCTUnwrap(bitmap.colorAt(x: 150, y: 20)?.usingColorSpace(.deviceRGB))
            if tone == .light { XCTAssertGreaterThan(color.redComponent, 0.8) }
            else { XCTAssertLessThan(color.redComponent, 0.15) }
            if let path = ProcessInfo.processInfo.environment["SLP_TEST_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("background-\(tone.rawValue).png"))
            }
        }
    }
}

/// 自动判色的极性：**卡片永远和壁纸相反**。
///
/// 用户反馈"深色背景下转成黑色了"。根因是同一个 `BackgroundTone` 值被当成两种含义：
/// `policy.tone` 说的是"壁纸亮还是暗"，而 `applyBackgroundTone` 收的是"卡片亮还是暗"。
/// 自动路径把前者直接当后者用，于是一张近乎纯黑的壁纸（luma ≈ 0.03）被判成 `.dark`，
/// 卡片也成了黑底——黑压黑，胶囊等于消失。
@MainActor
final class BackgroundTonePolarityTests: XCTestCase {

    private func sample(luma: Double, contrast: Double = 0.02) -> BackgroundSample {
        BackgroundSample(meanLuma: luma, contrast: contrast)
    }

    // MARK: 纯函数

    func testContrastingCardToneIsAlwaysTheOpposite() {
        XCTAssertEqual(BackgroundTone.light.contrastingCardTone, .dark)
        XCTAssertEqual(BackgroundTone.dark.contrastingCardTone, .light)
        XCTAssertEqual(BackgroundTone.dark.contrastingCardTone.contrastingCardTone, .dark)
    }

    /// 采样判定本身仍然描述**壁纸**（日志与调试都依赖它），不能为了修极性把它反过来。
    func testClassificationStillDescribesTheWallpaper() {
        XCTAssertEqual(BackgroundAppearancePolicy.classification(of: sample(luma: 0.95)), .light)
        XCTAssertEqual(BackgroundAppearancePolicy.classification(of: sample(luma: 0.03)), .dark)
        XCTAssertNil(BackgroundAppearancePolicy.classification(of: sample(luma: 0.5)))
    }

    // MARK: 生产路径（与真实代码同一条）

    func testDarkWallpaperProducesLightCard() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.capsule)
        controller.consumeBackgroundSample(sample(luma: 0.03), now: ContinuousClock().now)
        XCTAssertEqual(controller.model.floatingTone, .light, "深色壁纸必须配浅色卡片")
        XCTAssertEqual(controller.debugPanel.appearance?.name, .aqua)
        controller.hide()
    }

    func testBrightWallpaperProducesDarkCard() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.capsule)
        controller.consumeBackgroundSample(sample(luma: 0.96), now: ContinuousClock().now)
        XCTAssertEqual(controller.model.floatingTone, .dark, "浅色壁纸必须配深色卡片")
        XCTAssertEqual(controller.debugPanel.appearance?.name, .darkAqua)
        controller.hide()
    }

    /// 证据不足（明暗混杂）时不切换：卡片回到跟随系统，而不是瞎猜一个。
    func testMixedEvidenceFallsBackToSystemAppearance() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.capsule)
        controller.consumeBackgroundSample(sample(luma: 0.5, contrast: 0.4), now: ContinuousClock().now)
        XCTAssertNil(controller.model.floatingTone)
        XCTAssertNil(controller.debugPanel.appearance)
        controller.hide()
    }

    /// 手动档位直接表达**卡片**色调，不经过反相：选"始终浅色"就必须是浅色卡片。
    func testManualModesAreNotInverted() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.capsule)
        controller.applyFloatingAppearance(.light)
        XCTAssertEqual(controller.model.floatingTone, .light)
        XCTAssertEqual(controller.debugPanel.appearance?.name, .aqua)
        controller.applyFloatingAppearance(.dark)
        XCTAssertEqual(controller.debugPanel.appearance?.name, .darkAqua)
        controller.hide()
    }
}
