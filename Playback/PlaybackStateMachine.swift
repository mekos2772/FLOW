import Foundation

/// 九态播放状态机。纯值类型、非隔离、不碰 I/O。
///
/// 契约：
/// - 输入事件 + 当前时刻，输出 (新状态, effect 列表, 是否被接受)。
/// - 非法迁移一律返回 `.rejected`：状态不变、不产 effect，调用方最多记一条 debug 日志。
/// - 因为不持有 session / 时钟 / UI，可被单测穷举全部 (状态 × 事件) 组合。
///
/// 并发命令策略（对应规格"并发命令顺序"）：
/// - `preparing` 期间只接受 load / stop / next / previous / sourceChanged，
///   其余用户意图一律拒绝——加载中的 play/pause 记录意图只会制造"看起来响应了其实没生效"的假象。
/// - `seeking` 期间只接受 seekFinished / stop / next / previous，
///   避免连续 seek 叠加出多个在途目标。
/// - 切歌一律先 `cancelLoading` + `releaseAudio` 再 `beginLoading`，
///   旧任务回调通过 trackID 比对隔离，不会覆盖新曲目状态。
struct PlaybackStateMachine: Sendable {
    private(set) var state: PlaybackState = .idle
    private(set) var context: PlaybackContext
    private(set) var isRouteAvailable: Bool = true

    init(now: Instant) {
        self.context = .empty(now: now)
    }

    mutating func handle(_ event: PlaybackEvent, now: Instant) -> StateMachineOutcome {
        switch event {
        case let .load(track, autoplay):
            return load(track, autoplay: autoplay, now: now)
        case let .resourceReady(duration):
            return resourceReady(duration, now: now)
        case let .loadFailed(error):
            return loadFailed(error, now: now)
        case .play:
            return play(now: now)
        case let .pause(reason):
            return pause(reason, now: now)
        case .resume:
            return resume(now: now)
        case let .seek(position):
            return seek(position, now: now)
        case let .seekFinished(position):
            return seekFinished(position, now: now)
        case .next:
            return skip(.next, now: now)
        case .previous:
            return skip(.previous, now: now)
        case .stop:
            return stop(now: now)
        case .retry:
            return retry(now: now)
        case let .sourceChanged(sourceID):
            return sourceChanged(sourceID, now: now)
        case .playbackFinished:
            return playbackFinished(now: now)
        case let .playbackFailed(error):
            return failed(error, now: now)
        case .systemInterrupted:
            return systemInterrupted(now: now)
        case let .systemResumed(shouldResume):
            return systemResumed(shouldResume: shouldResume, now: now)
        case .stallBegan:
            return stallBegan(now: now)
        case .stallEnded:
            return stallEnded(now: now)
        }
    }

    // MARK: - 装载

    private mutating func load(_ track: Track, autoplay: Bool, now: Instant) -> StateMachineOutcome {
        context = PlaybackContext(
            trackID: track.id,
            duration: track.duration,
            anchor: .anchored(at: 0, now: now, rate: 0),
            retryCount: 0,
            pauseReason: nil,
            pendingAutoplay: autoplay
        )
        state = .preparing(context)
        return accept([
            .cancelLoading,
            .releaseAudio,
            .publish(state),
            .beginLoading(trackID: track.id, startAt: 0, delay: .zero),
        ])
    }

    private mutating func resourceReady(_ duration: TimeInterval, now: Instant) -> StateMachineOutcome {
        guard case .preparing(let bound) = state else { return .rejected(state) }

        var ctx = bound
        if duration > 0 { ctx.duration = duration }
        let upperBound = ctx.duration > 0 ? ctx.duration : ctx.anchor.position
        let resumePosition = min(max(ctx.anchor.position, 0), max(upperBound, 0))

        if ctx.pendingAutoplay {
            ctx.anchor = .anchored(at: resumePosition, now: now, rate: 1)
            ctx.pauseReason = nil
            context = ctx
            state = .playing(ctx)
            return accept([.publish(state), .playAudio])
        }

        ctx.anchor = .anchored(at: resumePosition, now: now, rate: 0)
        ctx.pauseReason = .preparing
        context = ctx
        state = .ready(ctx)
        return accept([.publish(state)])
    }

