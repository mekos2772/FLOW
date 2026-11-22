import CoreGraphics
import XCTest
@testable import SpatialLyricsPlayer

/// 阻尼弹簧的数学与配方契约。
///
/// 这套东西决定"手感"，所以断言必须能解释清楚每一条：
/// 谁该回弹、谁绝不能越过、几何怎么被安全区钳住。
final class SpringMotionTests: XCTestCase {

    // MARK: - 数学

    func testSpringStartsAtZeroAndEndsAtTarget() {
        for spec in [MotionCatalog.elastic, MotionCatalog.lightDamping, MotionCatalog.overdamped] {
            XCTAssertEqual(spec.progress(at: 0), 0, accuracy: 1e-6, "起步必须在原位")
            XCTAssertEqual(spec.progress(at: spec.settlingDuration * 2), 1, accuracy: 1e-3,
                           "足够久之后必须到位")
        }
    }

    func testUnderdampedSpringOvershoots() {
        XCTAssertGreaterThan(MotionCatalog.elastic.peakProgress, 1.0, "ζ=0.68 必须有过冲")
        XCTAssertGreaterThan(MotionCatalog.elastic.peakProgress, 1.02)
        XCTAssertLessThan(MotionCatalog.elastic.peakProgress, 1.10, "过冲别夸张到 10% 以上")
    }

