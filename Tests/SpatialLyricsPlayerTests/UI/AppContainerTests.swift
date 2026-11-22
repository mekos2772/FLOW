import XCTest
@testable import SpatialLyricsPlayer

@MainActor
final class AppContainerTests: XCTestCase {

    func testTestingContainerResolvesEveryDependency() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))

        // 测试容器只注册 Mock 源：音源只有 B 站，而 B 站源只在真实运行且联网时注册，
        // 测试路径不发起任何网络请求。
        XCTAssertEqual(container.sourceRegistry.descriptors.count, 1)
        XCTAssertEqual(container.sourceRegistry.descriptors.map(\.id), [.mock])
        // 联网开关的真实来源是 settings（`AppConfiguration` 已删除：
        // 它从来没被任何地方读过，留着只会让人误以为它在控制行为）。
        XCTAssertFalse(container.settings.enableNetwork, "测试容器默认不联网，单测不能意外发请求")
        XCTAssertTrue(container.persistence.isInMemory)
        XCTAssertEqual(container.playback.state, .idle)
    }

    func testProductionStoreAllowsNetworkByDefault() throws {
        let suite = "slp-network-default-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(UserDefaultsSettingsStore(defaults: defaults).enableNetwork,
                      "正式版首次打开默认允许联网；关掉后才不发请求")
        XCTAssertFalse(InMemorySettingsStore().enableNetwork, "测试替身默认不联网")
    }

    func testFallbackContainerIsUsable() {
        let container = ContainerBuilder.makeFallback()
        XCTAssertFalse(container.sourceRegistry.isEmpty)
        XCTAssertTrue(container.persistence.isInMemory)
    }

    func testChangingSourceRegistrationDoesNotTouchPlaybackLayer() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))

        // 追加第二个源，播放内核引用不变，仍只通过协议访问。
        container.sourceRegistry.register(ScriptedSourceProvider())
        XCTAssertEqual(container.sourceRegistry.descriptors.count, 2)
        XCTAssertEqual(container.playback.state, .idle)
    }

    func testSettingsDefaultsAreOffline() async throws {
        let settings = InMemorySettingsStore()
        XCTAssertFalse(settings.enableNetwork)
        await settings.setEnableNetwork(true)
        XCTAssertTrue(settings.enableNetwork)
    }
}