    private mutating func loadFailed(_ error: PlaybackError, now: Instant) -> StateMachineOutcome {
        failed(error, now: now)
    }

    // MARK: - 用户意图

    private mutating func play(now: Instant) -> StateMachineOutcome {
        switch state {
        case .ready(let bound), .paused(let bound, _):
            return enterPlaying(from: bound, now: now)

        case .ended(let bound):
            // 结束后再次播放：从头开始。
            var ctx = bound
            ctx.anchor = .anchored(at: 0, now: now, rate: 1)
            ctx.pauseReason = nil
            context = ctx
            state = .playing(ctx)
            return accept([.publish(state), .seekAudio(0), .playAudio])

        case .idle, .preparing, .playing, .buffering, .seeking, .failed:
            return .rejected(state)
        }
    }

    private mutating func resume(now: Instant) -> StateMachineOutcome {
        guard case .paused(let bound, let reason) = state else { return .rejected(state) }
        guard reason.isAutoResumable || reason == .user || reason == .sleepTimer else {
            return .rejected(state)
        }
        guard isRouteAvailable else { return .rejected(state) }
        return enterPlaying(from: bound, now: now)
    }

    private mutating func enterPlaying(from bound: PlaybackContext, now: Instant) -> StateMachineOutcome {
        guard isRouteAvailable else { return .rejected(state) }
        var ctx = bound
        ctx.anchor = ctx.anchor.rebased(at: now, rate: 1)
        ctx.pauseReason = nil
        ctx.pendingAutoplay = true
        context = ctx
        state = .playing(ctx)
        return accept([.publish(state), .playAudio])
    }

    private mutating func pause(_ reason: PauseReason, now: Instant) -> StateMachineOutcome {
        switch state {
        case .playing(let bound), .buffering(let bound):
            var ctx = bound
            ctx.anchor = ctx.anchor.rebased(at: now, rate: 0)
            ctx.pauseReason = reason
            if reason == .user { ctx.pendingAutoplay = false }
            context = ctx
            state = .paused(ctx, reason)
            return accept([.publish(state), .pauseAudio])

        case .paused(let bound, _):
            var ctx = bound
            ctx.pauseReason = reason
            if reason == .user { ctx.pendingAutoplay = false }
            context = ctx
            state = .paused(ctx, reason)
            return accept([.publish(state)])

        case .idle, .preparing, .ready, .seeking, .ended, .failed:
            return .rejected(state)
        }
    }

    private mutating func seek(_ position: TimeInterval, now: Instant) -> StateMachineOutcome {
        let destination = max(0, position)

        switch state {
        case .playing(let bound):
            return enterSeeking(from: bound, to: destination, returnsTo: .playing, now: now)
        case .paused(let bound, _):
            return enterSeeking(from: bound, to: destination, returnsTo: .paused, now: now)
        case .ready(let bound), .ended(let bound):
            return enterSeeking(from: bound, to: destination, returnsTo: .ready, now: now)
        case .idle, .preparing, .buffering, .seeking, .failed:
            return .rejected(state)
        }
    }

    private mutating func enterSeeking(from bound: PlaybackContext,
                                       to destination: TimeInterval,
                                       returnsTo: SeekReturn,
                                       now: Instant) -> StateMachineOutcome {
        var ctx = bound
        let origin = ctx.clampedPosition(at: now)
        // seek 在途期间进度跟随目标值，避免 UI 显示回跳。
        ctx.anchor = .anchored(at: destination, now: now, rate: returnsTo == .playing ? 1 : 0)
        context = ctx
        let target = SeekTarget(origin: origin, destination: destination, returnsTo: returnsTo)
        state = .seeking(ctx, target)
        return accept([.publish(state), .seekAudio(destination)])
    }

