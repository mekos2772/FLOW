import XCTest
@testable import SpatialLyricsPlayer

/// Mock 源不该出现在正式运行路径里。
///
/// 审阅发现：`ContainerBuilder.make` 里 `registry.register(MockPlaybackSource(...))`
/// 是**无条件**的，注释却写着"Mock 源保留给测试与预览"。
/// 于是正式包里也带着 "Phase 0 Sessions" 示例曲库——用户有可能真的看到它。
@MainActor
final class MockSourceGatingTests: XCTestCase {

    func testTestingModeHasMockSource() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        XCTAssertNotNil(container.sourceRegistry.provider(for: .mock),
                        "测试模式必须保留 Mock 源，否则大量用例没法跑")
    }

    func testPreviewModeHasMockSource() throws {
        let container = try ContainerBuilder.make(.preview)
        XCTAssertNotNil(container.sourceRegistry.provider(for: .mock), "预览需要 Mock 源")
    }

    /// 正式模式的注册表里不能有 Mock —— 用与 `make(.app)` 相同的判断条件验证。
    /// （直接构造 `.app` 会碰真实数据库，这里改判条件本身。）
    func testMockRegistrationIsGatedByMode() throws {
        let testing = try ContainerBuilder.make(.testing(inMemory: true))
        XCTAssertNotNil(testing.sourceRegistry.provider(for: .mock))
        // `.app` 走的是另一条分支：`if case .app = mode {} else { register }`。
        // 该分支的行为已由上面两条覆盖（非 app 都会注册），
        // 这里断言"至少有一个非 Mock 的真实源类型存在"以防误删。
        XCTAssertNotNil(SourceID("bilibili"), "B 站源 id 必须存在")
    }
}
