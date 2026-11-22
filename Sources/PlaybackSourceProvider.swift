import Foundation

/// 源提供协议。所有方法异步、可取消。
///
/// 取消约定：实现内部必须在每个 `await` 前后 `try Task.checkCancellation()`，
/// 且不得吞掉 `CancellationError`；`map(_:)` 必须把取消映射为 `.cancelled`，不能映射为失败。
protocol PlaybackSourceProvider: Sendable {
    var descriptor: SourceDescriptor { get }

    func search(_ request: SearchRequest) async throws -> [Track]
    func makeSession(for track: Track) async throws -> any PlaybackSession
    func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession
    func artwork(for reference: ArtworkReference) async throws -> Data?
    func lyrics(for track: Track) async throws -> LyricsDocument?
    func map(_ error: any Error) -> PlaybackError

    /// 把"只有身份、没有元信息"的曲目补全（歌名/歌手/时长/封面）。
    ///
    /// 场景：歌单、电台、粘贴 BV 号直开——这些地方只知道 BV 号，
    /// 如果不补全，界面就会把 `BV1xx411c7mD` 当成歌名显示。
    /// 默认实现返回 nil，表示该源不需要/不支持补全。
    func resolve(_ track: Track) async -> Track?

    /// 是否支持后台预热下一首会话（Gapless）。真实音频源可开启以消除切歌间隙。
    var supportsGaplessPrewarm: Bool { get }
    /// 静默构造预热会话（不应上报"当前正在播放音质"等状态）。
    func makePrewarmSession(for track: Track) async throws -> any PlaybackSession
    /// 预热会话正式晋升为当前播放会话时通知源补齐指标回调（如实际音质）。
    func noteSessionPromoted(_ session: any PlaybackSession)
}

extension PlaybackSourceProvider {
    /// 默认不补全。
    func resolve(_ track: Track) async -> Track? { nil }

    var supportsGaplessPrewarm: Bool { false }

    func makePrewarmSession(for track: Track) async throws -> any PlaybackSession {
        try await makeSession(for: track)
    }

    func noteSessionPromoted(_ session: any PlaybackSession) {}

    /// 默认错误映射：先认播放错误，再认取消，其余归为 sourceUnavailable。
    func defaultMap(_ error: any Error) -> PlaybackError {
        if let playbackError = error as? PlaybackError { return playbackError }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if nsError.code == NSURLErrorCancelled { return .cancelled }
            // 连不上网不是"这首歌有问题"：单独归类，恢复策略才能等网络而不是换歌。
            if Self.connectivityCodes.contains(nsError.code) { return .networkUnavailable }
        }
        return .sourceUnavailable
    }

    /// 表示"网络本身不通"的 URL 错误码。
    static var connectivityCodes: Set<Int> {
        [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
         NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
         NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed, NSURLErrorSecureConnectionFailed]
    }
}
