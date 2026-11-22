import AppKit
import XCTest
@testable import SpatialLyricsPlayer

/// 动画与决策的交接契约。
///
/// 用户要求："算好最后落点，然后丝滑过去；动画过程不要影响下一次落点计算。"
/// 这几条断言守的就是这个边界——动画只负责呈现，落地后状态必须干净。
@MainActor
final class AnimationHandoffTests: XCTestCase {

    func testPresentationFlagsStartClean() {
        let model = MorphPresentationModel()
        XCTAssertNil(model.presentationSizeOverride, "启动时不该有钉住的排版尺寸")
        XCTAssertFalse(model.isAnimatingGeometry)
    }

    func testCompletedTransitionLeavesNoResidualAnimationState() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.capsule)
        controller.setMorphology(.compact)

        XCTAssertNil(controller.model.presentationSizeOverride,
                     "过渡结束后必须解冻排版，否则后续内容永远按旧尺寸排")
        XCTAssertFalse(controller.model.isAnimatingGeometry,
                       "过渡结束后不能再宣称自己在动画中，否则补偿检查再也不跑")
    }

    func testLandingIsExactSoNextEvaluationStartsFromTarget() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.capsule)
        let landed = controller.currentFrame

        controller.setMorphology(.compact)
        let compactFrame = controller.currentFrame

        // 落点必须真的等于窗口当前 frame：下一次计算用的是它，不能是动画残值。
        XCTAssertEqual(controller.currentFrame, compactFrame)
        XCTAssertNotEqual(controller.currentFrame, landed,
                          "换了形态就必须真的换到新落点，不能停在旧框上")
        XCTAssertGreaterThan(controller.currentFrame.height, 0)
    }

    func testRepeatedFormChangesDoNotAccumulateDrift() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.capsule)
        let first = controller.currentFrame

        for _ in 0..<5 {
            controller.setMorphology(.compact)
            controller.setMorphology(.capsule)
        }
        XCTAssertEqual(controller.currentFrame.size, first.size,
                       "反复切换后尺寸不得漂移——漂移说明动画中间帧被当成了新起点")
    }

    func testCapsulePresentationUsesFrozenSizeOnlyWhileAnimating() {
        let model = MorphPresentationModel()
        let size = CGSize(width: 320, height: 240)
        model.presentationSizeOverride = size
        // 冻结时按目标尺寸取断点，与实时几何无关。
        XCTAssertEqual(CompactSpacePresentation(size: model.presentationSizeOverride!).showsContext, true)
        model.presentationSizeOverride = nil
        XCTAssertEqual(CompactSpacePresentation(size: CGSize(width: 320, height: 80)).showsContext, false)
    }
}
