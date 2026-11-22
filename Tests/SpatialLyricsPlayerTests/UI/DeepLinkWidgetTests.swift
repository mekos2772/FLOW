import XCTest
@testable import SpatialLyricsPlayer

/// 小组件与 App 的深链必须指向同一处。
///
/// 起因：`WidgetEntryView` 里既没有 `widgetURL` 也没挂 intent，
/// 于是"点小组件空白处打开主窗口"这句文档**没有实现**——用户点了不会有任何反应。
/// 同时 `OpenPlayerIntent.perform()` 什么也不做，是纯粹的摆设（已删）。
@MainActor
final class DeepLinkWidgetTests: XCTestCase {

    func testOpenURLIsBuiltFromSharedScheme() throws {
        let url = try XCTUnwrap(DeepLinkScheme.openPlayer)
        XCTAssertEqual(url.scheme, DeepLinkScheme.value)
        XCTAssertEqual(url.host, "open")
    }

    /// 小组件用的 URL 必须被 App 的深链路由识别为"打开播放器"。
    func testWidgetURLIsHandledByRouter() throws {
        let url = try XCTUnwrap(DeepLinkScheme.openPlayer)
        XCTAssertEqual(DeepLinkRouter.action(for: url), .openPlayer)
    }

    /// App 内向外部暴露的入口与 Shared 常量一致（防两处各写一遍）。
    func testRouterAndSharedConstantAgree() {
        XCTAssertEqual(DeepLinkRouter.openPlayerURL, DeepLinkScheme.openPlayer)
        XCTAssertEqual(DeepLinkRouter.scheme, DeepLinkScheme.value)
    }
}
