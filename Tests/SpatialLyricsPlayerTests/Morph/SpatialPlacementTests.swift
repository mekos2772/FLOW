import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

// 空间布局的全部契约：空闲空间分析、规划器、机会判定、多屏。

final class SpatialPlacementTests: XCTestCase {

    private let zone = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private var solver = PlacementSolver()

    private func snapshot(
        zone: CGRect? = nil,
        obstacles: [CGRect] = [],
        current: CGRect? = nil,
        shape: LyricsShape = .capsule,
        locked: Bool = false,
        fullscreen: Bool = false,
        preferred: CGPoint? = nil,
        permission: AccessibilityPermission = .granted
    ) -> SpatialSnapshot {
        SpatialSnapshot(
            displayID: "TEST",
            safeZone: zone ?? self.zone,
            screenFrame: zone ?? self.zone,
            obstacles: obstacles,
            frontmostApp: FrontmostAppInfo(bundleID: "com.test", name: "Test", isFullscreen: fullscreen),
            floatingFrame: current,
            preferredSize: shape.preferredSize,
            currentShape: shape,
            userPreferredOrigin: preferred,
            isLocked: locked,
            permission: permission
        )
    }

    // MARK: - 1. 无障碍物

    func testNoObstaclesKeepsCurrentShapeAndStaysInside() {
        let decision = solver.solve(snapshot())
        XCTAssertTrue(zone.contains(decision.frame))
        XCTAssertEqual(decision.shape, .capsule, "无障碍物时应尊重当前形态，不无理由变形")
        XCTAssertFalse(decision.shouldHide)
    }

    func testNoObstaclesPrefersEdgeAnchoring() {
        let decision = solver.solve(snapshot())
        let distances = [
            decision.frame.minX - zone.minX,
            zone.maxX - decision.frame.maxX,
            decision.frame.minY - zone.minY,
            zone.maxY - decision.frame.maxY,
        ]
        XCTAssertLessThan(distances.min() ?? .infinity, 1.5, "应贴住某一条安全区边界")
    }

    // MARK: - 2. 单个居中窗口

    func testSingleCenteredWindowAvoidsIt() {
        let window = CGRect(x: 370, y: 200, width: 700, height: 500)
        let decision = solver.solve(snapshot(obstacles: [window]))
        XCTAssertFalse(decision.frame.intersects(window), "不得压在前台窗口上")
        XCTAssertTrue(zone.contains(decision.frame))
    }

    // MARK: - 3. 两个左右窗口

    func testTwoSideWindowsFindGap() {
        let left = CGRect(x: 0, y: 100, width: 620, height: 700)
        let right = CGRect(x: 820, y: 100, width: 620, height: 700)
        let decision = solver.solve(snapshot(obstacles: [left, right]))

        XCTAssertFalse(decision.frame.intersects(left))
        XCTAssertFalse(decision.frame.intersects(right))
    }

    // MARK: - 4. 三个不规则窗口

    func testThreeIrregularWindows() {
        let obstacles = [
            CGRect(x: 40, y: 500, width: 500, height: 300),
            CGRect(x: 700, y: 120, width: 400, height: 400),
            CGRect(x: 1050, y: 560, width: 380, height: 300),
        ]
        let decision = solver.solve(snapshot(obstacles: obstacles))

        for obstacle in obstacles {
            XCTAssertFalse(decision.frame.intersects(obstacle), "压到了 \(obstacle)")
        }
        XCTAssertTrue(zone.contains(decision.frame))
    }

    // MARK: - 5. 窗口几乎占满全屏

    func testAlmostFullScreenWindowFallsBackToEdge() {
        let window = CGRect(x: 20, y: 20, width: 1400, height: 840)
        let decision = solver.solve(snapshot(obstacles: [window]))

        XCTAssertEqual(decision.reason, .fallbackEdge, "没有任何合法候选时应贴最近边")
        XCTAssertTrue(zone.contains(decision.frame))
        XCTAssertFalse(decision.shouldHide)
    }

    // MARK: - 6. 顶部仅剩一条区域

    func testNarrowTopStripShrinksShape() {
        // 只剩 45pt 高：胶囊需要 46pt，只有贴边形态（38pt）放得下。
        let window = CGRect(x: 0, y: 0, width: 1440, height: 830)
        let decision = solver.solve(snapshot(obstacles: [window]))

        XCTAssertEqual(decision.shape, .edge, "空间不足应自动降级到更紧凑形态")
        XCTAssertFalse(decision.frame.intersects(window))
    }

    // MARK: - 7. 底部空白区

