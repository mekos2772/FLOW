import Foundation

/// 驱动状态机的外部事件。
///
/// 来源只有三类：用户意图（play/pause/seek/next/stop/retry）、
/// 音频会话回报（resourceReady/loadFailed/playbackFinished/playbackFailed/stall）、
/// 系统层（systemInterrupted/systemResumed/sourceChanged）。
enum PlaybackEvent: Sendable, Equatable {
    case load(Track, autoplay: Bool)
    case resourceReady(duration: TimeInterval)
    case loadFailed(PlaybackError)
    case play
    case pause(PauseReason)
    case resume
    case seek(TimeInterval)
    case seekFinished(TimeInterval)
    case next
    case previous
    case stop
    case retry
    case sourceChanged(SourceID)
    case playbackFinished
    case playbackFailed(PlaybackError)
    case systemInterrupted
    case systemResumed(shouldResume: Bool)
    case stallBegan
    case stallEnded
}
