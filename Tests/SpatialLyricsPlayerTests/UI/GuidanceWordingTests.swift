import XCTest
@testable import SpatialLyricsPlayer

/// 界面里的"去哪里做什么"指引必须**指向真实存在的入口**。
///
/// 之前收藏夹的空态写着「右上角地球 → 扫码登录」，而界面里根本没有地球图标——
/// 用户照着找会一脸茫然。真实入口是「设置 → 在线音乐 → 登录」。
final class GuidanceWordingTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: RepositoryRoot.locate().appendingPathComponent(relative),
                   encoding: .utf8)
    }

    func testHomeFavoritesDoNotRequireOnlineSignIn() throws {
        let text = try source("UI/Expanded/OnlineHomeView.swift")
        XCTAssertFalse(text.contains("右上角地球"))
        XCTAssertFalse(text.contains("收藏夹需要登录"), "首页收藏是本地收藏，不应要求在线账号")
        XCTAssertTrue(text.contains("home.loadFavorites(app: app)"))
    }

    /// 指引里出现「右上角」时，那个位置确实要有可点的东西（这里只挡已知的过时说法）。
    func testNoStaleTopRightReferences() throws {
        for file in ["UI/Expanded/OnlineHomeView.swift", "UI/Expanded/AuxiliaryDrawer.swift"] {
            let text = try source(file)
            XCTAssertFalse(text.contains("右上角地球"))
        }
    }
}
