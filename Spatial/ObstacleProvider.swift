import AppKit
import CoreGraphics
import Foundation

/// 一次障碍物扫描的完整输入。全部是值类型，可以安全地送进后台。
struct ObstacleScanRequest: Sendable, Equatable {
    var excludingPID: pid_t
    var screenFrame: CGRect
    var primaryMaxY: CGFloat
    var minimumArea: CGFloat = 120 * 80
}

/// 刷新节奏的纯逻辑，便于脱离真实桌面测试。
///
/// 为什么需要它：`CGWindowListCopyWindowInfo` 中位 0.3ms 但实测峰值 53ms，
/// `NSWorkspace` 的壁纸接口峰值也有 7.6ms。这些调用一旦落在主线程，
/// 就会把一帧（16.7ms）整块吞掉——用户看到的是"卡片走两步停一下"。
struct ObstacleRefreshPolicy: Sendable {
    /// 两次真实扫描之间的最小间隔。低于它只复用缓存。
    var minimumInterval: Duration = .milliseconds(180)

    func shouldScan(now: ContinuousClock.Instant,
                    lastScan: ContinuousClock.Instant?,
                    isRefreshing: Bool) -> Bool {
        guard !isRefreshing else { return false }
        guard let lastScan else { return true }
        return now >= lastScan.advanced(by: minimumInterval)
    }

    func isStale(now: ContinuousClock.Instant, lastScan: ContinuousClock.Instant?) -> Bool {
        guard let lastScan else { return true }
        return now >= lastScan.advanced(by: minimumInterval)
    }
}

/// 障碍物快照的唯一持有者。
///
/// 两条硬规则：
/// 1. **主线程永不调用 WindowServer 枚举**——读取只返回缓存。
/// 2. 同一时刻最多一次扫描在飞，重复请求合并到那一次，避免拖动时堆积。
@MainActor
final class ObstacleProvider {
    private(set) var latest: [CGRect] = []
    private(set) var lastScan: ContinuousClock.Instant?
    /// 真实发出的扫描次数，供测试与调试面板核对"有没有白白多扫"。
    private(set) var scanCount = 0

    let policy: ObstacleRefreshPolicy
    private let scanner: @Sendable (ObstacleScanRequest) -> [CGRect]
    private let clock = ContinuousClock()
    private var refreshTask: Task<[CGRect], Never>?
    /// 最近一次扫描的代数。用来丢弃比当前快照更旧的结果。
    private var generation: UInt64 = 0

    init(policy: ObstacleRefreshPolicy = ObstacleRefreshPolicy(),
         scanner: (@Sendable (ObstacleScanRequest) -> [CGRect])? = nil) {
        self.policy = policy
        self.scanner = scanner ?? { request in
            VisibleWindowScanner.scanObstacles(excludingPID: request.excludingPID,
                                               screenFrame: request.screenFrame,
                                               primaryMaxY: request.primaryMaxY,
                                               minimumArea: request.minimumArea)
        }
    }

    var isRefreshing: Bool { refreshTask != nil }

    /// 同步读取。绝不触发扫描，因此绝不会阻塞主线程。
    func snapshot(in screenFrame: CGRect) -> [CGRect] {
        latest.filter { $0.intersects(screenFrame) }
    }

    /// 需要时后台扫描并等待结果；已在飞时直接复用那一次。
    func refresh(_ request: ObstacleScanRequest) async -> [CGRect] {
        if let inFlight = refreshTask { return await inFlight.value }
        guard policy.shouldScan(now: clock.now, lastScan: lastScan, isRefreshing: false) else {
            return snapshot(in: request.screenFrame)
        }
        return await launch(request).value
    }

    /// 主线程只读路径：需要时顺手排队一次后台刷新，不等待。
    @discardableResult
    func requestRefresh(_ request: ObstacleScanRequest) -> Bool {
        guard refreshTask == nil,
              policy.shouldScan(now: clock.now, lastScan: lastScan, isRefreshing: false) else { return false }
        _ = launch(request)
        return true
    }

    /// 新快照直接替换：空列表也是有效事实（最后一个窗口关掉了）。
    func adopt(_ rects: [CGRect]) {
        generation &+= 1
        latest = rects
        lastScan = clock.now
    }

    private func launch(_ request: ObstacleScanRequest) -> Task<[CGRect], Never> {
        generation &+= 1
        let ticket = generation
        scanCount += 1
        let scan = scanner
        let task = Task { [weak self] () -> [CGRect] in
            // 只有这一层离开主 actor；WindowServer 枚举与坐标换算都在后台完成。
            let rects = await Task.detached(priority: .userInitiated) {
                scan(request)
            }.value
            guard let self else { return rects }
            // 只接受最新一次扫描，旧结果不覆盖新快照。
            if ticket == self.generation {
                self.latest = rects
                self.lastScan = self.clock.now
            }
            self.refreshTask = nil
            return rects
        }
        refreshTask = task
        return task
    }
}
