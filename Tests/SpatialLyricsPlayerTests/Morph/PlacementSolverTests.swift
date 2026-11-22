import AppKit
import CoreGraphics
import XCTest
@testable import SpatialLyricsPlayer

// PlacementSolver 的全部契约：连续优化、多屏落点、与障碍的关系。

@MainActor
final class PlacementSolverTests: XCTestCase {

    private let zone = CGRect(x: 0, y: 0, width: 1600, height: 900)
    private let solver = ContinuousPlacementSolver()

    /// B. 自由位置：屏幕正中间一块空白，四角都被占住，仍必须能放到中间。
    func testPlacesInMiddleFreeAreaNotCorners() {
        let capsule = PlayerMorphology.capsule.geometry.preferredSize
        // 中间留出 600×400 的空洞（x 500…1100, y 250…650），四周都是障碍
        let obstacles = [
            CGRect(x: 0, y: 0, width: 1600, height: 240),      // 下条
            CGRect(x: 0, y: 660, width: 1600, height: 240),    // 上条
            CGRect(x: 0, y: 240, width: 480, height: 420),     // 左块
            CGRect(x: 1120, y: 240, width: 480, height: 420),  // 右块
        ]
        let solution = solver.solve(
            zone: zone, obstacles: obstacles,
            currentFrame: CGRect(x: 4, y: 4, width: capsule.width, height: capsule.height),
            current: .capsule, preferredOrigin: nil,
            allowed: [.capsule]
        )
        let best = try! XCTUnwrap(solution.best)
        XCTAssertTrue(best.frame.midX > 500 && best.frame.midX < 1100, "应落在中间空洞里：\(best.frame)")
        XCTAssertTrue(best.frame.midY > 240 && best.frame.midY < 660, "应落在中间空洞里：\(best.frame)")
        XCTAssertFalse(obstacles.contains { $0.intersects(best.frame) })
    }

    /// C. 多窗口切出的不规则空间。
    func testFitsIntoIrregularGapBetweenTwoWindows() {
        let capsule = PlayerMorphology.capsule.geometry.preferredSize
        let obstacles = [
            CGRect(x: 0, y: 300, width: 900, height: 600),     // 左上
            CGRect(x: 900, y: 0, width: 700, height: 620),     // 右下
        ]
        // 起点故意放在第一个窗口**里面**，逼它必须离开
        let solution = solver.solve(
            zone: zone, obstacles: obstacles,
            currentFrame: CGRect(x: 100, y: 400, width: capsule.width, height: capsule.height),
            current: .capsule, preferredOrigin: nil, allowed: [.capsule]
        )
        let best = try! XCTUnwrap(solution.best)
        XCTAssertFalse(obstacles.contains { $0.intersects(best.frame) }, "不得与任何窗口相交：\(best.frame)")
        XCTAssertTrue(
            solution.freeRects.contains { $0.contains(best.frame) },
            "落点必须完整落在求解器自己算出的某块自由矩形里：\(best.frame) / \(solution.freeRects)"
        )
    }

    /// D. 稳定：当前位置合法时，一律不动——哪怕别处更空。
    func testKeepsPositionWhenStillLegal() {
        let capsule = PlayerMorphology.capsule.geometry.preferredSize
        let current = CGRect(x: 40, y: 40, width: capsule.width, height: capsule.height)
        let solution = solver.solve(
            zone: zone, obstacles: [CGRect(x: 0, y: 400, width: 1600, height: 500)],
            currentFrame: current, current: .capsule, preferredOrigin: nil, allowed: [.compact, .capsule]
        )
        XCTAssertEqual(solution.best?.frame, current)
        XCTAssertEqual(solution.best?.morphology, .capsule)
        XCTAssertTrue(solution.reason.contains("保持不动"))
    }

    /// E. 形态优先：只有 500×70 的缝，胶囊放得下、迷你放不下 → 不得为了迷你横跨屏幕。
    func testPrefersCapsuleOverCrossScreenCompact() {
        let obstacles = [
            CGRect(x: 0, y: 0, width: 1600, height: 400),
            CGRect(x: 0, y: 470, width: 1600, height: 430),   // 中间留 70pt 高的缝
        ]
        let capsule = PlayerMorphology.capsule.geometry.preferredSize
        let solution = solver.solve(
            zone: zone, obstacles: obstacles,
            currentFrame: CGRect(x: 700, y: 400, width: capsule.width, height: capsule.height),
            current: .capsule, preferredOrigin: nil, allowed: [.compact, .capsule]
        )
        XCTAssertEqual(solution.best?.morphology, .capsule, "缝隙只够胶囊时不应换成迷你")
    }

