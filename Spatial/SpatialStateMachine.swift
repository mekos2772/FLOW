import Foundation

enum SpatialState: String, Sendable, Equatable {
    case following
    case evaluating
    case repositioning
    case morphing
    case locked
    case suspended
}

enum SpatialEvent: Sendable, Equatable {
    case frontWindowChanged
    case windowMoved
    case windowResized
    case displayAdded
    case displayRemoved
    case displayConfigurationChanged
    case spaceChanged
    case fullscreenEntered
    case fullscreenExited
    case userDragged
    case userLocked
    case userUnlocked
    case lyricShapeChanged
    case playbackPaused
    case playbackResumed
    case sleep
    case wake
    case solved(shapeChanged: Bool)
    case tick
}

struct SpatialOutcome: Sendable, Equatable {
    var state: SpatialState
    var requestSolve: Bool
    var isHidden: Bool
}

/// 空间状态机。只决定"什么时候求解"，不决定"放到哪"。
///
/// 两个时间闸门都在这里：
/// - 窗口几何事件先进入 `evaluating` 并等满 `debounce`，把连续拖拽合并成一次求解；
/// - 求解完成后若发生形态切换，进入 `morphing` 冷却，冷却期内不接受新的求解请求，
///   避免动画期间反复重算导致画面抖动。
struct SpatialStateMachine: Sendable {
    private(set) var state: SpatialState = .following
    private(set) var isFullscreen = false
    private(set) var isAsleep = false
    private var evaluateDeadline: Instant?
    private var morphDeadline: Instant?

    var tuning: PlacementTuning

    init(tuning: PlacementTuning = PlacementTuning()) {
        self.tuning = tuning
    }

    mutating func handle(_ event: SpatialEvent, now: Instant) -> SpatialOutcome {
        switch event {
        case .sleep:
            isAsleep = true
            state = .suspended
            return outcome()

        case .wake:
            isAsleep = false
            state = .following
            return outcome(requestSolve: true)

        case .fullscreenEntered:
            isFullscreen = true
            return outcome()

        case .fullscreenExited:
            isFullscreen = false
            return outcome(requestSolve: true)

        case .userLocked:
            state = .locked
            return outcome()

        case .userUnlocked:
            state = .following
            return outcome(requestSolve: true)

        case .userDragged:
            // 拖拽期间不求解；结束后由调用方发 tick 触发一次。
            evaluateDeadline = nil
            if state != .locked { state = .following }
            return outcome()

        case .frontWindowChanged, .windowMoved, .windowResized,
             .displayAdded, .displayRemoved, .displayConfigurationChanged, .spaceChanged:
            guard !isAsleep, !isFullscreen, state != .locked else { return outcome() }
            guard state != .morphing else { return outcome() }
            evaluateDeadline = now.advanced(by: tuning.debounce)
            state = .evaluating
            return outcome()

        case .lyricShapeChanged:
            morphDeadline = now.advanced(by: tuning.morphologyCooldown)
            state = .morphing
            return outcome()

        case let .solved(shapeChanged):
            if shapeChanged {
                morphDeadline = now.advanced(by: tuning.morphologyCooldown)
                state = .morphing
            } else {
                state = .following
            }
            evaluateDeadline = nil
            return outcome()

        case .tick:
            if state == .morphing, let morphDeadline, now >= morphDeadline {
                self.morphDeadline = nil
                state = .following
                return outcome()
            }
            if state == .evaluating, let evaluateDeadline, now >= evaluateDeadline {
                self.evaluateDeadline = nil
                state = .repositioning
                return outcome(requestSolve: true)
            }
            return outcome()

        case .playbackPaused, .playbackResumed:
            return outcome()
        }
    }

    private func outcome(requestSolve: Bool = false) -> SpatialOutcome {
        SpatialOutcome(state: state, requestSolve: requestSolve, isHidden: isFullscreen || isAsleep)
    }
}
