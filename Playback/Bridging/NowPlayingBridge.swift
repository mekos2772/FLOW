import Foundation

/// 系统正在播放桥接的抽象。
///
/// 正式实现是 `MediaPlayerNowPlayingBridge`（真的接 `MPNowPlayingInfoCenter`
/// 与 `MPRemoteCommandCenter`，媒体键可用）。
/// 本文件里的 `NoopNowPlayingBridge` 只是**测试替身**，不要误读成"功能还没做"。
/// 约束：桥接层只消费 `PlaybackState`，不得直接调源。
@MainActor
protocol NowPlayingBridging: AnyObject {
    func update(state: PlaybackState, track: Track?, position: TimeInterval, artwork: Data?)
    func clear()
}

/// 测试替身：记录收到的状态，不产生任何系统副作用。
@MainActor
final class NoopNowPlayingBridge: NowPlayingBridging {
    private(set) var lastPublishedState: PlaybackState?
    private(set) var publishCount = 0

    func update(state: PlaybackState, track: Track?, position: TimeInterval, artwork: Data?) {
        lastPublishedState = state
        lastPublishedArtwork = artwork
        publishCount += 1
    }

    /// 供测试断言"封面确实传下来了"。
    private(set) var lastPublishedArtwork: Data?

    func clear() {
        lastPublishedState = nil
    }
}