    func testCriticalDampingNeverOvershoots() {
        let critical = MotionCatalog.critical
        XCTAssertEqual(critical.dampingRatio, 1.0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(critical.peakProgress, 1.0 + 1e-6)
    }

    func testOverdampedNeverOvershootsAndSettlesSooner() {
        XCTAssertLessThanOrEqual(MotionCatalog.overdamped.peakProgress, 1.0 + 1e-6,
                                 "过阻尼绝不允许越过目标")
        XCTAssertLessThan(MotionCatalog.overdamped.settlingDuration,
                          MotionCatalog.elastic.settlingDuration,
                          "躲避要比弹性切换更快停稳")
    }

    func testShorterResponseSettlesFaster() {
        let quick = SpringSpec(response: 0.22, dampingRatio: 0.86)
        let slow = SpringSpec(response: 0.40, dampingRatio: 0.86)
        XCTAssertLessThan(quick.settlingDuration, slow.settlingDuration)
    }

    // MARK: - 几何钳制（安全区是硬边界）

    func testElasticGeometryIsClampedEvenThoughSpringOvershoots() {
        let recipe = MotionCatalog.expand
        XCTAssertFalse(recipe.geometryMayOvershoot, "展开不允许过冲")
        // 全程几何进度不得超过 1，否则 1020 宽的窗口会压到邻居。
        var t = 0.0
        while t < recipe.duration {
            XCTAssertLessThanOrEqual(recipe.geometryProgress(at: t), 1.0 + 1e-9)
            t += 0.005
        }
    }

    func testCollapseMayOvershootGeometryBecauseShrinkingIsSafe() {
        let recipe = MotionCatalog.collapse
        XCTAssertTrue(recipe.geometryMayOvershoot, "变小方向越界是安全的")
        XCTAssertGreaterThan(recipe.geometry.progress(at: 0.12), 0.5)
    }

    func testContentLayerCarriesTheBounce() {
        let recipe = MotionCatalog.morph
        XCTAssertGreaterThan(recipe.contentOvershoot, 0, "回弹必须体现在内容层")
        var peak = 0.0
        var t = 0.0
        while t < recipe.duration {
            peak = max(peak, recipe.contentScale(at: t))
            t += 0.004
        }
        XCTAssertGreaterThan(peak, 1.0, "内容应真的弹一下")
        XCTAssertLessThan(peak, 1.20, "但不要弹到夸张")
    }

    func testContentStaysStillForPassiveMotions() {
        // 躲避与隐匿是"不该抢注意力"的动作：内容层不做任何缩放。
        XCTAssertEqual(MotionCatalog.dodge.contentOvershoot, 0)
        XCTAssertEqual(MotionCatalog.hide.contentOvershoot, 0)
        XCTAssertEqual(MotionCatalog.dodge.contentScale(at: 0.1), 1, accuracy: 1e-9)
    }

    func testClampKeepsFrameInsideSafetyZone() {
        let zone = CGRect(x: 0, y: 79, width: 1920, height: 971)
        // 模拟一次过冲：左移过头 + 底部越界。
        let overshot = CGRect(x: -40, y: 20, width: 392, height: 56)
        let clamped = WindowFrameAnimator.clamp(overshot, inside: zone)
        XCTAssertGreaterThanOrEqual(clamped.minX, zone.minX)
        XCTAssertGreaterThanOrEqual(clamped.minY, zone.minY)
        XCTAssertLessThanOrEqual(clamped.maxX, zone.maxX + 0.001)
        XCTAssertLessThanOrEqual(clamped.maxY, zone.maxY + 0.001)
    }

    // MARK: - 配方分派

    func testRecipePerTransitionMatchesDesign() {
        XCTAssertEqual(MotionCatalog.recipe(from: .capsule, to: .expanded), MotionCatalog.expand)
        XCTAssertEqual(MotionCatalog.recipe(from: .expanded, to: .capsule), MotionCatalog.collapse)
        XCTAssertEqual(MotionCatalog.recipe(from: .capsule, to: .compact), MotionCatalog.morph)
        XCTAssertEqual(MotionCatalog.recipe(from: .compact, to: .edge), MotionCatalog.morph)
        XCTAssertEqual(MotionCatalog.recipe(from: .edge, to: .dormant), MotionCatalog.hide)
        XCTAssertEqual(MotionCatalog.recipe(from: .dormant, to: .capsule), MotionCatalog.restore)
    }

    func testElasticUsedForMorphsAndLightDampingForMoves() {
        // 用户口径：形态切换用 C 弹性，移动用 B 轻阻尼。
        XCTAssertEqual(MotionCatalog.morph.geometry.dampingRatio, 0.68, accuracy: 0.001)
        XCTAssertEqual(MotionCatalog.move.geometry.dampingRatio, 0.86, accuracy: 0.001)
        XCTAssertEqual(MotionCatalog.dodge.geometry.dampingRatio, 1.30, accuracy: 0.001)
    }

    /// 新契约：时长按"看得见的运动"给，而不是按弹簧理论收敛时间。
    ///
    /// 弹簧的 5%→95% 区间只占 settle 的约 25%（实测 158ms / 0.65s），
    /// 按 settle 推时长会让可见运动短到"几乎没有动画"。
    func testDurationsAreLongEnoughToBeVisible() {
        for (name, recipe) in [("expand", MotionCatalog.expand),
                               ("collapse", MotionCatalog.collapse),
                               ("morph", MotionCatalog.morph),
                               ("move", MotionCatalog.move),
                               ("restore", MotionCatalog.restore)] {
            XCTAssertGreaterThanOrEqual(recipe.duration, 0.32,
                                        "\(name) 时长太短，用户会觉得没有动画")
            XCTAssertLessThanOrEqual(recipe.duration, 0.60, "\(name) 不该拖沓")
        }
    }

    /// 被动动作（躲避、隐匿）必须比主动切换更快，否则会抢注意力。
    func testPassiveMotionsAreFasterThanActiveOnes() {
        XCTAssertLessThan(MotionCatalog.dodge.duration, MotionCatalog.morph.duration)
        XCTAssertLessThan(MotionCatalog.hide.duration, MotionCatalog.move.duration)
        XCTAssertLessThanOrEqual(MotionCatalog.hide.duration, 0.24, "隐匿应尽快消失")
    }

    /// 几何曲线必须单调铺满时长：不允许过冲（过冲由内容层表达）。
    func testGeometryCurvesDoNotOvershoot() {
        for (name, recipe) in [("expand", MotionCatalog.expand),
                               ("collapse", MotionCatalog.collapse),
                               ("morph", MotionCatalog.morph),
                               ("move", MotionCatalog.move),
                               ("dodge", MotionCatalog.dodge)] {
            XCTAssertLessThanOrEqual(recipe.geometryCurve.y1, 1.0 + 1e-9,
                                     "\(name) 的几何曲线不得过冲（会压到别的窗口）")
            XCTAssertLessThanOrEqual(recipe.geometryCurve.y2, 1.0 + 1e-9)
        }
    }

    // MARK: - 插值

    func testInterpolationHitsBothEnds() {
        let from = CGRect(x: 10, y: 20, width: 100, height: 50)
        let to = CGRect(x: 400, y: 300, width: 300, height: 200)
        XCTAssertEqual(WindowFrameAnimator.interpolate(from, to, progress: 0), from)
        XCTAssertEqual(WindowFrameAnimator.interpolate(from, to, progress: 1), to)
    }

    func testInterpolationWithOvershootGoesPastTarget() {
        let from = CGRect(x: 0, y: 0, width: 100, height: 100)
        let to = CGRect(x: 100, y: 0, width: 100, height: 100)
        let overshot = WindowFrameAnimator.interpolate(from, to, progress: 1.05)
        XCTAssertGreaterThan(overshot.minX, to.minX, "进度 >1 时应该越过目标")
    }
}
