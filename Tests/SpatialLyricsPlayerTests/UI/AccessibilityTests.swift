import AppKit
import XCTest
@testable import SpatialLyricsPlayer

// 无障碍：AX 契约与节流。

/// 悬浮窗无障碍契约：交互态可被 VoiceOver 读到，穿透态不应产生无法操作的焦点。
@MainActor
final class AccessibilityTests: XCTestCase {

    private func makeController() throws -> MorphWindowController {
        try MorphTestSupport.make().controller
    }

    func testFloatingPanelIsAContainerNotAStaticText() throws {
        // 形态窗口里有播放键、展开热区等真实控件，因此它必须是容器元素，
        // 不能再像旧版悬浮歌词那样整体伪装成一个静态文本——那会让控件在 VoiceOver 里消失。
        let controller = try makeController()
        controller.setMorphology(.capsule)
        let panel = controller.debugPanel
        XCTAssertFalse(panel.isAccessibilityElement())
        XCTAssertEqual(panel.accessibilityLabel(), "FLOW 播放器")
    }

    func testPanelIsHiddenFromVoiceOverWhenClickThrough() throws {
        let controller = try makeController()
        controller.setMorphology(.capsule)
        let panel = controller.debugPanel

        XCTAssertFalse(panel.ignoresMouseEvents, "悬浮形态默认可点，才能点开完整播放器")
        XCTAssertFalse(panel.isAccessibilityHidden())

        controller.toggleInteractive()
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.isAccessibilityHidden(), "穿透态不得暴露不可操作的焦点")
    }

    func testAccessibilityHelpFollowsMorphology() throws {
        let controller = try makeController()
        controller.setMorphology(.edge)
        XCTAssertEqual(controller.debugPanel.accessibilityHelp(), "贴边")
        controller.setMorphology(.compact)
        XCTAssertEqual(controller.debugPanel.accessibilityHelp(), "迷你")
    }
}
/// 权限查询必须节流。
///
/// `AXIsProcessTrusted()` 每次调用都会打一次 TCC IPC，而 `obstacles(for:)`
/// 每 2 秒就要问一次权限——实测每 2 秒一条 `TCCAccessRequest()`，日志被刷满。
@MainActor
final class AccessibilityThrottleTests: XCTestCase {

    func testRepeatedQueriesWithinIntervalHitTheSystemOnce() {
        var calls = 0
        let manager = AccessibilityManager(isTrusted: { calls += 1; return false })

        let t0 = ContinuousClock().now
        manager.refreshIfStale(now: t0)
        XCTAssertEqual(calls, 1, "首次必须真的问一次")

        for i in 1...50 {
            manager.refreshIfStale(now: t0.advanced(by: .milliseconds(50 * i)))
        }
        XCTAssertEqual(calls, 1, "2.5 秒内的 50 次查询都该命中缓存")
    }

    func testQueryHappensAgainAfterInterval() {
        var calls = 0
        let manager = AccessibilityManager(isTrusted: { calls += 1; return false })
        let t0 = ContinuousClock().now

        manager.refreshIfStale(now: t0)
        manager.refreshIfStale(now: t0.advanced(by: .seconds(11)))
        XCTAssertEqual(calls, 2, "过了节流间隔要重新问，否则授权后永远发现不了")
    }

    func testExplicitRefreshAlwaysQueries() {
        var calls = 0
        let manager = AccessibilityManager(isTrusted: { calls += 1; return true })
        let t0 = ContinuousClock().now

        manager.refreshIfStale(now: t0)
        manager.refresh()   // 设置页"请求授权"路径：必须立即反映真实状态
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(manager.permission, .granted)
    }
}
