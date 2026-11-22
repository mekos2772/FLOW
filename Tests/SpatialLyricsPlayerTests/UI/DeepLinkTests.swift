import XCTest
@testable import SpatialLyricsPlayer

// 深链：URL 形状解析与路由分发。

@MainActor
final class DeepLinkTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    func testKnownRoutes() {
        XCTAssertEqual(DeepLinkRouter.action(for: url("spatiallyrics://now")), .openPlayer)
        XCTAssertEqual(DeepLinkRouter.action(for: url("spatiallyrics://open")), .openPlayer)
        XCTAssertEqual(DeepLinkRouter.action(for: url("spatiallyrics://toggle-floating")), .toggleFloating)
    }

    func testBareSchemeOpensPlayer() {
        XCTAssertEqual(DeepLinkRouter.action(for: url("spatiallyrics://")), .openPlayer)
    }

    func testUnknownSchemeAndHostAreIgnored() {
        XCTAssertNil(DeepLinkRouter.action(for: url("https://example.com/now")))
        XCTAssertNil(DeepLinkRouter.action(for: url("spatiallyrics://delete-everything")))
    }

    func testHandleReturnsFalseForUnknownURL() {
        XCTAssertFalse(DeepLinkRouter.handle(url("https://example.com"), floating: nil))
    }

    func testToggleFloatingReachesController() throws {
        let controller = try MorphTestSupport.make().controller
        controller.setMorphology(.capsule)
        controller.show()
        let before = controller.isVisible

        XCTAssertTrue(DeepLinkRouter.handle(url("spatiallyrics://toggle-floating"), floating: controller))
        XCTAssertNotEqual(controller.isVisible, before, "深链必须真的切换了悬浮歌词")
    }
}
/// 深链：排布切换（`spatiallyrics://shape/...`）。
///
/// 加这条链路是为了让"双行/歌词板"这些排布可以被脚本触发——
/// 设置窗口里的 Picker 在 AX 里拿不到可点元素，自动化测试和截图都够不着它。
@MainActor
final class DeepLinkShapeTests: XCTestCase {

    func testParsesEveryShape() {
        for shape in LyricsShape.allCases {
            let url = URL(string: "spatiallyrics://shape/\(shape.rawValue)")!
            XCTAssertEqual(DeepLinkRouter.action(for: url), .setShape(shape),
                           "\(shape.rawValue) 应能解析")
        }
    }

    func testUnknownShapeIsRejected() {
        let url = URL(string: "spatiallyrics://shape/nonsense")!
        XCTAssertNil(DeepLinkRouter.action(for: url), "未知排布不得被猜成默认值")
    }

    func testShapeDeepLinkTakesEffect() async throws {
        let harness = try MorphTestSupport.make()
        let url = URL(string: "spatiallyrics://shape/doubleLine")!
        XCTAssertTrue(DeepLinkRouter.handle(url, floating: nil, morph: harness.controller))
        XCTAssertEqual(harness.controller.floatingShape, .doubleLine)
    }
}
