import Foundation

/// 形态状态机。
///
/// 纯逻辑：输入事件 + 当前时刻，输出新状态与"该做什么动作"。
/// 不持有窗口、不碰 AppKit、不自己起定时器——窗口层负责执行动作，
/// 定时（防抖/冷却）通过 `.tick` 事件推进。这样可以脱离真实窗口穷举测试。
///
/// 优先级（规格 4.4）在 `handle` 里逐条落实：
/// 系统挂起 > 用户显式隐藏 > 用户锁定 > 用户主动展开 > 用户指定形态 > 自动空间优化。
struct MorphologyStateMachine: Sendable {
    private(set) var state: MorphologyState

    /// 把状态机拉回**窗口实际所处的形态**。
    ///
    /// 用途只有一个：当窗口层决定**不执行**某次自动变形时（例如"不许自动收成把手"），
    /// 状态机在 `handle` 里已经前进到了目标形态。不同步回来，两边就会长期不一致——
    /// 表现是"点胶囊不展开"：状态机以为自己已经是 expanded，把用户点击判成 redundant。
    mutating func assumeMorphology(_ morphology: PlayerMorphology) {
        state.current = morphology
        state.previous = nil
        state.phase = .settled
    }

    var tuning: MorphologyTuning

    init(state: MorphologyState = MorphologyState(), tuning: MorphologyTuning = .default) {
        self.state = state
        self.tuning = tuning
    }

    // MARK: - 冷启动恢复

    /// 只把"当前形态"落到位，**保留运行时事实**。
    ///
    /// 之前是直接重建整个 `MorphologyStateMachine`，把 `deactivatedAt`、
    /// `lastUserInteraction`、`hasStartedPlayback` 一起清掉了；而恢复任务是异步的，
    /// 落在 `syncFrontmostState()` 之后 —— 于是"我不在前台"被抹掉，
    /// 之后所有自动收缩都被判成 `appStillActive`（实测：播放着、切走了、就是不收缩）。
    mutating func adoptRestoredMorphology(_ morphology: PlayerMorphology) {
        state.current = morphology
        state.previous = morphology
        state.phase = .settled
        state.recommendation = MorphologyRecommendation(
            morphology: morphology,
            fitsPreferred: true,
            currentStillFits: true,
            availableSize: .zero
        )
    }

    // MARK: - 事件入口

    mutating func handle(_ event: MorphologyEvent, now: ContinuousClock.Instant) -> MorphologyDecision {
        switch event {
        case .sleep:
            return sleep(now: now)
        case .wake:
            return wake(now: now)
        case .fullscreenChanged(let isFullscreen):
            return isFullscreen ? enterFullscreen(now: now) : exitFullscreen(now: now)

        case .userHiddenChanged(let hidden):
            return setUserHidden(hidden, now: now)

        case .userLockChanged(let locked):
            return setUserLock(locked, now: now)

        case .userOpened:
            return userOpened(now: now)

        case .userRequested(let morphology):
            return userRequested(morphology, now: now)

        case .userCollapsed(let morphology):
            return userRequested(morphology, now: now)

        case .appActivated:
            state.deactivatedAt = nil
            return .init(state: state, actions: [])

        case .appDeactivated:
            state.deactivatedAt = now
            // 失焦立刻评估一次：真正的门槛在 tick 里（稳定 + 免打扰 + 冷却）。
            return attemptAutoApply(now: now)

        case .environmentEvaluated(let recommendation):
            if state.recommendation.morphology != recommendation.morphology || state.recommendationSince == nil {
                state.recommendationSince = now
            }
            state.recommendation = recommendation
            return attemptAutoApply(now: now)

        case .playbackStarted:
            // 播放本身不触发形态切换，但它标记"用户已经用起来了"：
            // 只有用起来之后，切走才允许自动收缩。
            state.hasStartedPlayback = true
            return .init(state: state, actions: [])

        case .playbackStopped:
            // 暂停/停止不是形态切换的理由：规格明确反对"播放后固定等待几秒就收缩"。
            return .init(state: state, actions: [])

        case .transitionCompleted:
            return completeTransition(now: now)

        case .transitionInterrupted:
            state.previous = nil
            state.phase = .settled
            state.lastSettledAt = now
            return .init(state: state, actions: [])

        case .autoMorphChanged(let enabled):
            state.isAutoMorphEnabled = enabled
            return .init(state: state, actions: [])

        case .auxiliaryActivityChanged(let isBrowsing):
            state.isBrowsingAuxiliary = isBrowsing
            if isBrowsing { state.lastUserInteraction = now }
            return .init(state: state, actions: [])

        case .tick:
            return tick(now: now)
        }
    }

    // MARK: - 用户意图

    /// 用户主动要完整播放器。
    ///
    /// 点击缩小后的胶囊属于"明确要求展开"，因此这里顺带解除形态锁定——
    /// 否则锁定胶囊的用户会陷入"点了没反应"的状态。位置锁定是另一套开关，不受影响。
    private mutating func userOpened(now: ContinuousClock.Instant) -> MorphologyDecision {
        state.lastUserInteraction = now
        // 点击展开视为解除形态锁定；位置锁定是另一套开关，不受影响。
        state.isLocked = false
        state.isUserHidden = false
        // 挂起期间用户仍然可以展开：清掉挂起，让人能继续用播放器。
        state.suspendedBy = nil
        state.morphologyBeforeSuspension = nil
        return transition(to: .expanded, now: now, reason: .userOpened)
    }

