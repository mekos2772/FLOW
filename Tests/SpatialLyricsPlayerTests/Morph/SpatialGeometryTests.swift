import XCTest
@testable import SpatialLyricsPlayer

/// 纯几何算法测试，不依赖真实窗口。
final class SpatialGeometryTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: - 安全区

    func testSafeZoneKeepsVisibleFrameWhenMenuBarVisible() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let zone = ScreenGeometry.safeZone(frame: screen, visibleFrame: visible, topInset: 32)
        XCTAssertEqual(zone, visible, "菜单栏可见时刘海已被覆盖，不得重复扣除")
    }

    func testSafeZoneInsetTopWhenMenuBarHidden() {
        // 菜单栏自动隐藏：visibleFrame 顶到屏幕物理顶部，此时必须扣掉刘海。
        let visible = screen
        let zone = ScreenGeometry.safeZone(frame: screen, visibleFrame: visible, topInset: 32)
        XCTAssertEqual(zone.height, 900 - 32, accuracy: 0.001)
        XCTAssertEqual(zone.maxY, 900 - 32, accuracy: 0.001, "顶部内缩意味着可用区上界下移")
    }

    func testSafeZoneIgnoresZeroTopInset() {
        let zone = ScreenGeometry.safeZone(frame: screen, visibleFrame: screen, topInset: 0)
        XCTAssertEqual(zone, screen)
    }

    // MARK: - 钳制

    func testClampPullsWindowBackIntoZone() {
        let zone = CGRect(x: 100, y: 100, width: 800, height: 600)
        let frame = CGRect(x: 1200, y: 900, width: 300, height: 100)
        let clamped = frame.clamped(into: zone)
        XCTAssertTrue(zone.contains(clamped))
    }

    func testClampShrinksOversizedWindow() {
        let zone = CGRect(x: 0, y: 0, width: 400, height: 300)
        let frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let clamped = frame.clamped(into: zone)
        XCTAssertLessThanOrEqual(clamped.width, 400)
        XCTAssertLessThanOrEqual(clamped.height, 300)
        XCTAssertTrue(zone.contains(clamped))
    }

    func testClampLeavesValidFrameUnchanged() {
        let zone = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frame = CGRect(x: 200, y: 200, width: 300, height: 100)
        XCTAssertEqual(frame.clamped(into: zone), frame)
    }

    func testClampHandlesEmptyZone() {
        let frame = CGRect(x: 10, y: 10, width: 100, height: 40)
        XCTAssertEqual(frame.clamped(into: .zero), frame, "空安全区时保持原样，交给上层回退主屏")
    }

    // MARK: - 吸附

    func testSnapLeftEdgeWithinDistance() {
        let zone = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = CGRect(x: 8, y: 400, width: 200, height: 50)
        XCTAssertEqual(EdgeSnap.snap(frame, in: zone).minX, 0, accuracy: 0.001)
    }

    func testNoSnapBeyondDistance() {
        let zone = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = CGRect(x: 40, y: 400, width: 200, height: 50)
        XCTAssertEqual(EdgeSnap.snap(frame, in: zone).minX, 40, accuracy: 0.001)
    }

    func testSnapBindsBothAxesAtCorner() {
        let zone = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = CGRect(x: 6, y: 5, width: 200, height: 50)
        let snapped = EdgeSnap.snap(frame, in: zone)
        XCTAssertEqual(snapped.minX, 0, accuracy: 0.001)
        XCTAssertEqual(snapped.minY, 0, accuracy: 0.001)
    }

    func testSnapRespectsCustomDistance() {
        let zone = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = CGRect(x: 8, y: 400, width: 200, height: 50)
        XCTAssertEqual(EdgeSnap.snap(frame, in: zone, distance: 4).minX, 8, accuracy: 0.001)
        XCTAssertEqual(EdgeSnap.snap(frame, in: zone, distance: 12).minX, 0, accuracy: 0.001)
    }

    // MARK: - 形态尺寸

    func testShapeMetricsAreSane() {
        for shape in LyricsShape.allCases {
            XCTAssertLessThanOrEqual(shape.minimumSize.width, shape.preferredSize.width, "\(shape)")
            XCTAssertLessThanOrEqual(shape.minimumSize.height, shape.preferredSize.height, "\(shape)")
            XCTAssertGreaterThan(shape.minimumSize.width, 0)
        }
    }

    func testShapeCyclesThroughAllFour() {
        var seen: [LyricsShape] = []
        var current = LyricsShape.capsule
        for _ in 0..<4 {
            seen.append(current)
            current = current.next
        }
        XCTAssertEqual(seen, LyricsShape.allCases)
        XCTAssertEqual(current, .capsule, "四次循环应回到起点")
    }
}