    func testBottomGapIsUsedWhenTopIsBlocked() {
        let window = CGRect(x: 0, y: 300, width: 1440, height: 575)
        let decision = solver.solve(snapshot(obstacles: [window]))

        XCTAssertFalse(decision.frame.intersects(window))
        XCTAssertLessThanOrEqual(decision.frame.maxY, 300.5)
    }

    // MARK: - 8/9/10. 多屏、窄屏、不同缩放

    func testNarrowScreenStillFitsInsideSafeZone() {
        let narrow = CGRect(x: 0, y: 0, width: 700, height: 600)
        let window = CGRect(x: 0, y: 0, width: 700, height: 420)
        let decision = solver.solve(snapshot(zone: narrow, obstacles: [window]))

        XCTAssertTrue(narrow.contains(decision.frame))
        XCTAssertFalse(decision.frame.intersects(window))
    }

    func testRetinaScaleZoneProducesProportionallySameResult() {
        let small = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let retina = CGRect(x: 0, y: 0, width: 2880, height: 1750)

        let a = solver.solve(snapshot(zone: small))
        let b = solver.solve(snapshot(zone: retina))

        let ratioA = a.frame.minX / small.width
        let ratioB = b.frame.minX / retina.width
        XCTAssertEqual(ratioA, ratioB, accuracy: 0.05, "不同缩放下归一化位置应一致")
    }

    // MARK: - 11. 极长歌词

    func testOversizedShapeFallsBackIntoZone() {
        let tiny = CGRect(x: 0, y: 0, width: 420, height: 300)
        let decision = solver.solve(snapshot(zone: tiny, shape: .board))

        XCTAssertTrue(tiny.contains(decision.frame), "再长的歌词也必须留在屏内")
        XCTAssertLessThanOrEqual(decision.frame.width, tiny.width)
    }

    // MARK: - 12. 全屏

    func testFullscreenHidesOverlay() {
        let decision = solver.solve(snapshot(fullscreen: true))
        XCTAssertTrue(decision.shouldHide)
        XCTAssertEqual(decision.reason, .hidden)
    }

    // MARK: - 13. 权限缺失

    func testWithoutPermissionSolverStillWorksOnSafeZoneOnly() {
        let decision = solver.solve(snapshot(permission: .notGranted))
        XCTAssertTrue(zone.contains(decision.frame))
        XCTAssertFalse(decision.shouldHide, "无权限不得导致隐藏或崩溃")
    }

    // MARK: - 14. 用户锁定

    func testLockedWindowIsNotMovedByBetterScore() {
        let current = CGRect(x: 600, y: 400, width: 380, height: 46)
        let decision = solver.solve(snapshot(obstacles: [CGRect(x: 0, y: 0, width: 300, height: 300)],
                                             current: current, locked: true))

        XCTAssertEqual(decision.reason, .locked)
        XCTAssertEqual(decision.frame.origin.x, current.origin.x, accuracy: 0.5)
        XCTAssertEqual(decision.frame.origin.y, current.origin.y, accuracy: 0.5)
    }

    func testLockedWindowIsStillClampedIntoVisibleArea() {
        let offscreen = CGRect(x: 5000, y: -400, width: 380, height: 46)
        let decision = solver.solve(snapshot(current: offscreen, locked: true))

        XCTAssertEqual(decision.reason, .locked)
        XCTAssertTrue(zone.contains(decision.frame), "锁定不能成为越界的借口")
    }

    // MARK: - 15/16. 显示器断开与恢复

    func testNormalizedPositionRoundTripsAcrossDisplayChanges() {
        let origin = CGPoint(x: 800, y: 700)
        let normalized = SpatialCoordinator.normalized(origin: origin, shape: .capsule, in: zone)

        let restored = SpatialCoordinator.denormalized(normalized, shape: .capsule, in: zone)
        XCTAssertEqual(restored.origin.x, origin.x, accuracy: 1)
        XCTAssertEqual(restored.origin.y, origin.y, accuracy: 1)

        // 换成更小的副屏后，仍应落在新屏内。
        let secondary = CGRect(x: 0, y: 0, width: 900, height: 600)
        let moved = SpatialCoordinator.denormalized(normalized, shape: .capsule, in: secondary)
        XCTAssertTrue(secondary.contains(moved))
    }

    func testNormalizedClampsOutOfRangeInput() {
        let outside = SpatialCoordinator.normalized(origin: CGPoint(x: -500, y: 5000), shape: .capsule, in: zone)
        XCTAssertEqual(outside.x, 0, accuracy: 0.001)
        XCTAssertEqual(outside.y, 1, accuracy: 0.001)
    }

    // MARK: - 17. 快速连续 Resize（防抖）