    private mutating func userRequested(_ morphology: PlayerMorphology, now: ContinuousClock.Instant) -> MorphologyDecision {
        state.lastUserInteraction = now
        // 用户显式隐藏时，任何"指定形态"都视为恢复显示。
        if state.isUserHidden { state.isUserHidden = false }
        let reason: MorphologyChangeReason = morphology.tightness > state.current.tightness
            ? .userCollapsed : .userSpecified
        return transition(to: morphology, now: now, reason: reason)
    }

    private mutating func setUserLock(_ locked: Bool, now: ContinuousClock.Instant) -> MorphologyDecision {
        state.lastUserInteraction = now
        guard state.isLocked != locked else {
            return .init(state: state, actions: [], rejection: .redundant)
        }
        state.isLocked = locked
        if !locked {
            // 解锁不是"立刻乱动"的理由：等下一轮空间评估。
            return .init(state: state, actions: [], reason: .userRestored)
        }
        return .init(state: state, actions: [], reason: .userLocked)
    }

    private mutating func setUserHidden(_ hidden: Bool, now: ContinuousClock.Instant) -> MorphologyDecision {
        state.lastUserInteraction = now
        guard state.isUserHidden != hidden else {
            return .init(state: state, actions: [], rejection: .redundant)
        }
        state.isUserHidden = hidden
        if hidden {
            state.morphologyBeforeSuspension = state.current
            return transition(to: .dormant, now: now, reason: .userHidden)
        }
        let restore = state.morphologyBeforeSuspension ?? state.recommendation.morphology
        state.morphologyBeforeSuspension = nil
        let target = restore == .dormant ? .capsule : restore
        return transition(to: target, now: now, reason: .userRestored)
    }

    // MARK: - 系统状态

    private mutating func sleep(now: ContinuousClock.Instant) -> MorphologyDecision {
        guard state.suspendedBy != .sleep else {
            return .init(state: state, actions: [], rejection: .suspended)
        }
        state.suspendedBy = .sleep
        state.morphologyBeforeSuspension = state.current
        guard state.current.isFloating else {
            return .init(state: state, actions: [], reason: .sleep)
        }
        return transition(to: .dormant, now: now, reason: .sleep)
    }

    private mutating func wake(now: ContinuousClock.Instant) -> MorphologyDecision {
        guard state.suspendedBy == .sleep else {
            return .init(state: state, actions: [], rejection: .redundant)
        }
        return restoreAfterSuspension(now: now, reason: .wake)
    }

    private mutating func enterFullscreen(now: ContinuousClock.Instant) -> MorphologyDecision {
        guard state.suspendedBy != .fullscreen else {
            return .init(state: state, actions: [], rejection: .suspended)
        }
        state.suspendedBy = .fullscreen
        state.morphologyBeforeSuspension = state.current
        // 完整播放器是用户自己的窗口，全屏应用不会盖住它，因此不动它。
        guard state.current.isFloating else {
            return .init(state: state, actions: [], reason: .fullscreenEntered)
        }
        return transition(to: .dormant, now: now, reason: .fullscreenEntered)
    }

    private mutating func exitFullscreen(now: ContinuousClock.Instant) -> MorphologyDecision {
        guard state.suspendedBy == .fullscreen else {
            return .init(state: state, actions: [], rejection: .redundant)
        }
        return restoreAfterSuspension(now: now, reason: .fullscreenExited)
    }

    private mutating func restoreAfterSuspension(now: ContinuousClock.Instant,
                                                 reason: MorphologyChangeReason) -> MorphologyDecision {
        let restore = state.morphologyBeforeSuspension ?? .capsule
        state.suspendedBy = nil
        state.morphologyBeforeSuspension = nil
        guard !state.isUserHidden else {
            return .init(state: state, actions: [], rejection: .userHidden)
        }
        let target = restore == .dormant ? .capsule : restore
        return transition(to: target, now: now, reason: reason)
    }

    // MARK: - 自动决策

    private mutating func tick(now: ContinuousClock.Instant) -> MorphologyDecision {
        attemptAutoApply(now: now)
    }

