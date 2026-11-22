import XCTest
@testable import SpatialLyricsPlayer

/// 边缘吸附（规格 6.1 的「12pt 边缘吸附」）。
///
/// 规则：候选位置离安全区边界小于等于吸附距离时贴到边界，否则原地不动。
/// 吸附只做位移，不允许把窗口推出安全区——否则会出现「卡在菜单栏后面」。
final class EdgeSnapTests: XCTestCase {

    private let zone = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let snap: CGFloat = 12

    func testSnapsLeftEdgeWhenWithinDistance() {
        let rect = CGRect(x: 5, y: 400, width: 200, height: 40)
        let snapped = EdgeSnap.snap(rect, in: zone, distance: snap)
        XCTAssertEqual(snapped.minX, zone.minX, accuracy: 0.001, "距左边界 5pt，应贴到边界")
        XCTAssertEqual(snapped.width, rect.width, accuracy: 0.001, "吸附不得改变尺寸")
        XCTAssertEqual(snapped.height, rect.height, accuracy: 0.001)
    }

    func testSnapsRightEdgeWhenWithinDistance() {
        let rect = CGRect(x: 795, y: 400, width: 200, height: 40)   // 右边距 5pt
        let snapped = EdgeSnap.snap(rect, in: zone, distance: snap)
        XCTAssertEqual(snapped.maxX, zone.maxX, accuracy: 0.001)
    }

    func testLeavesRectAloneWhenFarFromEdges() {
        let rect = CGRect(x: 400, y: 380, width: 200, height: 40)
        let snapped = EdgeSnap.snap(rect, in: zone, distance: snap)
        XCTAssertEqual(snapped, rect, "离边界都超过吸附距离时不应移动，避免无谓抖动")
    }

    func testSnapNeverPushesRectOutsideZone() {
        for x in stride(from: 0.0, through: 800.0, by: 37.0) {
            let rect = CGRect(x: x, y: 300, width: 200, height: 40)
            let snapped = EdgeSnap.snap(rect, in: zone, distance: snap)
            XCTAssertGreaterThanOrEqual(snapped.minX, zone.minX - 0.001, "吸附后不能越过左边界")
            XCTAssertLessThanOrEqual(snapped.maxX, zone.maxX + 0.001, "吸附后不能越过右边界")
        }
    }
}