    private mutating func seekFinished(_ position: TimeInterval, now: Instant) -> StateMachineOutcome {
        guard case .seeking(let bound, let target) = state else { return .rejected(state) }

        var ctx = bound
        let clamped = max(0, position)
        context = ctx

        switch target.returnsTo {
        case .playing:
            ctx.anchor = .anchored(at: clamped, now: now, rate: 1)
            ctx.pauseReason = nil
            context = ctx
            state = .playing(ctx)
            return accept([.publish(state)])
        case .paused:
            ctx.anchor = .anchored(at: clamped, now: now, rate: 0)
            ctx.pauseReason = .user
            context = ctx
            state = .paused(ctx, .user)
            return accept([.publish(state)])
        case .ready:
            ctx.anchor = .anchored(at: clamped, now: now, rate: 0)
            ctx.pauseReason = .preparing
            context = ctx
            state = .ready(ctx)
            return accept([.publish(state)])
        }
    }

    // MARK: - 队列

    private mutating func skip(_ direction: SkipDirection, now: Instant) -> StateMachineOutcome {
        guard state.isActive else { return .rejected(state) }

        var ctx = state.context ?? context
        ctx.anchor = .anchored(at: 0, now: now, rate: 0)
        ctx.pauseReason = nil
        ctx.pendingAutoplay = true
        context = ctx
        state = .preparing(ctx)
        return accept([
            .publish(state),
            .cancelLoading,
            .releaseAudio,
            .requestNeighbor(direction),
        ])
    }

    private mutating func stop(now: Instant) -> StateMachineOutcome {
        guard state.isActive else { return .rejected(state) }
        context = .empty(now: now)
        state = .idle
        return accept([.publish(state), .cancelLoading, .releaseAudio])
    }

    // MARK: - 失败与恢复

    private mutating func failed(_ error: PlaybackError, now: Instant) -> StateMachineOutcome {
        // 取消不是失败：切歌导致的加载取消必须保持现状。
        if case .cancelled = error { return .rejected(state) }
        guard state.isActive else { return .rejected(state) }

        context.pauseReason = nil
        // 失败的那一刻把进度**冻住**。
        // 锚点还带着 `rate = 1` 的话，"当前位置"会在失败状态里继续往前走——
        // 没有声音，进度条却在动；之后按位置恢复也会落到一个没播过的地方。
        context.anchor = context.anchor.rebased(at: now, rate: 0)
        state = .failed(context, error)
        return accept([.publish(state), .releaseAudio, .reportError(error)])
    }

    private mutating func retry(now: Instant) -> StateMachineOutcome {
        guard case .failed(let maybeContext, let error) = state,
              var ctx = maybeContext,
              let trackID = ctx.trackID else {
            return .rejected(state)
        }

        switch error.hint {
        case let .retry(maxAttempts, backoff):
            guard ctx.retryCount < maxAttempts else {
                // 超限：不再自动重试，交还上层决定人工重试或跳过。
                return StateMachineOutcome(
                    state: state,
                    effects: [.reportError(error), .requestNeighbor(.next)],
                    accepted: false
                )
            }
            ctx.retryCount += 1
            ctx.anchor = .anchored(at: 0, now: now, rate: 0)
            ctx.pendingAutoplay = true
            ctx.pauseReason = nil
            context = ctx
            state = .preparing(ctx)
            return accept([
                .publish(state),
                .cancelLoading,
                .beginLoading(trackID: trackID, startAt: 0, delay: backoff),
            ])

        case .advanceToNext:
            return skip(.next, now: now)

        case .degradeToPlaceholder, .manual:
            return StateMachineOutcome(state: state, effects: [.reportError(error)], accepted: false)
        }
    }

