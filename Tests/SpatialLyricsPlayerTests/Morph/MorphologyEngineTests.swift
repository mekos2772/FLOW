import XCTest
@testable import SpatialLyricsPlayer

/// 形态决策引擎与几何解析的纯逻辑测试。
///
/// 覆盖规格 23「空间」一节要求的情形：单窗口遮挡、多窗口遮挡、小范围/大范围、
/// 形态适配、无法放置、当前位置仍然合适时不乱动。
final class MorphologyEngineTests: XCTestCase {

    private let zone = CGRect(x: 0, y: 0, width: 1440, height: 875)

    private func evaluate(current: PlayerMorphology, obstacles: [CGRect]) -> MorphologyEvaluation {
        MorphologyEngine().evaluate(MorphologyEnvironment(
            safeZone: zone, obstacles: obstacles, currentFrame: nil, current: current
        ))
    }

    // MARK: - 形态适配

    func testEmptyDesktopPromotesOneStepOnly() {
        let result = evaluate(current: .capsule, obstacles: [])
        // 空桌面下胶囊可以放宽到迷你，但一次只放宽一档，且引擎不推荐完整播放器。
        XCTAssertEqual(result.recommendation.morphology, .compact)
    }

    func testNeverRecommendsExpanded() {
        for current in [PlayerMorphology.compact, .capsule, .edge] {
            let result = evaluate(current: current, obstacles: [])
            XCTAssertNotEqual(result.recommendation.morphology, .expanded,
                              "完整播放器只能由用户意图进入")
        }
    }

    func testSingleWindowOcclusionKeepsCompact() {
        // 浏览器占左半边，右侧仍有一条 640 宽的空白：迷你放得下，保持迷你。
        let obstacle = CGRect(x: 0, y: 0, width: 800, height: 875)
        let result = evaluate(current: .compact, obstacles: [obstacle])
        XCTAssertEqual(result.recommendation.morphology, .compact)
        XCTAssertTrue(result.recommendation.fitsPreferred)
    }

    func testNarrowStripDowngradesCapsuleToEdge() {
        // 只剩 200 宽：迷你(320)与胶囊(240)都放不下，贴边(168)可以。
        let obstacle = CGRect(x: 0, y: 0, width: 1240, height: 875)
        let result = evaluate(current: .capsule, obstacles: [obstacle])
        XCTAssertEqual(result.recommendation.morphology, .edge)
    }

    func testTightStripDowngradesCapsule() {
        // 剩 300 宽：迷你最小 320 放不下，胶囊最小 240 放得下。
        let obstacle = CGRect(x: 0, y: 0, width: 1140, height: 875)
        let result = evaluate(current: .compact, obstacles: [obstacle])
        XCTAssertEqual(result.recommendation.morphology, .capsule)
    }

    func testFullScreenOcclusionGoesDormant() {
        let obstacle = CGRect(x: -20, y: -20, width: 1480, height: 915)
        let result = evaluate(current: .capsule, obstacles: [obstacle])
        XCTAssertEqual(result.recommendation.morphology, .dormant)
    }

    func testMultipleWindowsOcclusion() {
        // 两个窗口把桌面对半切开，只留中间一条 220 宽的竖缝 → 贴边。
        let left = CGRect(x: 0, y: 0, width: 600, height: 875)
        let right = CGRect(x: 820, y: 0, width: 620, height: 875)
        let result = evaluate(current: .capsule, obstacles: [left, right])
        XCTAssertEqual(result.recommendation.morphology, .edge)
    }

    func testCurrentStillComfortableStaysPut() {
        // 极小遮挡不该引起任何形态变化。
        let obstacle = CGRect(x: 1400, y: 800, width: 40, height: 75)
        let result = evaluate(current: .compact, obstacles: [obstacle])
        XCTAssertEqual(result.recommendation.morphology, .compact)
        XCTAssertTrue(result.recommendation.currentStillFits)
        XCTAssertTrue(result.note.contains("保持不动"))
    }

    // MARK: - 几何解析