    /// 落点必须是连续量：同一个空洞，起点不同，落点也应不同（而不是固定角点）。
    func testPositionFollowsCurrentPositionContinuously() {
        let capsule = PlayerMorphology.capsule.geometry.preferredSize
        let obstacles = [CGRect(x: 0, y: 500, width: 1600, height: 400)]
        let wide = CGRect(x: 0, y: 0, width: 1600, height: 500)
        _ = wide

        func solveFrom(x: CGFloat) -> CGRect? {
            solver.solve(zone: zone, obstacles: obstacles,
                         currentFrame: CGRect(x: x, y: 450, width: capsule.width, height: capsule.height),
                         current: .capsule, preferredOrigin: nil, allowed: [.capsule]).best?.frame
        }
        let left = solveFrom(x: 200)!
        let right = solveFrom(x: 1100)!
        XCTAssertNotEqual(left.origin.x, right.origin.x, "落点应随当前位置连续变化，而不是固定角点")
        XCTAssertLessThan(left.origin.x, right.origin.x)
    }

    /// 完全没空间时不硬塞，交给上层降级。
    func testReturnsNoBestWhenNothingFits() {
        let solution = solver.solve(
            zone: zone, obstacles: [zone],
            currentFrame: nil, current: .capsule, preferredOrigin: nil, allowed: [.capsule, .edge]
        )
        XCTAssertNil(solution.best)
        XCTAssertTrue(solution.reason.contains("没有"))
    }
}
@MainActor
final class PlacementTradeoffTests: XCTestCase {
    private let zone = CGRect(x: 0, y: 0, width: 1600, height: 900)

    func testShrinkingInPlaceBeatsCrossScreenMove() throws {
        let solver = ContinuousPlacementSolver()
        // 右下角被一大块占住；左下角留一条 34pt 高的缝；左上方留一大块。
        let obstacles = [
            CGRect(x: 900, y: 0, width: 700, height: 900),   // 右侧整条
            CGRect(x: 0, y: 0, width: 900, height: 300),     // 左下
        ]
        // 当前胶囊就压在右侧障碍里
        let current = CGRect(x: 1200, y: 400, width: 392, height: 56)
        let solution = solver.solve(
            zone: zone, obstacles: obstacles,
            currentFrame: current, current: .capsule,
            preferredOrigin: nil,
            allowed: [.compact, .capsule, .edge]
        )
        let best = try XCTUnwrap(solution.best)
        XCTAssertFalse(obstacles.contains { $0.intersects(best.frame) }, "落点必须合法")
        // 最近的可放置区在左侧；如果评分正确，它应该留在左侧附近而不是乱飞
        XCTAssertLessThan(best.frame.midX, 900, "应选最近的合法区域：\(best.frame)")
    }

    /// 形态代价：同样都能放下时，倾向保持当前形态。
    func testPrefersKeepingMorphologyWhenBothFit() throws {
        let solver = ContinuousPlacementSolver()
        let capsule = PlayerMorphology.capsule.geometry.preferredSize
        let current = CGRect(x: 200, y: 200, width: capsule.width, height: capsule.height)
        let solution = solver.solve(
            zone: zone, obstacles: [CGRect(x: 0, y: 0, width: 1600, height: 150)],
            currentFrame: current, current: .capsule, preferredOrigin: nil,
            allowed: [.compact, .capsule, .edge]
        )
        XCTAssertEqual(solution.best?.morphology, .capsule)
    }
}
@MainActor
final class ClearancePriorityTests: XCTestCase {
    private let zone = CGRect(x: 0, y: 0, width: 1600, height: 900)

