import Foundation

/// 状态机产出的副作用意图。
///
/// 状态机是纯函数：读事件、写自身状态、吐 effect 列表，不碰 session、时钟、UI。
/// 由 `PlaybackEngine` 逐条执行，执行结果再以新事件喂回，形成闭环。
enum PlaybackEffect: Sendable, Equatable {
    case cancelLoading
    case releaseAudio
    case beginLoading(trackID: Track.ID, startAt: TimeInterval, delay: Duration)
    case reloadCurrentTrack(sourceID: SourceID, position: TimeInterval)
    case playAudio
    case pauseAudio
    case seekAudio(TimeInterval)
    case requestNeighbor(SkipDirection)
    case reportError(PlaybackError)
    case publish(PlaybackState)
}

/// 一次处理的完整结果。
struct StateMachineOutcome: Sendable, Equatable {
    var state: PlaybackState
    var effects: [PlaybackEffect]
    var accepted: Bool

    static func rejected(_ state: PlaybackState) -> StateMachineOutcome {
        StateMachineOutcome(state: state, effects: [], accepted: false)
    }
}