    func testRapidResizeEventsAreCoalescedIntoOneSolve() {
        var machine = SpatialStateMachine()
        let start = ContinuousClock().now

        for index in 0..<8 {
            let outcome = machine.handle(.windowResized, now: start.advanced(by: .milliseconds(index * 10)))
            XCTAssertEqual(outcome.state, .evaluating)
            XCTAssertFalse(outcome.requestSolve, "防抖窗口内不得求解")
        }

        let beforeDeadline = machine.handle(.tick, now: start.advanced(by: .milliseconds(60)))
        XCTAssertFalse(beforeDeadline.requestSolve)

        // 最后一次事件在 70ms，debounce 100ms → 170ms 到期。
        let afterDeadline = machine.handle(.tick, now: start.advanced(by: .milliseconds(200)))
        XCTAssertTrue(afterDeadline.requestSolve, "窗口停止移动后应求解一次")
        XCTAssertEqual(afterDeadline.state, .repositioning)
    }

    // MARK: - 18. 窗口小幅移动（滞回）

    func testSmallChangeKeepsCurrentPosition() {
        let current = CGRect(x: 0, y: 829, width: 380, height: 46)
        let decision = solver.solve(snapshot(current: current))
        XCTAssertEqual(decision.reason, .keepCurrent, "当前位置仍有效时不得因微小改善而跳动")
        XCTAssertEqual(decision.frame.origin.x, current.origin.x, accuracy: 0.5)
    }

    func testObstructedCurrentPositionForcesMove() {
        let current = CGRect(x: 500, y: 400, width: 380, height: 46)
        let window = CGRect(x: 400, y: 300, width: 700, height: 400)
        let decision = solver.solve(snapshot(obstacles: [window], current: current))

        XCTAssertNotEqual(decision.reason, .keepCurrent)
        XCTAssertFalse(decision.frame.intersects(window))
    }

    // MARK: - 19. 形态反复变化（冷却）

    func testMorphologyCooldownBlocksReevaluation() {
        var machine = SpatialStateMachine()
        let start = ContinuousClock().now

        _ = machine.handle(.lyricShapeChanged, now: start)
        XCTAssertEqual(machine.state, .morphing)

        let during = machine.handle(.windowMoved, now: start.advanced(by: .milliseconds(200)))
        XCTAssertEqual(during.state, .morphing, "冷却期内不接受新的求解请求")
        XCTAssertFalse(during.requestSolve)

        let after = machine.handle(.tick, now: start.advanced(by: .milliseconds(900)))
        XCTAssertEqual(after.state, .following)
    }

    // MARK: - 20. 候选同分（确定性）

    func testSolverIsDeterministic() {
        let obstacles = [CGRect(x: 300, y: 300, width: 600, height: 400)]
        let first = solver.solve(snapshot(obstacles: obstacles))
        let second = solver.solve(snapshot(obstacles: obstacles))
        XCTAssertEqual(first, second, "同分候选必须有稳定次序，否则会来回横跳")
    }

    // MARK: - 21. 不存在合法候选

    func testNoLegalCandidateStillReturnsVisibleFrame() {
        let wall = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let decision = solver.solve(snapshot(obstacles: [wall]))

        XCTAssertEqual(decision.reason, .fallbackEdge)
        XCTAssertTrue(zone.contains(decision.frame))
        XCTAssertFalse(decision.shouldHide, "整屏被占也保持可见，只是贴边")
    }

    // MARK: - 底层算法

    func testFreeSpaceReturnsWholeZoneWithoutObstacles() {
        XCTAssertEqual(FreeSpaceAnalyzer.maximalRects(in: zone, obstacles: []), [zone])
    }

    func testFreeSpaceNeverOverlapsObstacles() {
        let obstacles = [CGRect(x: 200, y: 200, width: 400, height: 300)]
        let rects = FreeSpaceAnalyzer.maximalRects(in: zone, obstacles: obstacles)
        XCTAssertFalse(rects.isEmpty)
        for rect in rects {
            XCTAssertFalse(rect.intersects(obstacles[0]))
        }
    }

    func testFreeSpaceEmptyWhenFullyCovered() {
        XCTAssertTrue(FreeSpaceAnalyzer.maximalRects(in: zone, obstacles: [zone]).isEmpty)
    }

    func testStateMachineIgnoresGeometryEventsWhileLocked() {
        var machine = SpatialStateMachine()
        _ = machine.handle(.userLocked, now: ContinuousClock().now)
        let outcome = machine.handle(.windowMoved, now: ContinuousClock().now)
        XCTAssertEqual(outcome.state, .locked)
        XCTAssertFalse(outcome.requestSolve)
    }