    func testPrefersClearSpaceOverNearbyCrampedGap() throws {
        let solver = ContinuousPlacementSolver()
        // 当前位置紧贴左侧；左边只有一条 60pt 高的窄缝（放得下但要压扁），
        // 右边有一大块干净空间（放得下标准尺寸）。
        let obstacles = [
            CGRect(x: 0, y: 0, width: 700, height: 500),      // 左下大块
            CGRect(x: 0, y: 560, width: 700, height: 340),    // 左上大块
            // 左侧只剩 y 500…560 的 60pt 缝
        ]
        let current = CGRect(x: 20, y: 505, width: 392, height: 44)   // 被压扁的胶囊
        let solution = solver.solve(
            zone: zone, obstacles: obstacles,
            currentFrame: current, current: .capsule, preferredOrigin: nil,
            allowed: [.compact, .capsule, .edge]
        )
        let best = try XCTUnwrap(solution.best)
        XCTAssertEqual(best.clearance, 0, "应该找到无遮挡的空间")
        XCTAssertGreaterThan(best.frame.minX, 700, "应该去右边那块干净桌面：\(best.frame)")
        // 只要不是"被压扁"的形态即可——实际选出的是完整的 compact，比压扁的胶囊更好。
        XCTAssertGreaterThanOrEqual(best.frame.height,
                                    PlayerMorphology.capsule.geometry.preferredSize.height - 1,
                                    "不应为了就近而被压扁")
    }

    func testKeepsCurrentWhenAlreadyClear() {
        let solver = ContinuousPlacementSolver()
        let capsule = PlayerMorphology.capsule.geometry.preferredSize
        let current = CGRect(x: 1000, y: 400, width: capsule.width, height: capsule.height)
        let solution = solver.solve(
            zone: zone, obstacles: [CGRect(x: 0, y: 0, width: 700, height: 900)],
            currentFrame: current, current: .capsule, preferredOrigin: nil,
            allowed: [.compact, .capsule, .edge]
        )
        XCTAssertEqual(solution.best?.frame, current, "当前已经无遮挡就不该动")
    }
}
@MainActor
final class MultiDisplayGeometryTests: XCTestCase {

    private let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    /// 副屏挂在主屏左侧：x 为负，AppKit 全局坐标的常见情形。
    private let leftDisplay = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    /// 副屏挂在主屏上方：y 为正。
    private let aboveDisplay = CGRect(x: 0, y: 1117, width: 2560, height: 1440)

    func testSafeZoneOnLeftDisplayIsNotShiftedToMainScreen() {
        let zone = ScreenGeometry.safeZone(
            frame: leftDisplay,
            visibleFrame: leftDisplay.insetBy(dx: 0, dy: 0),
            topInset: 0
        )
        XCTAssertEqual(zone, leftDisplay)
        XCTAssertLessThanOrEqual(zone.maxX, 0, "副屏安全区应落在负坐标侧（右缘接主屏左缘 x=0）")
    }

    func testSafeZoneOnDisplayAboveMainStartsWhereMainEnds() {
        let zone = ScreenGeometry.safeZone(
            frame: aboveDisplay,
            visibleFrame: aboveDisplay,
            topInset: 0
        )
        XCTAssertEqual(zone.minY, main.maxY, "副屏安全区应紧接主屏上沿")
    }

    /// 菜单栏被自动隐藏 + 刘海屏：只扣一次刘海高度，不能重复扣。
    func testNotchInsetAppliedOnceWhenMenuBarHidden() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = frame                       // 菜单栏隐藏 → 可见区顶到物理顶部
        let zone = ScreenGeometry.safeZone(frame: frame, visibleFrame: visible, topInset: 32)
        XCTAssertEqual(zone.height, frame.height - 32, "刘海只应扣一次")
    }

    /// 菜单栏可见时不再扣刘海（菜单栏已经占掉了那块）。
    func testNoDoubleInsetWhenMenuBarVisible() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 957)   // 菜单栏占 25pt
        let zone = ScreenGeometry.safeZone(frame: frame, visibleFrame: visible, topInset: 32)
        XCTAssertEqual(zone.height, 957, "菜单栏可见时不应再扣刘海")
    }

    /// 在副屏的安全区里求解：结果必须落在副屏内，不能跑回主屏。
    func testSolverKeepsPlacementOnSecondaryDisplayZone() {
        let zone = ScreenGeometry.safeZone(frame: leftDisplay, visibleFrame: leftDisplay, topInset: 0)
        let solver = ContinuousPlacementSolver()
        let solution = solver.solve(
            zone: zone,
            obstacles: [CGRect(x: -1800, y: 200, width: 900, height: 700)],
            currentFrame: CGRect(x: -1900, y: 100, width: 392, height: 56),
            current: .capsule,
            preferredOrigin: nil,
            allowed: [.capsule, .compact]
        )
        let best = try! XCTUnwrap(solution.best)
        XCTAssertTrue(zone.contains(best.frame), "落点必须留在副屏安全区内：\(best.frame)")
        XCTAssertLessThanOrEqual(best.frame.maxX, 0, "不应跨回主屏")
    }
}