    private func resolver() -> WindowGeometryResolver { WindowGeometryResolver() }

    func testExpandedExpandsFromTopLeftAnchor() {
        let capsule = CGRect(x: 200, y: 700, width: 392, height: 56)
        let target = resolver().resolve(.expanded, currentFrame: capsule, in: zone)
        XCTAssertEqual(target.frame.minX, capsule.minX, accuracy: 1, "展开时左边不动")
        XCTAssertEqual(target.frame.maxY, capsule.maxY, accuracy: 1, "展开时顶边不动")
        XCTAssertTrue(target.didPreserveAnchor)
        XCTAssertTrue(zone.contains(target.frame))
    }

    func testExpandedShrinksIntoSmallZone() {
        let tiny = CGRect(x: 0, y: 0, width: 900, height: 560)
        let target = resolver().resolve(.expanded, currentFrame: CGRect(x: 10, y: 10, width: 400, height: 60), in: tiny)
        XCTAssertLessThanOrEqual(target.frame.width, 900)
        XCTAssertLessThanOrEqual(target.frame.height, 560)
        XCTAssertTrue(tiny.insetBy(dx: -1, dy: -1).contains(target.frame))
    }

    func testCapsuleCollapseKeepsTopLeft() {
        let expanded = CGRect(x: 300, y: 200, width: 1020, height: 640)
        let target = resolver().resolve(.capsule, currentFrame: expanded, in: zone)

        XCTAssertEqual(target.frame.minX, expanded.minX, accuracy: 1)
        XCTAssertEqual(target.frame.maxY, expanded.maxY, accuracy: 1)
        XCTAssertEqual(target.frame.size, PlayerMorphology.capsule.geometry.preferredSize)
    }

    func testCapsuleMovesOutOfObstacle() {
        // 当前位置正好被前台窗口压住：必须换到同屏的空白处，而不是原地不动。
        let expanded = CGRect(x: 0, y: 400, width: 1020, height: 640)
        let obstacle = CGRect(x: -10, y: 300, width: 600, height: 575)
        let target = resolver().resolve(.capsule, currentFrame: expanded, in: zone, obstacles: [obstacle])

        XCTAssertFalse(obstacle.insetBy(dx: -2, dy: -2).intersects(target.frame))
    }

    func testEdgeSnapsToNearestEdge() {
        let rightSide = CGRect(x: 1000, y: 400, width: 392, height: 56)
        let target = resolver().resolve(.edge, currentFrame: rightSide, in: zone)
        XCTAssertEqual(target.edge, .right)
        XCTAssertEqual(target.frame.maxX, zone.maxX - 4, accuracy: 1, "贴右边时留 4pt 缝，不压住 Dock/滚动条")
        XCTAssertEqual(target.frame.height, PlayerMorphology.edge.geometry.preferredSize.height)
    }

    /// 隐匿把手是**贴边竖条**（参考产品形态：三点竖条），所以只贴左右边；
    /// 即使当前位置更靠近顶边，也要落到侧边——否则会变成一根横着的短棍。
    func testDormantHandleSnapsToSideEdgeEvenWhenNearTop() {
        let frame = CGRect(x: 100, y: 800, width: 392, height: 56)
        let target = resolver().resolve(.dormant, currentFrame: frame, in: zone)
        XCTAssertEqual(target.edge, .right, "竖条只贴左右边")
        XCTAssertEqual(target.frame.maxX, zone.maxX - 4, accuracy: 1, "贴右边缘留 4pt 缝")
        XCTAssertLessThan(target.frame.width, target.frame.height, "必须是竖条，不是方块")
        XCTAssertGreaterThan(target.frame.height, 40)
    }

    func testDormantHandleKeepsLeftEdge() {
        let frame = CGRect(x: 20, y: 400, width: 392, height: 56)
        let target = resolver().resolve(.dormant, currentFrame: frame, in: zone)
        XCTAssertEqual(target.edge, .left)
        XCTAssertEqual(target.frame.minX, zone.minX + 4, accuracy: 1)
    }