    func testStateMachineHidesWhileFullscreen() {
        var machine = SpatialStateMachine()
        let entered = machine.handle(.fullscreenEntered, now: ContinuousClock().now)
        XCTAssertTrue(entered.isHidden)

        let moved = machine.handle(.windowMoved, now: ContinuousClock().now)
        XCTAssertFalse(moved.requestSolve, "全屏期间不做求解")

        let exited = machine.handle(.fullscreenExited, now: ContinuousClock().now)
        XCTAssertTrue(exited.requestSolve)
    }

    func testSleepSuspendsSolving() {
        var machine = SpatialStateMachine()
        _ = machine.handle(.sleep, now: ContinuousClock().now)
        let outcome = machine.handle(.windowMoved, now: ContinuousClock().now)
        XCTAssertEqual(outcome.state, .suspended)
        XCTAssertFalse(outcome.requestSolve)
    }

    // MARK: - 回归：被遮挡的当前位置不得保持

    /// 这条用例来自一次真实桌面验证：Calculator 覆盖了悬浮面板左侧 96pt（约 25% 面积），
    /// 当时面板没有让开。排查后确认求解器在遮挡 0.253 时确实会移动（best 比当前高 53%），
    /// 问题出在测试坐标没真正重叠。把该场景固化下来，防止滞回逻辑以后退化成"永远保持"。
    func testOccludedCurrentPositionIsNotKept() {
        let current = CGRect(x: 834, y: 83, width: 380, height: 46)
        let obstacle = CGRect(x: 700, y: 79, width: 230, height: 408)

        let decision = solver.solve(snapshot(obstacles: [obstacle], current: current))

        XCTAssertNotEqual(decision.reason, .keepCurrent, "当前位被遮挡约 25% 时不得原地不动")
        XCTAssertTrue(obstacle.intersection(decision.frame).isNull, "新位置必须完全避开障碍物")
        XCTAssertTrue(zone.contains(decision.frame), "新位置必须仍在安全区内")
    }
}
@MainActor
final class FreeSpaceMaximalityTests: XCTestCase {
    private let zone = CGRect(x: 0, y: 0, width: 1600, height: 900)

    func testNoRectIsContainedInAnother() {
        let obstacles = [
            CGRect(x: 300, y: 200, width: 400, height: 300),
            CGRect(x: 900, y: 100, width: 200, height: 700),
            CGRect(x: 100, y: 600, width: 500, height: 200),
        ]
        let rects = FreeSpaceAnalyzer.maximalRects(in: zone, obstacles: obstacles)
        XCTAssertFalse(rects.isEmpty)
        for inner in rects {
            for outer in rects where outer != inner {
                let contained = outer.minX <= inner.minX + 0.01 && outer.minY <= inner.minY + 0.01
                    && outer.maxX >= inner.maxX - 0.01 && outer.maxY >= inner.maxY - 0.01
                XCTAssertFalse(contained, "\(inner) 被 \(outer) 完全包含，应被剪掉")
            }
        }
    }

    func testKeepsAllUsableSpace() {
        let obstacles = [CGRect(x: 400, y: 300, width: 500, height: 300)]
        let rects = FreeSpaceAnalyzer.maximalRects(in: zone, obstacles: obstacles)
        // 障碍物左右两侧都应有矩形覆盖
        XCTAssertTrue(rects.contains { $0.contains(CGPoint(x: 390, y: 400)) }, "左侧空间丢失")
        XCTAssertTrue(rects.contains { $0.contains(CGPoint(x: 910, y: 400)) }, "右侧空间丢失")
    }

    func testNoObstaclesReturnsWholeZone() {
        XCTAssertEqual(FreeSpaceAnalyzer.maximalRects(in: zone, obstacles: []), [zone])
    }

    func testOverlappingObstaclesDoNotProduceNegativeSpace() {
        let obstacles = [
            CGRect(x: 100, y: 100, width: 600, height: 600),
            CGRect(x: 300, y: 300, width: 600, height: 600),
            CGRect(x: 500, y: 200, width: 200, height: 800),
        ]
        let rects = FreeSpaceAnalyzer.maximalRects(in: zone, obstacles: obstacles)
        for rect in rects {
            XCTAssertFalse(obstacles.contains { $0.intersects(rect) }, "\(rect) 与障碍物相交")
            XCTAssertTrue(zone.contains(rect), "\(rect) 越出安全区")
        }
    }
}
@MainActor
final class AdaptiveSpatialTests: XCTestCase {
    private let zone = CGRect(x: 0, y: 0, width: 1600, height: 900)

    func testContinuousEventsDoNotPostponeEvaluation() {
        var schedule = SpatialEvaluationSchedule()
        let now = ContinuousClock().now
        XCTAssertTrue(schedule.request(now: now, delay: .milliseconds(80)))
        for time in stride(from: 10, through: 70, by: 10) {
            XCTAssertFalse(schedule.request(now: now.advanced(by: .milliseconds(time)), delay: .milliseconds(80)))
        }
        XCTAssertEqual(schedule.deadline, now.advanced(by: .milliseconds(80)))
        schedule.consume()
        XCTAssertTrue(schedule.request(now: now, delay: .zero))
    }