    /// 自动形态决策的统一入口。所有门槛都集中在这里，事件本身不做判断。
    private mutating func attemptAutoApply(now: ContinuousClock.Instant) -> MorphologyDecision {
        guard !state.isSuspended else {
            return .init(state: state, actions: [], rejection: .suspended)
        }
        guard !state.isUserHidden else {
            return .init(state: state, actions: [], rejection: .userHidden)
        }
        guard !state.isLocked else {
            return .init(state: state, actions: [], rejection: .locked)
        }
        guard !state.isBrowsingAuxiliary else {
            return .init(state: state, actions: [], rejection: .appStillActive)
        }
        guard state.isAutoMorphEnabled else {
            return .init(state: state, actions: [], rejection: .autoMorphDisabled)
        }

        guard state.phase == .settled else {
            return .init(state: state, actions: [], rejection: .coolingDown)
        }
        let target = state.recommendation.morphology
        guard target.participatesInAutoMorph else {
            // 空间引擎不该建议完整播放器；建议了就说明上层逻辑出错，保持现状。
            return .init(state: state, actions: [], rejection: .noBetterOption)
        }
        guard target != state.current else {
            return .init(state: state, actions: [], rejection: .noBetterOption)
        }

        // 完整播放器只在"用户已经离开、并且真的用过播放器"之后才允许收缩。
        if state.current == .expanded {
            guard state.hasStartedPlayback || state.lastUserInteraction != nil else {
                return .init(state: state, actions: [], rejection: .appStillActive)
            }
            guard let deactivatedAt = state.deactivatedAt else {
                return .init(state: state, actions: [], rejection: .appStillActive)
            }
            guard now >= deactivatedAt.advanced(by: tuning.autoCollapseDelay) else {
                return .init(state: state, actions: [], rejection: .appStillActive)
            }
        }

        if let last = state.lastUserInteraction,
           now < last.advanced(by: tuning.interactionGrace) {
            return .init(state: state, actions: [], rejection: .interactionGrace)
        }
        if let settled = state.lastSettledAt,
           now < settled.advanced(by: tuning.morphologyCooldown) {
            return .init(state: state, actions: [], rejection: .coolingDown)
        }

        if target.tightness < state.current.tightness,
           let since = state.recommendationSince,
           now < since.advanced(by: tuning.promotionStability) {
            return .init(state: state, actions: [], rejection: .coolingDown)
        }

        // 空间不再够用 → 先降级；空间变宽 → 只升一级，且要引擎已经确认收益足够。
        let tightening = target.tightness > state.current.tightness
        let reason: MorphologyChangeReason = tightening ? .spaceTightened : .spaceRestored
        return transition(to: target, now: now, reason: reason)
    }

    /// 返回真正挡住当前建议的最后一个截止时间。控制器只安排一次重评估，
    /// 不靠下一次 AX 通知推进冷却，也不对永久门槛反复轮询。
    func nextAutomaticEvaluation(after now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard state.phase == .settled, !state.isSuspended, !state.isUserHidden,
              !state.isLocked, !state.isBrowsingAuxiliary, state.isAutoMorphEnabled,
              state.recommendation.morphology != state.current,
              state.recommendation.morphology.participatesInAutoMorph else { return nil }
        var deadlines: [ContinuousClock.Instant] = []
        if state.current == .expanded {
            guard state.hasStartedPlayback || state.lastUserInteraction != nil,
                  let deactivated = state.deactivatedAt else { return nil }
            deadlines.append(deactivated.advanced(by: tuning.autoCollapseDelay))
        }
        if let interaction = state.lastUserInteraction {
            deadlines.append(interaction.advanced(by: tuning.interactionGrace))
        }
        if let settled = state.lastSettledAt {
            deadlines.append(settled.advanced(by: tuning.morphologyCooldown))
        }
        if state.recommendation.morphology.tightness < state.current.tightness,
           let since = state.recommendationSince {
            deadlines.append(since.advanced(by: tuning.promotionStability))
        }
        return deadlines.filter { $0 > now }.max()
    }

    // MARK: - 过渡

    private mutating func completeTransition(now: ContinuousClock.Instant) -> MorphologyDecision {
        state.previous = nil
        state.phase = .settled
        state.lastSettledAt = now
        // 隐匿形态在动画结束后才真正把窗口移出屏幕，避免"瞬间消失"。
        let actions: [MorphologyAction] = state.current == .dormant ? [.orderOut] : []
        return .init(state: state, actions: actions)
    }

    /// 执行（或替代）一次变形。
    ///
    /// 正在动画时收到新请求：不排队，直接替换——把起点写成动画中的目标形态，
    /// 由窗口层用"当前真实 frame"作为新的几何起点，所以视觉上不会回跳。
    private mutating func transition(to target: PlayerMorphology,
                                     now: ContinuousClock.Instant,
                                     reason: MorphologyChangeReason) -> MorphologyDecision {
        if target == state.current, state.phase == .settled {
            return .init(state: state, actions: [], reason: reason, rejection: .redundant)
        }

        // 内容在过渡一开始就切到了目标形态，所以新的起点永远是 `current`：
        // 打断动画时窗口层会用"当前真实 frame"作为几何起点，视觉上不会回跳。
        let from = state.current
        let wasHidden = state.current == .dormant

        state.previous = from
        state.current = target
        state.phase = .transitioning

        var actions: [MorphologyAction] = []
        // 从隐匿里恢复时窗口已经 orderOut，需要先重新上屏再做几何动画。
        if wasHidden, target != .dormant {
            actions.append(.orderFront(from))
        }
        actions.append(.transition(from: from, to: target))
        if target == .expanded {
            actions.append(.activateApplication)
        } else if from == .expanded {
            actions.append(.resignKeyFocus)
        }

        return .init(state: state, actions: actions, reason: reason)
    }
}
