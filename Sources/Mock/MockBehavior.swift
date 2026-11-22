import Foundation

/// Mock 源的可编排行为。不是"假数据开关"，而是**故障注入器**。
///
/// 默认值即为"正常可用"；测试通过改 `failurePlan` / `alwaysFailWith` 精确构造异常路径。
struct MockBehavior: Sendable, Equatable {
    var prepareLatency: Duration = .milliseconds(120)
    var searchLatency: Duration = .milliseconds(60)
    /// 第 N 次 `prepare()` 抛出的错误（N 从 1 开始）。
    var failurePlan: [Int: PlaybackError] = [:]
    /// 无视次数，永远失败。
    var alwaysFailWith: PlaybackError?
    var corpusSize: Int = 12
    var supportsSeek: Bool = true
    var supportsRate: Bool = true
    /// 每次 `makeSession` 是否新建 session（false 时用于测试 refresh 复用路径）。
    var reusesSession: Bool = false

    static let healthy = MockBehavior()

    static func failing(_ error: PlaybackError) -> MockBehavior {
        var behavior = MockBehavior()
        behavior.alwaysFailWith = error
        return behavior
    }

    static func failOnAttempts(_ attempts: [Int], with error: PlaybackError) -> MockBehavior {
        var behavior = MockBehavior()
        behavior.failurePlan = Dictionary(uniqueKeysWithValues: attempts.map { ($0, error) })
        return behavior
    }
}
