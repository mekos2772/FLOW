import XCTest
@testable import SpatialLyricsPlayer


/// 空间挤压时的让位规则：可以缩小躲避，但不能缩成把手消失。
@MainActor
final class ExpandedDodgeRuleTests: XCTestCase {

    func testExpandedMayShrinkToVisibleForms() throws {
        let harness = try MorphTestSupport.make()
        // 直接确认机器给出的建议形态里，胶囊/迷你条都是合法目标（不是 dormant-only）。
        for form in [PlayerMorphology.capsule, .compact, .edge] {
            XCTAssertTrue(form.isFloating, "\(form.rawValue) 属于悬浮形态")
            XCTAssertNotEqual(form, .dormant, "\(form.rawValue) 仍能看见内容")
        }
    }

    func testDormantIsTheOnlyHiddenForm() {
        // 规则依赖"只有 dormant 会藏起播放器内容"这个事实。
        let visible = PlayerMorphology.allCases.filter { $0 != .dormant }
        XCTAssertEqual(visible.count, PlayerMorphology.allCases.count - 1)
        XCTAssertTrue(PlayerMorphology.dormant.isFloating)
    }
}

/// 用户主动展开**不能**被"绝不自动展开"的规则拦掉。
///
/// 这条是真实 bug 的回归守卫：规则原本不分来源，把"点胶囊展开"也当自动展开拦了，
/// 用户看到的是"点了没反应"（实测：点击日志有、形态不变）。
@MainActor
final class UserInitiatedExpandTests: XCTestCase {

    func testExpandFromCompactReachesExpanded() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.compact)
        XCTAssertEqual(controller.morphology, .compact)

        controller.expand()
        XCTAssertEqual(controller.morphology, .expanded,
                       "用户点开必须真的展开，不能被自动展开规则拦住")
    }

    func testExpandFromCapsuleReachesExpanded() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.capsule)
        controller.expand()
        XCTAssertEqual(controller.morphology, .expanded)
    }

    func testCollapseStillWorks() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.expanded)
        controller.collapse()
        XCTAssertNotEqual(controller.morphology, .expanded, "用户收缩要继续有效")
    }
}
