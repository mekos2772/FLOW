import XCTest
@testable import SpatialLyricsPlayer

/// 诊断信息里的"本地存储"一行。
///
/// 起因：真机演练（第 119 节）确认损坏库能自动从备份恢复，
/// 但 `restoredFromBackup` / `recoveredFromCorruption` 这两个属性
/// **没有任何地方读**——用户永远不会知道自己少了最近几次改动。
@MainActor
final class StorageStateDiagnosticsTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-storage-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent("SpatialLyrics.store") }

    func testHealthyStoreReportsNormal() throws {
        let controller = try PersistenceController(inMemory: false, storeURL: storeURL)
        XCTAssertEqual(AppContainer.storageState(for: controller), "正常")
    }

    func testRestoredFromBackupIsReported() async throws {
        let first = try PersistenceController(inMemory: false, storeURL: storeURL)
        try await first.makeTrackRepository().save(
            Track(sourceID: "local", externalID: "/tmp/a.mp3", title: "曲目",
                  artist: "某人", album: nil, duration: 200))
        PersistenceController.writeBackup(of: storeURL, at: Date().addingTimeInterval(5))

        // 写坏文件头：下次打开会隔离 + 从备份恢复
        try Data("not sqlite".utf8).write(to: storeURL)

        let second = try PersistenceController(inMemory: false, storeURL: storeURL)
        let state = AppContainer.storageState(for: second)
        XCTAssertTrue(state.contains("备份"), "恢复过备份必须如实告知，实际：\(state)")
        XCTAssertTrue(state.contains("可能缺少"), "还要提醒用户可能缺少最近改动")
    }

    /// 设置页只在异常时显示这一行（正常时不占版面）。
    @MainActor
    func testSettingsNoticeOnlyShowsWhenAbnormal() throws {
        let healthy = try PersistenceController(inMemory: false, storeURL: storeURL)
        XCTAssertEqual(AppContainer.storageState(for: healthy), "正常")
        // 正常时提示文案为 nil（由设置页的 storageNoticeText 决定不渲染这一组）。
        XCTAssertTrue(AppContainer.storageState(for: healthy) == "正常")
    }

    func testDiagnosticsReportContainsStorageLine() throws {
        var facts = DiagnosticsReport.Facts(
            appVersion: "0.1.0", osVersion: "macOS", schemaVersion: "3.0.0",
            accessibilityState: "已授权", queueCount: 2, floatingShape: "胶囊",
            privacyModeEnabled: false, sleepTimerArmed: false, storageState: "正常", runtimeMode: "正常", widgetShared: "可用")
        var text = DiagnosticsReport.render(facts)
        XCTAssertTrue(text.contains("本地存储: 正常"))

        facts.storageState = "本次启动已从备份恢复（可能缺少最近的改动）"
        text = DiagnosticsReport.render(facts)
        XCTAssertTrue(text.contains("从备份恢复"))
    }
}

/// 小组件共享容器的可见性。
///
/// App Group 需要签名与描述文件；未签名构建里 `SharedStateStore` 会退回
/// `UserDefaults.standard`——但**小组件进程**用的是它自己的域，
/// 于是小组件永远读不到数据，而主 App 看不出任何异常。
/// 把这件事写进诊断，至少让排障能从"小组件空白"变成"共享不可用"。
@MainActor
final class WidgetSharingDiagnosticsTests: XCTestCase {

    func testDiagnosticsReportStatesWidgetSharing() {
        let facts = DiagnosticsReport.Facts(
            appVersion: "0.1.0", osVersion: "macOS", schemaVersion: "3.0.0",
            accessibilityState: "已授权", queueCount: 0, floatingShape: "胶囊",
            privacyModeEnabled: false, sleepTimerArmed: false,
            storageState: "正常", runtimeMode: "正常", widgetShared: "不可用（未签名）")
        let text = DiagnosticsReport.render(facts)
        XCTAssertTrue(text.contains("小组件数据共享"), "诊断里要看得到小组件的共享状态")
        XCTAssertTrue(text.contains("不可用"))
    }
}
