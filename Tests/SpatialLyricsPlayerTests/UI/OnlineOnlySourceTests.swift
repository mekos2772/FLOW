import XCTest
@testable import SpatialLyricsPlayer

/// "音源只有 B 站"这条产品决定的守卫。
///
/// 删掉一个源很容易在几个月后被"顺手加回来"，所以把结论写成测试。
@MainActor
final class OnlineOnlySourceTests: XCTestCase {

    func testAppContainerHasNoLocalSource() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        XCTAssertNil(container.sourceRegistry.provider(for: .localFile),
                     "本地文件源必须已经下线")
    }

    func testFallbackContainerHasNoLocalSource() {
        let container = ContainerBuilder.makeFallback()
        XCTAssertNil(container.sourceRegistry.provider(for: .localFile))
    }

    func testCleanContainerStartsWithoutPreloadedCatalogUntilConfigured() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        XCTAssertFalse(container.sourceManager.hasAnyConfiguredSource,
                       "洁净启动默认不预装任何商业曲库或未经用户添加的本地目录")
    }
}