    func testImmediateEventCanAdvanceDeadline() {
        var schedule = SpatialEvaluationSchedule()
        let now = ContinuousClock().now
        XCTAssertTrue(schedule.request(now: now, delay: .seconds(1)))
        XCTAssertTrue(schedule.request(now: now, delay: .milliseconds(80)))
        XCTAssertFalse(schedule.request(now: now, delay: .seconds(1)))
    }

    func testEmptyDesktopRestoresDormantWithoutExpandingMainWindow() throws {
        let result = AdaptivePlacementPlanner().evaluate(
            .init(safeZone: zone, obstacles: [], currentFrame: CGRect(x: 10, y: 200, width: 26, height: 72), current: .dormant),
            permitsMorphing: true, promotionImprovement: 0.18, version: 12)
        XCTAssertEqual(result.evaluation.recommendation.morphology, .compact)
        XCTAssertEqual(result.solution.snapshotVersion, 12)
        XCTAssertNotNil(result.solution.best)
    }

    func testBlockedPlayerGetsLegalPlacementInSameDecision() throws {
        let obstacles = [CGRect(x: 0, y: 0, width: 800, height: 900)]
        let result = AdaptivePlacementPlanner().evaluate(
            .init(safeZone: zone, obstacles: obstacles, currentFrame: CGRect(x: 100, y: 200, width: 420, height: 80), current: .compact),
            permitsMorphing: true, promotionImprovement: 0.18, version: 2)
        let best = try XCTUnwrap(result.solution.best)
        XCTAssertEqual(result.evaluation.recommendation.morphology, best.morphology)
        XCTAssertFalse(obstacles.contains { $0.intersects(best.frame) })
    }

    func testFullDesktopChoosesHandleAndEmptyDesktopRecovers() {
        let planner = AdaptivePlacementPlanner()
        let full = planner.evaluate(.init(safeZone: zone, obstacles: [zone], currentFrame: nil, current: .capsule),
                                    permitsMorphing: true, promotionImprovement: 0.18, version: 1)
        XCTAssertEqual(full.evaluation.recommendation.morphology, .dormant)
        let empty = planner.evaluate(.init(safeZone: zone, obstacles: [], currentFrame: nil, current: .dormant),
                                     permitsMorphing: true, promotionImprovement: 0.18, version: 2)
        XCTAssertEqual(empty.evaluation.recommendation.morphology, .compact)
    }

    func testLockedFormStillRelocatesWithoutChangingForm() throws {
        let result = AdaptivePlacementPlanner().evaluate(
            .init(safeZone: zone, obstacles: [CGRect(x: 0, y: 0, width: 800, height: 900)],
                  currentFrame: CGRect(x: 100, y: 200, width: 392, height: 56), current: .capsule),
            permitsMorphing: false, promotionImprovement: 0.18, version: 3)
        XCTAssertEqual(result.solution.best?.morphology, .capsule)
        XCTAssertGreaterThan(try XCTUnwrap(result.solution.best).frame.minX, 800)
    }

    func testSolverNeverReturnsDisallowedCurrentForm() {
        let result = ContinuousPlacementSolver().solve(zone: zone, obstacles: [],
            currentFrame: CGRect(x: 100, y: 200, width: 392, height: 56), current: .capsule,
            preferredOrigin: nil, allowed: [.compact])
        XCTAssertEqual(result.best?.morphology, .compact)
    }

    func testDesktopTranslationDoesNotChangeScore() {
        let solver = ContinuousPlacementSolver()
        let frame = CGRect(x: 300, y: 300, width: 392, height: 56)
        let original = solver.score(frame: frame, morphology: .capsule, zone: zone, obstacles: [],
                                    currentFrame: frame, current: .capsule, preferredOrigin: nil)
        let offset = frame.offsetBy(dx: -1800, dy: 1200)
        let translated = solver.score(frame: offset, morphology: .capsule, zone: zone.offsetBy(dx: -1800, dy: 1200),
                                      obstacles: [], currentFrame: offset, current: .capsule, preferredOrigin: nil)
        XCTAssertEqual(original, translated, accuracy: 0.0001)
    }

    func testSecondaryDisplayUsesPrimaryCoordinateOrigin() {
        let cg = CGRect(x: 100, y: -900, width: 500, height: 400)
        XCTAssertEqual(VisibleWindowScanner.appKitRect(cg, primaryMaxY: 1080),
                       CGRect(x: 100, y: 1580, width: 500, height: 400))
    }

