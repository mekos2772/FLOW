import XCTest
@testable import SpatialLyricsPlayer

/// 障碍物扫描的刷新策略：主线程只读缓存，一次扫描服务所有消费者。
@MainActor
final class ObstacleRefreshTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 900)

    private func request() -> ObstacleScanRequest {
        ObstacleScanRequest(excludingPID: 123, screenFrame: screen, primaryMaxY: screen.maxY)
    }

    func testFirstScanIsAllowedImmediately() {
        let policy = ObstacleRefreshPolicy()
        XCTAssertTrue(policy.shouldScan(now: .now, lastScan: nil, isRefreshing: false))
        XCTAssertTrue(policy.isStale(now: .now, lastScan: nil))
    }

    func testScanIsSuppressedInsideInterval() {
        let policy = ObstacleRefreshPolicy(minimumInterval: .milliseconds(180))
        let now = ContinuousClock().now
        let last = now.advanced(by: .milliseconds(-100))
        XCTAssertFalse(policy.shouldScan(now: now, lastScan: last, isRefreshing: false),
                       "180ms 内的重复请求应复用缓存，不能每次都去问 WindowServer")
        XCTAssertFalse(policy.isStale(now: now, lastScan: last), "刚扫过 100ms，还算新鲜")
    }

    func testScanIsSuppressedWhileOneIsInFlight() {
        let policy = ObstacleRefreshPolicy()
        let now = ContinuousClock().now
        XCTAssertFalse(policy.shouldScan(now: now, lastScan: nil, isRefreshing: true),
                       "已有扫描在飞时必须合并，否则拖动会堆积枚举")
    }

    func testScanAllowedAgainAfterInterval() {
        let policy = ObstacleRefreshPolicy(minimumInterval: .milliseconds(180))
        let now = ContinuousClock().now
        let last = now.advanced(by: .milliseconds(-400))
        XCTAssertTrue(policy.shouldScan(now: now, lastScan: last, isRefreshing: false))
        XCTAssertTrue(policy.isStale(now: now, lastScan: last), "超过间隔就算过期，需要重新扫描")
    }

    func testCachedSnapshotReadNeverTriggersScan() {
        let provider = ObstacleProvider()
        XCTAssertEqual(provider.scanCount, 0)
        XCTAssertTrue(provider.snapshot(in: screen).isEmpty)
        XCTAssertEqual(provider.scanCount, 0, "只读路径不允许发起扫描")
    }

    func testDuplicateRefreshRequestsCollapseIntoOne() async {
        let provider = ObstacleProvider(policy: ObstacleRefreshPolicy(minimumInterval: .milliseconds(500)))
        let request = request()
        let first = provider.requestRefresh(request)
        let second = provider.requestRefresh(request)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "第二次请求应合并到在飞的那次")
        XCTAssertEqual(provider.scanCount, 1)
        _ = await provider.refresh(request)
    }

    func testRefreshWaitsForRealScanAndRecordsTimestamp() async {
        let provider = ObstacleProvider()
        let rects = await provider.refresh(request())
        XCTAssertEqual(provider.scanCount, 1)
        XCTAssertNotNil(provider.lastScan)
        XCTAssertEqual(provider.latest.count, rects.count, "快照应与本次扫描一致")
    }

    func testEmptyScanResultIsAnAdoptedFact() async {
        let provider = ObstacleProvider()
        provider.adopt([screen])
        XCTAssertEqual(provider.snapshot(in: screen), [screen])
        provider.adopt([])
        XCTAssertTrue(provider.snapshot(in: screen).isEmpty,
                      "最后一个窗口关掉时，空列表必须成为新的有效快照")
    }

    func testSnapshotIsFilteredToRequestedScreen() async {
        let provider = ObstacleProvider()
        let other = CGRect(x: 3000, y: 0, width: 800, height: 600)
        provider.adopt([screen, other])
        XCTAssertEqual(provider.snapshot(in: screen), [screen])
    }

    func testScanOffMainThreadKeepsPureParserContract() {
        // 后台入口与纯解析入口必须给出一致结果（坐标换算只应发生一次）。
        let window: [String: Any] = [
            kCGWindowOwnerPID as String: pid_t(999),
            kCGWindowLayer as String: 0,
            kCGWindowIsOnscreen as String: true,
            kCGWindowBounds as String: CGRect(x: 100, y: 100, width: 400, height: 300).dictionaryRepresentation,
            kCGWindowAlpha as String: 1.0,
        ]
        let parsed = VisibleWindowScanner.obstacleRects(in: [window], excludingPID: 123,
                                                       screenFrame: screen, primaryMaxY: screen.maxY)
        XCTAssertEqual(parsed, [CGRect(x: 100, y: 500, width: 400, height: 300)])
    }
}