    func testNearestEdgePrefersHorizontalSidesOnTie() {
        // 正方形安全区的正中，四条边距离完全相同；此时必须确定性地选左右边。
        let square = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let centered = CGRect(x: 400, y: 472, width: 200, height: 56)
        let edge = resolver().nearestEdge(to: centered, in: square)
        XCTAssertEqual(edge, .left, "同距离时优先左右边，避免歌词条压在菜单栏下")
    }

    // MARK: - 过渡计划

    func testShortMoveUsesContinuousMorph() {
        let plan = MorphTransitionPlan.make(
            from: .compact, to: .capsule,
            fromFrame: CGRect(x: 100, y: 700, width: 420, height: 80),
            toFrame: CGRect(x: 110, y: 710, width: 392, height: 56),
            screenDiagonal: hypot(1440, 875),
            tuning: .default, reduceMotion: false
        )
        XCTAssertFalse(plan.relocatesThroughFade)
        XCTAssertEqual(plan.duration, MorphologyTuning.default.morphDuration)
    }

    func testLongMoveUsesFadeRelocation() {
        let plan = MorphTransitionPlan.make(
            from: .capsule, to: .edge,
            fromFrame: CGRect(x: 20, y: 800, width: 392, height: 56),
            toFrame: CGRect(x: 1300, y: 40, width: 300, height: 34),
            screenDiagonal: hypot(1440, 875),
            tuning: .default, reduceMotion: false
        )
        XCTAssertTrue(plan.relocatesThroughFade, "远距离重定位不允许窗口横穿工作区")
    }

    func testReduceMotionCollapsesDuration() {
        let plan = MorphTransitionPlan.make(
            from: .expanded, to: .capsule,
            fromFrame: CGRect(x: 0, y: 0, width: 1020, height: 640),
            toFrame: CGRect(x: 0, y: 600, width: 392, height: 56),
            screenDiagonal: hypot(1440, 875),
            tuning: .default, reduceMotion: true
        )
        XCTAssertEqual(plan.duration, .milliseconds(0))
        XCTAssertFalse(plan.relocatesThroughFade)
    }

    func testExpandDurationLongerThanCollapse() {
        let expand = MorphTransitionPlan.make(
            from: .capsule, to: .expanded,
            fromFrame: .zero, toFrame: .zero, screenDiagonal: 1000, tuning: .default, reduceMotion: false)
        let collapse = MorphTransitionPlan.make(
            from: .expanded, to: .capsule,
            fromFrame: .zero, toFrame: .zero, screenDiagonal: 1000, tuning: .default, reduceMotion: false)
        XCTAssertGreaterThan(expand.duration, collapse.duration, "展开要比收缩更有仪式感，但都不能拖沓")
    }
}

/// 障碍物过滤：桌面不是障碍物。
@MainActor
final class ObstacleFilterTests: XCTestCase {
    func testDesktopIsNotAnObstacle() {
        XCTAssertFalse(WindowGeometryReader.isObstacleCandidate(role: "AXScrollArea", subrole: "AXDesktop"))
        XCTAssertFalse(WindowGeometryReader.isObstacleCandidate(role: "AXWindow", subrole: "AXDesktop"))
    }

    func testStandardWindowIsAnObstacle() {
        XCTAssertTrue(WindowGeometryReader.isObstacleCandidate(role: "AXWindow", subrole: "AXStandardWindow"))
        XCTAssertTrue(WindowGeometryReader.isObstacleCandidate(role: "AXWindow", subrole: nil))
    }

    func testNonWindowRolesAreIgnored() {
        XCTAssertFalse(WindowGeometryReader.isObstacleCandidate(role: "AXScrollArea", subrole: nil))
        XCTAssertFalse(WindowGeometryReader.isObstacleCandidate(role: nil, subrole: nil))
    }
}

/// 避让的核心契约：**"放得下"不等于"位置没问题"**。
///
/// 之前引擎只看"这个形态能不能在空白区放下"，于是胶囊被浏览器压住时依旧报
/// `noBetterOption`（当前形态仍然放得下，保持不动），自动避让整个失效。
@MainActor
final class MorphologyRelocationTests: XCTestCase {