    func testRecoveryWaitsForStableSpaceThenHasExplicitDeadline() throws {
        let now = ContinuousClock().now
        var state = MorphologyState()
        state.current = .dormant
        var machine = MorphologyStateMachine(state: state)
        let recommendation = MorphologyRecommendation(morphology: .compact, fitsPreferred: true,
                                                      currentStillFits: true, availableSize: zone.size)
        let initial = machine.handle(.environmentEvaluated(recommendation), now: now)
        XCTAssertTrue(initial.actions.isEmpty)
        let deadline = try XCTUnwrap(machine.nextAutomaticEvaluation(after: now))
        _ = machine.handle(.environmentEvaluated(recommendation), now: now.advanced(by: .milliseconds(100)))
        XCTAssertEqual(machine.nextAutomaticEvaluation(after: now), deadline, "重复通知不重置恢复等待")
        XCTAssertEqual(machine.handle(.tick, now: deadline).state.current, .compact)
    }

    func testExpandedGraceSchedulesRetryWithoutAnotherWindowEvent() throws {
        let now = ContinuousClock().now
        var machine = MorphologyStateMachine()
        _ = machine.handle(.userRequested(.expanded), now: now)
        _ = machine.handle(.appDeactivated, now: now)
        _ = machine.handle(.environmentEvaluated(.init(morphology: .capsule, fitsPreferred: true,
                                                      currentStillFits: false, availableSize: zone.size)), now: now)
        let deadline = try XCTUnwrap(machine.nextAutomaticEvaluation(after: now))
        XCTAssertEqual(machine.handle(.tick, now: deadline).state.current, .capsule)
    }

    func testAutomaticEvaluationDoesNotInterruptAnimationButUserCan() {
        let now = ContinuousClock().now
        var machine = MorphologyStateMachine()
        _ = machine.handle(.userRequested(.capsule), now: now)
        let auto = machine.handle(.environmentEvaluated(.init(morphology: .edge, fitsPreferred: true,
                                                             currentStillFits: false, availableSize: .zero)),
                                  now: now.advanced(by: .seconds(10)))
        XCTAssertTrue(auto.actions.isEmpty)
        XCTAssertEqual(machine.handle(.userOpened, now: now).state.current, .expanded)
    }

    func testSweepMatchesExhaustiveReferenceAcrossGeneratedLayouts() {
        let small = CGRect(x: 0, y: 0, width: 100, height: 100)
        var seed: UInt64 = 42
        func random(_ max: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 32) % UInt64(max))
        }
        for _ in 0..<80 {
            let obstacles = (0..<5).map { _ in CGRect(x: random(100), y: random(100), width: random(45) + 1, height: random(45) + 1) }
            let actual = FreeSpaceAnalyzer.maximalRects(in: small, obstacles: obstacles)
            let expected = exhaustive(zone: small, obstacles: obstacles)
            XCTAssertEqual(actual.count, expected.count)
            XCTAssertTrue(expected.allSatisfy { actual.contains($0) })
        }
    }

    func testCrowdedDesktopSweepPerformance() {
        var obstacles: [CGRect] = []
        for i in 0..<24 {
            let x = CGFloat((i * 137) % 1450)
            let y = CGFloat((i * 83) % 800)
            obstacles.append(CGRect(x: x, y: y, width: CGFloat(90 + i * 3), height: CGFloat(60 + i * 2)))
        }
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<10 { _ = FreeSpaceAnalyzer.maximalRects(in: zone, obstacles: obstacles) }
        let elapsed = start.duration(to: clock.now)
        print("SPATIAL PERF: 24 obstacles / 10 sweeps = \(elapsed)")
        XCTAssertLessThan(elapsed, .seconds(1), "Debug 构建也应远低于一次交互等待")
    }

    private func exhaustive(zone: CGRect, obstacles: [CGRect]) -> [CGRect] {
        let clipped = obstacles.map { $0.intersection(zone) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        let xs = Array(Set([zone.minX, zone.maxX] + clipped.flatMap { [$0.minX, $0.maxX] })).sorted()
        let ys = Array(Set([zone.minY, zone.maxY] + clipped.flatMap { [$0.minY, $0.maxY] })).sorted()
        var result: [CGRect] = []
        for a in 0..<(xs.count - 1) { for b in (a + 1)..<xs.count {
            for c in 0..<(ys.count - 1) { for d in (c + 1)..<ys.count {
                let rect = CGRect(x: xs[a], y: ys[c], width: xs[b] - xs[a], height: ys[d] - ys[c])
                if !clipped.contains(where: { $0.intersects(rect) }) { result.append(rect) }
            }}
        }}
        return FreeSpaceAnalyzer.pruneContained(result)
    }
}
@MainActor
final class SpaceUtilizationTests: XCTestCase {
    private let zone = CGRect(x: 0, y: 0, width: 1600, height: 900)
    private let planner = AdaptivePlacementPlanner()

