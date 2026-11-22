import Foundation
@testable import SpatialLyricsPlayer

/// 可控时钟：`now` 只在 `sleep` 或显式 `advance` 时前移，不等真实墙钟。
///
/// 用途：让位置锚点、去抖窗口、重试退避等依赖时间的逻辑在测试里确定地推进。
/// 不加锁：测试内单线程使用，加锁反而在 async 上下文里被 Swift 6 拒绝。
final class TestPlaybackClock: PlaybackClock, @unchecked Sendable {

    private var current: Instant
    private(set) var totalSlept: Duration = .zero

    init(now: Instant = .now) {
        self.current = now
    }

    var now: Instant { current }

    func sleep(for duration: Duration) async throws {
        current = current.advanced(by: duration)  // 立即跳过这段时间
        totalSlept = totalSlept + duration
    }

    func advance(by duration: Duration) {
        current = current.advanced(by: duration)
    }
}