    private let zone = CGRect(x: 0, y: 0, width: 1600, height: 900)

    private func makeEngine() -> MorphologyEngine {
        MorphologyEngine(tuning: MorphologyTuning())
    }

    /// 胶囊位置被挡住 → 必须要求移动（currentStillFits 为 false）。
    func testOverlappedCurrentPositionAsksForRelocation() throws {
        let engine = makeEngine()
        // 左上角空着，右下角被一个窗口占住；胶囊当前正好在那个窗口上。
        let obstacle = CGRect(x: 900, y: 100, width: 600, height: 400)
        let capsule = PlayerMorphology.capsule.geometry.preferredSize
        let environment = MorphologyEnvironment(
            safeZone: zone,
            obstacles: [obstacle],
            currentFrame: CGRect(x: 950, y: 200, width: capsule.width, height: capsule.height),
            current: .capsule,
            currentOverlap: 0.95
        )
        let evaluation = engine.evaluate(environment)
        let recommendation = evaluation.recommendation
        XCTAssertFalse(recommendation.currentStillFits, "被压住就不能再报‘仍然放得下’")
        XCTAssertEqual(recommendation.morphology, .capsule, "空间够时优先保持形态、只移动位置")
        XCTAssertTrue(evaluation.note.contains("遮挡"), "note 要说明原因：\(evaluation.note)")
    }

    /// 没被挡住就一律不动（避免因为歌词变长之类的小事乱跳）。
    func testClearPositionDoesNotAskForRelocation() {
        let engine = makeEngine()
        let capsule = PlayerMorphology.capsule.geometry.preferredSize
        let environment = MorphologyEnvironment(
            safeZone: zone,
            obstacles: [CGRect(x: 900, y: 100, width: 600, height: 400)],
            currentFrame: CGRect(x: 40, y: 40, width: capsule.width, height: capsule.height),
            current: .capsule,
            currentOverlap: 0
        )
        XCTAssertTrue(engine.evaluate(environment).recommendation.currentStillFits)
    }

    /// 遮挡轻微（低于阈值）时不折腾。
    func testMinorOverlapBelowThresholdStays() {
        let engine = makeEngine()
        let capsule = PlayerMorphology.capsule.geometry.preferredSize
        let environment = MorphologyEnvironment(
            safeZone: zone,
            obstacles: [CGRect(x: 900, y: 100, width: 600, height: 400)],
            currentFrame: CGRect(x: 40, y: 40, width: capsule.width, height: capsule.height),
            current: .capsule,
            currentOverlap: MorphologyTuning().relocationOverlapThreshold - 0.05
        )
        XCTAssertTrue(engine.evaluate(environment).recommendation.currentStillFits)
    }
}

/// 遮挡面积必须按**并集**算，不能把重叠障碍物重复累加。
///
/// 实测症状：实际只压住 69%，两个重叠窗口加起来算成 138% → 钳到 100%，
/// 播放器以为一直没躲开，于是反复重定位（规格 6.8 明令要防的"重复横跳"）。
@MainActor
final class CoverageTests: XCTestCase {

    func testOverlappingObstaclesCountOnce() {
        let player = CGRect(x: 0, y: 0, width: 100, height: 100)
        let a = CGRect(x: 0, y: 0, width: 100, height: 40)
        let b = CGRect(x: 0, y: 0, width: 100, height: 40)   // 与 a 完全重合
        XCTAssertEqual(Coverage.fraction(of: player, by: [a, b]), 0.4, accuracy: 0.001)
    }

    func testPartiallyOverlappingObstaclesUnion() {
        let player = CGRect(x: 0, y: 0, width: 100, height: 100)
        let a = CGRect(x: 0, y: 0, width: 100, height: 40)
        let b = CGRect(x: 0, y: 30, width: 100, height: 40)  // 与 a 重叠 10
        // 并集高度 70
        XCTAssertEqual(Coverage.fraction(of: player, by: [a, b]), 0.7, accuracy: 0.001)
    }

