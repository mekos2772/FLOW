import XCTest
@testable import SpatialLyricsPlayer

/// "能不能读窗口信息"的判定。
///
/// 这是一条**安全相关**的谓词：辅助功能权限只有 `.granted` 时才允许读窗口几何。
/// 之前三处调用点各写一遍 `permission == .granted`，谓词本身没人用；
/// 现在统一走 `allowsWindowInspection`，并在这里钉住四种状态的语义。
final class WindowInspectionPermissionTests: XCTestCase {

    func testOnlyGrantedAllowsInspection() {
        XCTAssertTrue(AccessibilityPermission.granted.allowsWindowInspection)
    }

    func testOtherStatesDenyInspection() {
        XCTAssertFalse(AccessibilityPermission.unknown.allowsWindowInspection)
        XCTAssertFalse(AccessibilityPermission.notGranted.allowsWindowInspection)
        XCTAssertFalse(AccessibilityPermission.unavailable.allowsWindowInspection)
    }

    /// 原始值参与持久化与日志，改动会影响诊断文本，钉住它们。
    func testRawValuesAreStable() {
        XCTAssertEqual(AccessibilityPermission.unknown.rawValue, "unknown")
        XCTAssertEqual(AccessibilityPermission.notGranted.rawValue, "notGranted")
        XCTAssertEqual(AccessibilityPermission.granted.rawValue, "granted")
        XCTAssertEqual(AccessibilityPermission.unavailable.rawValue, "unavailable")
    }
}
