import XCTest
@testable import SpatialLyricsPlayer

/// 动效必须**与刷新率无关**：同一段动画在任何屏幕上都是同样的物理时长，
/// 帧数则随刷新率水涨船高。这条规则决定了"帧太少"和"高刷屏被拖慢"两端。
final class MotionTimingTests: XCTestCase {
    private let timing = MotionTiming()

    private func seconds(_ duration: Duration) -> Double {
        MotionTiming.seconds(duration)
    }

    func testSixtyHertzReachesMinimumFrameCount() {
        // 0.18s 在 60Hz 只有 11 帧——这正是"帧太少"的来源。
        let resolved = timing.resolve(base: .milliseconds(180), refreshRate: 60)
        let seconds = seconds(resolved)
        XCTAssertEqual(seconds, 0.50, accuracy: 0.001, "60Hz 下应抬到 30 帧所需的 500ms")
        XCTAssertGreaterThanOrEqual(seconds * 60, Double(timing.minimumFrames))
    }

    func testEveryRefreshRateReachesMinimumPositions() {
        // 核心契约：任何刷新率都必须凑够 30 个离散位置。
        // 60Hz 需要 500ms；120Hz 需要 250ms；240Hz 的基准时长本身已够，保持 180ms。
        let expected: [(rate: Double, seconds: Double)] = [
            (60, 0.50), (120, 0.25), (144, 30.0 / 144.0), (240, 0.18),
        ]
        for entry in expected {
            let resolved = timing.resolve(base: .milliseconds(180), refreshRate: entry.rate)
            XCTAssertEqual(seconds(resolved), entry.seconds, accuracy: 0.002,
                           "\(entry.rate)Hz 的时长应按 30 个位置反推")
            XCTAssertGreaterThanOrEqual(seconds(resolved) * entry.rate,
                                        Double(timing.minimumFrames) - 0.001,
                                        "\(entry.rate)Hz 必须凑够 \(timing.minimumFrames) 个位置")
        }
    }

    func testHigherRefreshRateFinishesSooner() {
        // 位置数相同，刷新率越高完成得越快：这正是"高刷屏更丝滑"的来源。
        var previous = Double.infinity
        for rate in [60.0, 120.0, 144.0, 240.0] {
            let resolved = seconds(timing.resolve(base: .milliseconds(180), refreshRate: rate))
            XCTAssertLessThan(resolved, previous, "\(rate)Hz 应比更低刷新率更快完成")
            previous = resolved
        }
    }

    func testThrottledDisplayGetsMorePositionsNotFewer() {
        // 远程/录屏这类低帧率链路上，宁可拉长也要凑够位置，否则就是"帧太少"。
        let slow = seconds(timing.resolve(base: .milliseconds(180), refreshRate: 30))
        let normal = seconds(timing.resolve(base: .milliseconds(180), refreshRate: 60))
        XCTAssertGreaterThan(slow, normal, "30Hz 链路上应进一步拉长以补足位置")
    }

    func testUnknownRefreshRateFallsBackToSixty() {
        let unknown = timing.resolve(base: .milliseconds(180), refreshRate: 0)
        XCTAssertEqual(seconds(unknown), 0.50, accuracy: 0.001, "未知刷新率按 60Hz 估，宁可够帧")
    }

    func testZeroDurationStaysInstant() {
        // "减少动态效果"与测试态都靠零时长表达，绝不能被抬到下限。
        XCTAssertEqual(seconds(timing.resolve(base: .zero, refreshRate: 60)), 0, accuracy: 1e-9)
        XCTAssertEqual(seconds(timing.resolve(base: .zero, refreshRate: 240)), 0, accuracy: 1e-9)
    }

    func testBaseDurationScalesWithDistance() {
        let near = timing.baseDuration(distance: 0, diagonal: 2000)
        let far = timing.baseDuration(distance: 2000, diagonal: 2000)
        XCTAssertLessThan(seconds(near), seconds(far), "远距离多给一点时间，但仍在同一量级")
        XCTAssertGreaterThanOrEqual(seconds(near), 0.2)
        XCTAssertLessThanOrEqual(seconds(far), 0.4)
    }

    func testBaseDurationIsClampedWhenDistanceExceedsDiagonal() {
        let beyond = timing.baseDuration(distance: 9999, diagonal: 1000)
        XCTAssertLessThanOrEqual(seconds(beyond), 0.4, "超出对角线也不会无限变慢")
    }
}