    private mutating func sourceChanged(_ sourceID: SourceID, now: Instant) -> StateMachineOutcome {
        guard var ctx = state.context, let trackID = ctx.trackID else { return .rejected(state) }

        let position: TimeInterval
        if case .ended = state {
            position = 0
        } else {
            position = ctx.clampedPosition(at: now)
        }
        ctx.anchor = .anchored(at: position, now: now, rate: 0)
        ctx.pauseReason = nil
        ctx.pendingAutoplay = ctx.pendingAutoplay || state.isPlaying
        context = ctx
        state = .preparing(ctx)
        _ = trackID
        return accept([
            .publish(state),
            .cancelLoading,
            .releaseAudio,
            .reloadCurrentTrack(sourceID: sourceID, position: position),
        ])
    }

    // MARK: - 会话回报与系统事件

    private mutating func playbackFinished(now: Instant) -> StateMachineOutcome {
        // `.buffering` 也要接：音频到底的那一刻常常正处在重新缓冲的尾巴上，
        // 只认 `.playing` 会把"自然播完"漏成"永远在缓冲"。
        let bound: PlaybackContext
        switch state {
        case .playing(let ctx), .buffering(let ctx), .seeking(let ctx, _): bound = ctx
        case .idle, .preparing, .ready, .paused, .ended, .failed:
            return .rejected(state)
        }
        var ctx = bound
        ctx.anchor = .anchored(at: ctx.duration, now: now, rate: 0)
        ctx.pauseReason = nil
        context = ctx
        state = .ended(ctx)
        return accept([.publish(state)])
    }

    /// 重新缓冲。
    ///
    /// HTTP 流式会话通过 `.stallBegan` / `.stallEnded` 报告缓冲状态。
    /// 状态机维护缓冲期间冻结的进度锚点与恢复意图。
    private mutating func stallBegan(now: Instant) -> StateMachineOutcome {
        guard case .playing(let bound) = state else { return .rejected(state) }
        var ctx = bound
        ctx.anchor = ctx.anchor.rebased(at: now, rate: 0)
        context = ctx
        state = .buffering(ctx)
        return accept([.publish(state)])
    }

    private mutating func stallEnded(now: Instant) -> StateMachineOutcome {
        guard case .buffering(let bound) = state else { return .rejected(state) }
        var ctx = bound
        ctx.anchor = ctx.anchor.rebased(at: now, rate: 1)
        context = ctx
        state = .playing(ctx)
        return accept([.publish(state)])
    }

    private mutating func systemInterrupted(now: Instant) -> StateMachineOutcome {
        switch state {
        case .playing(let bound), .buffering(let bound):
            var ctx = bound
            ctx.anchor = ctx.anchor.rebased(at: now, rate: 0)
            ctx.pauseReason = .interruption
            context = ctx
            state = .paused(ctx, .interruption)
            return accept([.publish(state), .pauseAudio])

        case .paused(let bound, let reason):
            guard reason.isAutoResumable else { return .rejected(state) }
            var ctx = bound
            ctx.pauseReason = .interruption
            context = ctx
            state = .paused(ctx, .interruption)
            return accept([.publish(state)])

        case .idle, .preparing, .ready, .seeking, .ended, .failed:
            return .rejected(state)
        }
    }

    private mutating func systemResumed(shouldResume: Bool, now: Instant) -> StateMachineOutcome {
        guard case .paused(let bound, let reason) = state, reason.isAutoResumable else {
            return .rejected(state)
        }
        guard shouldResume, isRouteAvailable else {
            return StateMachineOutcome(state: state, effects: [], accepted: false)
        }
        return enterPlaying(from: bound, now: now)
    }

    // MARK: - 工具

    private func accept(_ effects: [PlaybackEffect]) -> StateMachineOutcome {
        StateMachineOutcome(state: state, effects: effects, accepted: true)
    }
}