    private func plan(_ current: PlayerMorphology, frame: CGRect, obstacles: [CGRect] = [],
                      morphing: Bool = true) -> AdaptivePlacementPlanner.Result {
        planner.evaluate(.init(safeZone: zone, obstacles: obstacles, currentFrame: frame, current: current),
                         permitsMorphing: morphing, promotionImprovement: 0.18, version: 1)
    }

    func testClearDesktopGrowsStandardCompactIntoUsefulCard() throws {
        let frame = CGRect(x: 400, y: 300, width: 420, height: 80)
        let result = plan(.compact, frame: frame)
        let best = try XCTUnwrap(result.solution.best)
        XCTAssertEqual(best.morphology, .compact)
        XCTAssertEqual(best.frame.size, CGSize(width: 640, height: 240))
        XCTAssertTrue(result.improvesUseOfSpace)
    }

    func testTallNarrowSpaceUsesCompactInsteadOfThinEdge() throws {
        let obstacles = [CGRect(x: 380, y: 0, width: 1220, height: 900)]
        let result = plan(.edge, frame: CGRect(x: 40, y: 300, width: 300, height: 34), obstacles: obstacles)
        let best = try XCTUnwrap(result.solution.best)
        XCTAssertEqual(best.morphology, .compact)
        XCTAssertGreaterThan(best.frame.height, 150)
        XCTAssertLessThanOrEqual(best.frame.maxX, 380)
        XCTAssertFalse(obstacles.contains { $0.intersects(best.frame) })
    }

    func testPortraitGapTooNarrowForCompactUsesLyricBoard() throws {
        let obstacles = [CGRect(x: 330, y: 0, width: 1270, height: 900)]
        let result = plan(.capsule, frame: CGRect(x: 10, y: 300, width: 300, height: 56), obstacles: obstacles)
        let best = try XCTUnwrap(result.solution.best)
        XCTAssertEqual(best.morphology, .capsule)
        XCTAssertGreaterThanOrEqual(best.frame.height, 152)
        XCTAssertTrue(result.improvesUseOfSpace)
        XCTAssertEqual(CapsuleSpacePresentation.shape(preferred: .capsule, height: best.frame.height), .board)
    }

    func testCapsulePresentationUsesHeightWithoutChangingPreference() {
        XCTAssertEqual(CapsuleSpacePresentation.shape(preferred: .capsule, height: 56), .capsule)
        XCTAssertEqual(CapsuleSpacePresentation.shape(preferred: .capsule, height: 76), .doubleLine)
        XCTAssertEqual(CapsuleSpacePresentation.shape(preferred: .capsule, height: 200), .board)
    }

    func testHorizontalGapUsesWideCapsule() throws {
        let obstacles = [CGRect(x: 0, y: 0, width: 1600, height: 400),
                         CGRect(x: 0, y: 470, width: 1600, height: 430)]
        let result = plan(.dormant, frame: CGRect(x: 10, y: 400, width: 26, height: 72), obstacles: obstacles)
        let best = try XCTUnwrap(result.solution.best)
        XCTAssertEqual(best.morphology, .capsule)
        XCTAssertGreaterThan(best.frame.width, 500)
        XCTAssertFalse(obstacles.contains { $0.intersects(best.frame) })
    }

    func testLegalButCrampedPlayerMovesToLargeBlankRegion() throws {
        // 左下只有 120pt 高横带；右边整块桌面空白。
        let obstacles = [CGRect(x: 0, y: 120, width: 800, height: 780)]
        let frame = CGRect(x: 100, y: 20, width: 420, height: 80)
        let result = plan(.compact, frame: frame, obstacles: obstacles)
        let best = try XCTUnwrap(result.solution.best)
        XCTAssertGreaterThan(best.frame.minX, 800)
        // 断言"在空地上长高"，而不是写死 240：
        // 具体长到多少是设计常量，改设计不该让这条测试变红。
        XCTAssertGreaterThan(best.frame.height, frame.height,
                             "有空地时应当长高，而不是保持被压扁的高度")
        XCTAssertTrue(result.improvesUseOfSpace, "合法不等于已经充分利用空位")
    }

    func testConvergesWithoutFurtherGrowthOrHopping() throws {
        let first = try XCTUnwrap(plan(.compact, frame: CGRect(x: 400, y: 300, width: 420, height: 80)).solution.best)
        var frame = first.frame
        for _ in 0..<20 {
            let result = plan(first.morphology, frame: frame)
            let best = try XCTUnwrap(result.solution.best)
            XCTAssertEqual(best.frame, frame)
            XCTAssertFalse(result.improvesUseOfSpace)
            frame = best.frame
        }
    }

