import XCTest

/// 启动冒烟：应用能起来、主窗口出现、关键界面可见。
///
/// 两处以前是坏的：
/// 1. 断言的是 Phase 0 骨架文案（`Spatial Lyrics Player` / `Phase 0 · 架构骨架`），
///    产品早就叫 FLOW 了，这条测试如果真跑起来必然失败；
/// 2. 直接用 `XCUIApplication()` 启动，UI 测试是**独立进程**，
///    会读写使用者的真实数据库。现在传 `-SLP_UITest` 走内存库。
@MainActor
final class LaunchSmokeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-SLP_UITest"]
        app.launch()
        return app
    }

    func testAppLaunchesAndShowsWindow() {
        let app = launchApp()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "主窗口未出现")

        // 空闲态必有的一条文案（`OnlineHomeView` 的空态）。
        XCTAssertTrue(
            app.staticTexts["还没有播放"].waitForExistence(timeout: 15),
            "空闲态的「还没有播放」没有出现"
        )
    }

    func testIdleAppShowsNoErrorBanner() {
        let app = launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
        // 启动不该直接弹错误（联网关闭时也只是提示，不是报错）。
        XCTAssertFalse(app.staticTexts["出错了"].exists)
    }
}
