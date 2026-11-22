import XCTest
@testable import SpatialLyricsPlayer

/// 小组件重载节流。
///
/// 起因：`WidgetBridge` 原来把秒级进度也算进重载签名，**播放时每秒调一次**
/// `WidgetCenter.reloadAllTimelines()`——正是 Apple 明确说会被限流的用法。
/// 限流之后小组件会停止更新，用户看到的就是"卡住了"。
final class WidgetReloadThrottleTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testFirstCallAlwaysReloads() {
        var throttle = WidgetReloadThrottle()
        XCTAssertTrue(throttle.shouldReload(identity: "a", now: t0))
    }

    func testSameIdentityWithinIntervalIsThrottled() {
        var throttle = WidgetReloadThrottle(minimumInterval: 30)
        _ = throttle.shouldReload(identity: "a", now: t0)
        XCTAssertFalse(throttle.shouldReload(identity: "a", now: t0.addingTimeInterval(1)))
        XCTAssertFalse(throttle.shouldReload(identity: "a", now: t0.addingTimeInterval(29)))
    }

    func testSameIdentityAfterIntervalReloads() {
        var throttle = WidgetReloadThrottle(minimumInterval: 30)
        _ = throttle.shouldReload(identity: "a", now: t0)
        XCTAssertTrue(throttle.shouldReload(identity: "a", now: t0.addingTimeInterval(30)))
    }

    /// 换歌必须立刻反映，不能等 30 秒。
    func testIdentityChangeReloadsImmediately() {
        var throttle = WidgetReloadThrottle(minimumInterval: 30)
        _ = throttle.shouldReload(identity: "A|playing|1", now: t0)
        XCTAssertTrue(throttle.shouldReload(identity: "B|playing|1", now: t0.addingTimeInterval(0.2)))
        XCTAssertTrue(throttle.shouldReload(identity: "B|paused|1", now: t0.addingTimeInterval(0.4)))
    }

    func testForceBypassesThrottle() {
        var throttle = WidgetReloadThrottle(minimumInterval: 30)
        _ = throttle.shouldReload(identity: "a", now: t0)
        XCTAssertTrue(throttle.shouldReload(identity: "a", now: t0.addingTimeInterval(1), force: true))
    }

    /// 播放 60 秒：重载次数应当远小于 60（每秒一次就是 bug）。
    func testPlaybackSecondBySecondStaysUnderBudget() {
        var throttle = WidgetReloadThrottle(minimumInterval: 30)
        var reloads = 0
        for second in 0..<60 {
            if throttle.shouldReload(identity: "song|playing|1",
                                     now: t0.addingTimeInterval(Double(second))) {
                reloads += 1
            }
        }
        XCTAssertLessThanOrEqual(reloads, 3, "60 秒播放最多重载 3 次；实际 \(reloads) 次")
        XCTAssertGreaterThanOrEqual(reloads, 1)
    }
}
