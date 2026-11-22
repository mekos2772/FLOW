import AppKit
import Foundation
import MediaPlayer

/// 系统正在播放与远程控制。
///
/// 只做两件事：把统一播放状态投影成 `MPNowPlayingInfoCenter` 的信息，
/// 把 `MPRemoteCommandCenter` 的事件翻译成 `RemoteCommand` 回传。
/// 它不持有播放器、不做业务判断——所有命令最终都要进 `PlaybackEngine`。
enum RemoteCommand: Sendable, Equatable {
    case play
    case pause
    case toggle
    case next
    case previous
    case seek(TimeInterval)
}

@MainActor
final class MediaPlayerNowPlayingBridge: NowPlayingBridging {
    var onCommand: ((RemoteCommand) -> Void)?

    private var isConfigured = false
    private(set) var lastPublishedState: PlaybackState?

    /// 只注册一次远程命令，避免重复监听导致一条媒体键被处理多次。
    func configureCommandsIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        // 回调闭包**不能**带主 actor 隔离。
        //
        // 在 `@MainActor` 方法里直接写 `addTarget { ... }`，闭包会被推断成主 actor 隔离，
        // Swift 6 会在闭包入口插一条执行器断言。MediaPlayer 从哪条队列回调并没有文档保证——
        // 封面的 request handler 就是同样的写法、同样的原因崩过（见下面 `NowPlayingArtwork`）。
        // 所以这里把闭包放到 nonisolated 的静态方法里构造，只捕获一个 `@Sendable` 的转发器。
        let forward: @Sendable (RemoteCommand) -> Void = { [weak self] command in
            Task { @MainActor [weak self] in
                self?.onCommand?(command)
            }
        }
        Self.installHandlers(forward: forward)
    }

    private nonisolated static func installHandlers(forward: @escaping @Sendable (RemoteCommand) -> Void) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            forward(.play)
            return .success
        }
        center.pauseCommand.addTarget { _ in
            forward(.pause)
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            forward(.toggle)
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            forward(.next)
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            forward(.previous)
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            forward(.seek(event.positionTime))
            return .success
        }
    }

    /// 最近一次推送用的封面数据（同一张图不重复构造 `MPMediaItemArtwork`）。
    private var lastArtworkIdentity: TrackIdentity?
    private var lastArtwork: MPMediaItemArtwork?

    func update(state: PlaybackState, track: Track?, position: TimeInterval, artwork: Data? = nil) {
        configureCommandsIfNeeded()

        guard let track else {
            clear()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0,
        ]
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if track.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = track.duration }
        if let artwork, let image = NSImage(data: artwork) {
            let identity = TrackIdentity(sourceID: track.sourceID, externalID: track.externalID)
            if lastArtworkIdentity != identity || lastArtwork == nil {
                lastArtwork = NowPlayingArtwork.make(from: artwork, size: image.size)
                lastArtworkIdentity = identity
            }
            if let lastArtwork { info[MPMediaItemPropertyArtwork] = lastArtwork }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playbackState(for: state)
        lastPublishedState = state
    }

    func clear() {
        lastArtwork = nil
        lastArtworkIdentity = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        lastPublishedState = nil
    }

    private func playbackState(for state: PlaybackState) -> MPNowPlayingPlaybackState {
        switch state {
        case .playing: return .playing
        case .preparing, .buffering, .seeking: return .playing
        case .paused, .ready: return .paused
        case .idle, .ended, .failed: return .stopped
        }
    }
}

/// 给系统"正在播放"构造封面的唯一入口。
///
/// **这里必须是 `nonisolated`，而且闭包必须显式 `@Sendable`。**
/// `MPMediaItemArtwork` 的 request handler 由 MediaPlayer 在它自己的串行队列
/// （实测队列名 `*/accessQueue`）上调用，调用栈是
/// `-[MPMediaItemArtwork jpegDataWithSize:]` ← `_MPToMRNowPlayingInfoDictionary`。
/// 早先写成 `MPMediaItemArtwork(boundsSize:) { _ in image }`，闭包在 `@MainActor`
/// 上下文里形成、又捕获了主线程隔离的 `NSImage`，于是被推断成 MainActor 隔离闭包；
/// 系统在后台队列调它时执行器断言直接 trap：
///
///     EXC_BREAKPOINT / SIGTRAP
///     _dispatch_assert_queue_fail ← swift_task_isCurrentExecutorWithFlagsImpl
///
/// 只要曲目有封面就必然复现（崩溃报告 SpatialLyricsPlayer-2026-11-15-062145）。
/// 所以这里只捕获 `Data` 与 `CGSize` 两个 `Sendable` 值，在闭包里现建 `NSImage`。
enum NowPlayingArtwork {
    nonisolated static func make(from data: Data, size: CGSize) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: size) { @Sendable requestedSize in
            // 只碰 Sendable 入参，不引用任何 actor 隔离状态。
            render(data, size: requestedSize)
        }
    }

    /// 闭包的真实内容。单独抽出来是为了能在后台线程直接验证它不需要主线程。
    nonisolated static func render(_ data: Data, size: CGSize) -> NSImage {
        if let image = NSImage(data: data) { return image }
        return NSImage(size: size)
    }
}
