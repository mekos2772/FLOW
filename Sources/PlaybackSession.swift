import Foundation

/// session 能力声明。能力不足时播放内核必须降级而不是抛错。
struct SessionCapabilities: Hashable, Sendable {
    var canSeek: Bool
    var canSetRate: Bool
    var canSkip: Bool

    static let full = SessionCapabilities(canSeek: true, canSetRate: true, canSkip: true)
    static let playOnly = SessionCapabilities(canSeek: false, canSetRate: false, canSkip: true)
}

/// session 向播放内核回报的事件。
enum SessionEvent: Sendable, Equatable {
    case prepared(duration: TimeInterval)
    case ended
    case failed(PlaybackError)
    case rateChanged(Double)
    case stalled(Bool)
}

/// 播放会话。**换源不改播放层的唯一接缝**。
///
/// Mock 源用虚拟时钟实现；将来的真实源用 AVPlayer 包一层实现。
/// 播放内核只认这个协议，源码里不出现任何具体播放器类型。
protocol PlaybackSession: AnyObject, Sendable {
    var id: UUID { get }
    var duration: TimeInterval { get }
    var capabilities: SessionCapabilities { get }
    var events: AsyncStream<SessionEvent> { get }

    func prepare() async throws
    func play() async throws
    func pause() async
    func seek(to position: TimeInterval) async throws
    func setRate(_ rate: Double) async
    func setVolume(_ volume: Float) async
    func markGaplessNext() async
    func invalidate() async
}

extension PlaybackSession {
    /// 通知会话本次将以无缝预热接续（自动切歌）方式起播，可跳过淡入压低首拍。
    func markGaplessNext() async {}
}
