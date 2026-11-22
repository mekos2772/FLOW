import XCTest
@testable import SpatialLyricsPlayer

/// 权限降级（规格 §十二 I）。
///
/// 真机上撤销 TCC 会影响用户的正常授权，所以在**依赖注入层**验证：
/// 未授权时不得使用 AX 那一路的结果，也不得谎称识别了外部窗口。
@MainActor
final class PermissionDegradationTests: XCTestCase {

    func testManagerReportsNotGrantedWhenUntrusted() {
        let manager = AccessibilityManager(isTrusted: { false })
        XCTAssertEqual(manager.refresh(), .notGranted)
        XCTAssertEqual(manager.permission, .notGranted)
    }

    func testManagerReportsGrantedWhenTrusted() {
        let manager = AccessibilityManager(isTrusted: { true })
        XCTAssertEqual(manager.refresh(), .granted)
    }

    func testNotGrantedDropsAccessibilityRects() {
        let visible = [CGRect(x: 0, y: 0, width: 800, height: 600)]
        let ax = [CGRect(x: 900, y: 0, width: 400, height: 300)]
        let merged = VisibleWindowScanner.merge(visible: visible,
                                                accessibilityRects: ax,
                                                permission: .notGranted)
        XCTAssertEqual(merged, visible, "未授权时不得把 AX 矩形算进来")
        XCTAssertFalse(merged.contains(ax[0]), "不得假装识别了外部窗口")
    }

    func testGrantedKeepsBothSources() {
        let visible = [CGRect(x: 0, y: 0, width: 800, height: 600)]
        let ax = [CGRect(x: 900, y: 0, width: 400, height: 300)]
        let merged = VisibleWindowScanner.merge(visible: visible,
                                                accessibilityRects: ax,
                                                permission: .granted)
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains(ax[0]))
    }

    /// 未授权时安全区布局仍要工作：不依赖 AX 的窗口扫描照样给出障碍物。
    func testLayoutStillWorksWithoutAccessibility() {
        let screen = ScreenGeometryResolver.mainScreenGeometry()
        let rects = VisibleWindowScanner.merge(
            visible: VisibleWindowScanner.obstacleRects(
                excludingPID: ProcessInfo.processInfo.processIdentifier,
                screenFrame: screen.frame
            ),
            accessibilityRects: [],
            permission: .notGranted
        )
        // 有没有别的窗口取决于当时桌面；关键是这条路径不崩溃、不返回伪造矩形。
        for rect in rects {
            XCTAssertGreaterThan(rect.width, 1)
            XCTAssertGreaterThan(rect.height, 1)
        }
    }
}
