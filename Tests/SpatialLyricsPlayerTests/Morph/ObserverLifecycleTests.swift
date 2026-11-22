import XCTest
@testable import SpatialLyricsPlayer

/// 通知观察者必须能被清理。
///
/// `MorphWindowController` 在生产里随 App 存活，但**测试会反复创建它**。
/// 观察者数组本来就是为清理准备的，可一直没有清理路径——
/// 每个实例都会留下 6 个僵尸观察者（都持有 `[weak self]`，不崩但会累积）。
@MainActor
final class ObserverLifecycleTests: XCTestCase {

    func testShutdownRemovesAllObservers() throws {
        let support = try MorphTestSupport.make()
        let controller = support.controller
        // `start()` 才会注册通知观察者；测试里显式启动，再验证能清干净。
        controller.start()
        XCTAssertGreaterThan(controller.observerCountForTesting, 0, "start 之后应当已经注册了观察者")

        controller.shutdown()
        XCTAssertEqual(controller.observerCountForTesting, 0, "shutdown 之后不能再留下观察者")
    }

    /// 刷新循环也要停：否则退出后它还会再跑一拍去改 model。
    func testShutdownStopsTicker() throws {
        let support = try MorphTestSupport.make()
        let controller = support.controller
        controller.start()
        XCTAssertTrue(controller.tickerIsRunningForTesting, "start 之后刷新循环应当在跑")

        controller.shutdown()
        XCTAssertFalse(controller.tickerIsRunningForTesting, "shutdown 后刷新循环必须停")
    }

    /// 重复调用要幂等（退出路径可能被走两次）。
    func testShutdownIsIdempotent() throws {
        let support = try MorphTestSupport.make()
        let controller = support.controller
        controller.shutdown()
        controller.shutdown()
        XCTAssertEqual(controller.observerCountForTesting, 0)
    }
}