    func testObstacleOutsideCountsNothing() {
        let player = CGRect(x: 0, y: 0, width: 100, height: 100)
        let far = CGRect(x: 500, y: 500, width: 100, height: 100)
        XCTAssertEqual(Coverage.fraction(of: player, by: [far]), 0, accuracy: 0.001)
    }

    func testFullCoverIsOne() {
        let player = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(Coverage.fraction(of: player, by: [CGRect(x: -50, y: -50, width: 300, height: 300)]), 1, accuracy: 0.001)
    }
}

/// 自动展开积极度（规格 规则 D：用户可以选择更积极的策略）。
@MainActor
final class AutoExpandPolicyTests: XCTestCase {

    private let zone = CGRect(x: 0, y: 0, width: 1600, height: 900)

    private func evaluation(policy: AutoExpandPolicy) -> MorphologyEvaluation {
        var tuning = MorphologyTuning()
        tuning.minimumPromotionImprovement = policy.promotionImprovement
        let engine = MorphologyEngine(tuning: tuning)
        // 当前是胶囊、位置干净；可用空间刚好比"放大一档"多一点余量。
        let capsule = PlayerMorphology.capsule.geometry.preferredSize
        return engine.evaluate(MorphologyEnvironment(
            safeZone: zone,
            obstacles: [],
            currentFrame: CGRect(x: 40, y: 40, width: capsule.width, height: capsule.height),
            current: .capsule,
            currentOverlap: 0
        ))
    }

    func testThresholdsAreOrdered() {
        XCTAssertLessThan(AutoExpandPolicy.eager.promotionImprovement,
                          AutoExpandPolicy.balanced.promotionImprovement)
        XCTAssertLessThan(AutoExpandPolicy.balanced.promotionImprovement,
                          AutoExpandPolicy.conservative.promotionImprovement)
    }

    /// 空间充裕时，积极策略最多一档一档往上升，绝不直接跳到完整播放器。
    func testEagerStillNeverJumpsToExpanded() {
        let result = evaluation(policy: .eager)
        XCTAssertNotEqual(result.recommendation.morphology, .expanded,
                          "自动策略永远不打开完整播放器")
        XCTAssertLessThanOrEqual(result.recommendation.morphology.tightness,
                                 PlayerMorphology.capsule.tightness - 0)
    }

    /// 保守策略在同样空间下不会比积极策略更宽松。
    func testConservativeIsNotLooserThanEager() {
        let conservative = evaluation(policy: .conservative).recommendation.morphology
        let eager = evaluation(policy: .eager).recommendation.morphology
        XCTAssertGreaterThanOrEqual(conservative.tightness, eager.tightness,
                                    "保守策略的形态应该同样紧或更紧")
    }
}


/// 用用户截图里的真实几何核对自由矩形求解：中间那条缝必须能算出来。
@MainActor
final class FreeSpaceGapTests: XCTestCase {
    func testFindsMiddleBandGapBetweenTwoWindows() {
        let zone = CGRect(x: 0, y: 79, width: 2048, height: 1043)
        // 两个全宽窗口（上下），中间留 452…562 的缝；中间还有一个别的应用窗口挡住中段。
        let obstacles = [
            CGRect(x: 0, y: 152, width: 2048, height: 300),   // 下窗口
            CGRect(x: 0, y: 562, width: 2048, height: 500),   // 上窗口
            CGRect(x: 401, y: 197, width: 1280, height: 820), // 中间的应用窗口
        ]
        let rects = FreeSpaceAnalyzer.maximalRects(in: zone, obstacles: obstacles)
        let band = rects.filter { $0.height >= 100 && $0.width >= 300 }
        XCTAssertFalse(band.isEmpty, "应能找到中间那条 ≥100pt 高的缝，实际：\(rects)")
        XCTAssertTrue(band.contains { $0.contains(CGRect(x: 4, y: 452, width: 392, height: 56)) },
                      "左侧 x 0…401 的那块必须存在")
    }
}