    func testLockedFormDoesNotGrowUnprompted() throws {
        let frame = CGRect(x: 400, y: 300, width: 420, height: 80)
        let result = plan(.compact, frame: frame, morphing: false)
        XCTAssertEqual(result.solution.best?.frame, frame)
        XCTAssertFalse(result.improvesUseOfSpace)
    }

    func testGrowingCardShrinksWhenSpaceTightens() throws {
        let obstacles = [CGRect(x: 0, y: 0, width: 1600, height: 400),
                         CGRect(x: 0, y: 520, width: 1600, height: 380)]
        let result = plan(.compact, frame: CGRect(x: 400, y: 300, width: 640, height: 240), obstacles: obstacles)
        let best = try XCTUnwrap(result.solution.best)
        XCTAssertLessThan(best.frame.height, 120)
        XCTAssertFalse(obstacles.contains { $0.intersects(best.frame) })
    }

    func testOpportunityRequiresStableTarget() throws {
        var gate = SpatialOpportunityGate()
        let now = ContinuousClock().now
        let frame = CGRect(x: 400, y: 300, width: 640, height: 240)
        let deadline = try XCTUnwrap(gate.observe(frame, now: now))
        XCTAssertEqual(deadline, now.advanced(by: .milliseconds(500)))
        XCTAssertEqual(gate.observe(frame.offsetBy(dx: 2, dy: 0), now: now.advanced(by: .milliseconds(300))), deadline)
        let changed = gate.observe(frame.offsetBy(dx: 100, dy: 0), now: now.advanced(by: .milliseconds(350)))
        XCTAssertEqual(changed, now.advanced(by: .milliseconds(850)))
        XCTAssertNil(gate.observe(nil, now: now))
    }

    func testContentUsesVerticalRoomInsteadOfStretchingBlankShell() {
        let bar = CompactSpacePresentation(size: CGSize(width: 420, height: 80))
        XCTAssertFalse(bar.showsNext)
        let double = CompactSpacePresentation(size: CGSize(width: 420, height: 112))
        XCTAssertTrue(double.showsNext)
        XCTAssertFalse(double.showsContext)
        let card = CompactSpacePresentation(size: CGSize(width: 360, height: 240))
        XCTAssertTrue(card.showsContext)
        XCTAssertTrue(card.showsPrevious)
        // 封面尺寸是版式关系，不是某个具体数字：
        // 必须放得下、不能超过卡片高度，也不该小到看不见。
        XCTAssertGreaterThanOrEqual(card.artworkSide, 40)
        XCTAssertLessThanOrEqual(card.artworkSide, 240 * 0.6, "封面不应占据大半个卡片")
    }

    func testTallLyricBoardAccentFollowsTextInsteadOfStretchingIntoBlankSpace() throws {
        let model = MorphPresentationModel()
        let view = BoardLyricsView(model: model, onExpand: {})
            .frame(width: 318, height: 200)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var accentRows = 0
        for y in 0..<bitmap.pixelsHigh {
            let color = try XCTUnwrap(bitmap.colorAt(x: 17, y: y)?.usingColorSpace(.deviceRGB))
            if color.redComponent > 0.65 && color.greenComponent > 0.65 && color.blueComponent > 0.65 {
                accentRows += 1
            }
        }
        XCTAssertGreaterThan(accentRows, 8, "当前行保留可见强调标记")
        XCTAssertLessThan(accentRows, 50, "单行歌词的强调线不应占满 200pt 高的窗口")
        // 默认不落图；需要复核时显式给临时输出目录，不截图个人桌面。
        if let directory = ProcessInfo.processInfo.environment["SLP_TEST_RENDER_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // 用 `if let` 而不是 `XCTUnwrap`：后者在这里推不出泛型参数（合并后出现的编译问题），
            // 而这条分支本来就只是"可选落图"，失败不影响契约。
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: url.appendingPathComponent("narrow-gap-board-render.png"))
            }
        }
    }

    func testTinyGeometryChangesKeepSettledCard() throws {
        let obstacle = CGRect(x: 0, y: 0, width: 600, height: 900)
        let first = try XCTUnwrap(plan(.compact, frame: CGRect(x: 800, y: 300, width: 640, height: 240), obstacles: [obstacle]).solution.best)
        let result = plan(.compact, frame: first.frame, obstacles: [obstacle.offsetBy(dx: 2, dy: 0)])
        XCTAssertEqual(result.solution.best?.frame, first.frame)
        XCTAssertFalse(result.improvesUseOfSpace)
    }
}
