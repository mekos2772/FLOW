import CoreGraphics
import XCTest
@testable import SpatialLyricsPlayer

/// 桌面窗口扫描的契约。
///
/// 这一层不需要辅助功能权限，因此"拒绝授权"场景下避让仍然有效——
/// 这是规格 §十二 I 能验证的那一半。
@MainActor
final class VisibleWindowScannerTests: XCTestCase {

    private func window(pid: pid_t, frame: CGRect) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: 0,
         kCGWindowIsOnscreen as String: true,
         kCGWindowBounds as String: frame.dictionaryRepresentation,
         kCGWindowAlpha as String: 1.0]
    }

    func testExcludesOwnWindows() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let rects = VisibleWindowScanner.obstacleRects(
            in: [window(pid: 123, frame: screen)], excludingPID: 123,
            screenFrame: screen, primaryMaxY: screen.maxY)
        XCTAssertTrue(rects.isEmpty, "自己的全屏窗口应按 PID 排除，不取决于真实桌面布局")
    }

    func testAnotherApplicationsFullscreenRemainsAnObstacle() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let rects = VisibleWindowScanner.obstacleRects(
            in: [window(pid: 123, frame: screen), window(pid: 456, frame: screen)],
            excludingPID: 123, screenFrame: screen, primaryMaxY: screen.maxY)
        XCTAssertEqual(rects, [screen], "他人全屏应占满空白，不能为了测试通过而过滤")
    }

    func testReturnsOnlyPlausibleWindows() {
        let screen = ScreenGeometryResolver.mainScreenGeometry().frame
        let rects = VisibleWindowScanner.obstacleRects(
            excludingPID: 1,                 // 故意排除一个不存在的 PID，让所有窗口都进来
            screenFrame: screen,
            minimumArea: 120 * 80
        )
        for rect in rects {
            XCTAssertGreaterThanOrEqual(rect.width * rect.height, 120 * 80, "过小的窗口应被过滤：\(rect)")
            XCTAssertGreaterThan(rect.width, 1)
            XCTAssertGreaterThan(rect.height, 1)
        }
    }

    /// 扫描结果必须落在以主屏为基准的坐标系里（允许别的屏的窗口超出主屏范围）。
    func testRectsUseAppKitCoordinates() {
        let screen = ScreenGeometryResolver.mainScreenGeometry().frame
        let rects = VisibleWindowScanner.obstacleRects(excludingPID: 1, screenFrame: screen)
        for rect in rects where rect.maxY <= screen.maxY + 1 {
            XCTAssertGreaterThanOrEqual(rect.minY, -1, "不应出现整块落在屏幕下方之外的窗口：\(rect)")
        }
    }
}
