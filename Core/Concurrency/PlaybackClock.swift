import Foundation

/// 统一时间源。生产用系统时钟，测试用可手动推进的假时钟。
typealias Instant = ContinuousClock.Instant

protocol PlaybackClock: Sendable {
    var now: Instant { get }
    func sleep(for duration: Duration) async throws
}

extension Duration {
    /// `Duration` 没有实例级 `seconds` 属性（只有静态工厂），这里补一个到秒的换算。
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

struct SystemPlaybackClock: PlaybackClock {
    var now: Instant { ContinuousClock().now }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
