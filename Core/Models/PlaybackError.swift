import Foundation

/// 音频容器格式。用于把"AVFoundation 不支持"这类错误细化到具体格式。
enum MediaFormat: String, Codable, Sendable, Equatable {
    case flac, ogg, opus, wma, other
}

/// 恢复建议。状态机据此决定重试或降级。
enum RecoveryHint: Equatable, Sendable {
    case retry(maxAttempts: Int, backoff: Duration)
    case advanceToNext
    case degradeToPlaceholder
    case manual
}

/// 播放错误。全工程唯一错误语汇，源的底层错误必须经 `map(_:)` 收敛到这里。
enum PlaybackError: Error, Equatable, Sendable {
    case sourceUnavailable
    case decodeFailed(reason: String)
    /// 用户在设置里关掉了联网。
    case networkDisabled
    /// 网络断了（没连上、超时、DNS 解析不了）。
    ///
    /// 和 `networkDisabled` 分开：那是用户的选择，这个是环境问题——
    /// 恢复方式完全不同（等网络回来自动续上 vs 去设置里打开）。
    /// 也不能并进 `sourceUnavailable`：断网时把队列里的歌一首首"跳过"毫无意义。
    case networkUnavailable
    case unsupportedFormat(MediaFormat)
    case cancelled
    case rightsRestricted
    case songNotVerified
    case unknown(reason: String)

    var hint: RecoveryHint {
        switch self {
        case .sourceUnavailable, .decodeFailed, .unknown:
            return .retry(maxAttempts: 2, backoff: .milliseconds(400))
        case .networkDisabled, .networkUnavailable, .rightsRestricted, .cancelled, .songNotVerified:
            return .manual
        case .unsupportedFormat:
            return .advanceToNext
        }
    }

    var isRetryable: Bool {
        if case .retry = hint { return true }
        return false
    }

    var maxRetryAttempts: Int {
        if case let .retry(maxAttempts, _) = hint { return maxAttempts }
        return 0
    }

    var retryBackoff: Duration {
        if case let .retry(_, backoff) = hint { return backoff }
        return .zero
    }
}
