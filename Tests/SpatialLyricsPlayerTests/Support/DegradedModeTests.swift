import XCTest
@testable import SpatialLyricsPlayer

/// 降级模式必须**可见**。
///
/// 容器构建失败时，App 会退到"内存设置 + 示例曲库"，这是既定的兜底策略；
/// 但之前这件事**只在日志里**：用户看到的是一个正常界面、里面全是示例曲目，
/// 收藏也不保存——看起来就是"App 坏了"。
@MainActor
final class DegradedModeTests: XCTestCase {

    func testFallbackContainerCarriesReason() throws {
        let fallback = ContainerBuilder.makeFallback()
        let reason = try XCTUnwrap(fallback.degradedReason, "兜底容器必须带上降级原因")
        XCTAssertTrue(reason.contains("临时设置"), "文案要说清后果，实际：\(reason)")
        XCTAssertTrue(reason.contains("不会") || reason.contains("不被保存"), "还要说明数据不保存")
    }

    func testDiagnosticsReportShowsRuntimeMode() throws {
        let facts = DiagnosticsReport.Facts(
            appVersion: "0.1.0", osVersion: "macOS", schemaVersion: "3.0.0",
            accessibilityState: "已授权", queueCount: 0, floatingShape: "胶囊",
            privacyModeEnabled: false, sleepTimerArmed: false,
            storageState: "正常", runtimeMode: "降级（临时设置，不写盘）", widgetShared: "可用")
        let text = DiagnosticsReport.render(facts)
        XCTAssertTrue(text.contains("运行模式: 降级"), "诊断里要看得到运行模式")
    }

    func testNormalContainerHasNoReason() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        XCTAssertNil(container.degradedReason, "正常容器不该带降级原因")
    }
}
