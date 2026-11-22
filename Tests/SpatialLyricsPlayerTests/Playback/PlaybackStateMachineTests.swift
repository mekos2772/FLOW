import XCTest
@testable import SpatialLyricsPlayer

/// 九态迁移矩阵 + 关键路径定向用例。
///
/// 矩阵只写"合法迁移"表，其余全部断言被拒绝且状态不变——
/// 这样任何一次误加的分支都会立刻被"未列入合法表"抓出来。
final class PlaybackStateMachineTests: XCTestCase {

    private let track = Track(
        sourceID: .mock,
        externalID: "mock-001",
        title: "Spatial Drift",
        artist: "Mock Ensemble",
        duration: 200
    )

    private var now: Instant { ContinuousClock().now }

    // MARK: - 状态种子

    private enum Seed: String, CaseIterable {
        case idle, preparing, ready, playing, paused, buffering, seeking, ended, failed
    }

    private enum EventKey: String, CaseIterable {
        case load, resourceReady, loadFailed, play, pause, resume, seek, seekFinished,
             next, previous, stop, retry, sourceChanged, playbackFinished,
             playbackFailed, systemInterrupted, systemResumed, stallBegan, stallEnded
    }

    private func makeMachine(_ seed: Seed) -> PlaybackStateMachine {
        let t = ContinuousClock().now
        var m = PlaybackStateMachine(now: t)

        switch seed {
        case .idle:
            break
        case .preparing:
            _ = m.handle(.load(track, autoplay: true), now: t)
        case .ready:
            _ = m.handle(.load(track, autoplay: false), now: t)
            _ = m.handle(.resourceReady(duration: 200), now: t)
        case .playing:
            _ = m.handle(.load(track, autoplay: true), now: t)
            _ = m.handle(.resourceReady(duration: 200), now: t)
        case .paused:
            _ = m.handle(.load(track, autoplay: true), now: t)
            _ = m.handle(.resourceReady(duration: 200), now: t)
            _ = m.handle(.pause(.user), now: t)
        case .buffering:
            _ = m.handle(.load(track, autoplay: true), now: t)
            _ = m.handle(.resourceReady(duration: 200), now: t)
            _ = m.handle(.stallBegan, now: t)
        case .seeking:
            _ = m.handle(.load(track, autoplay: true), now: t)
            _ = m.handle(.resourceReady(duration: 200), now: t)
            _ = m.handle(.seek(30), now: t)
        case .ended:
            _ = m.handle(.load(track, autoplay: true), now: t)
            _ = m.handle(.resourceReady(duration: 200), now: t)
            _ = m.handle(.playbackFinished, now: t)
        case .failed:
            _ = m.handle(.load(track, autoplay: true), now: t)
            _ = m.handle(.resourceReady(duration: 200), now: t)
            _ = m.handle(.playbackFailed(.decodeFailed(reason: "matrix")), now: t)
        }
        return m
    }

    private func event(_ key: EventKey) -> PlaybackEvent {
        switch key {
        case .load: return .load(track, autoplay: true)
        case .resourceReady: return .resourceReady(duration: 200)
        case .loadFailed: return .loadFailed(.sourceUnavailable)
        case .play: return .play
        case .pause: return .pause(.user)
        case .resume: return .resume
        case .seek: return .seek(30)
        case .seekFinished: return .seekFinished(30)
        case .next: return .next
        case .previous: return .previous
        case .stop: return .stop
        case .retry: return .retry
        case .sourceChanged: return .sourceChanged(SourceID("local-file"))
        case .playbackFinished: return .playbackFinished
        case .playbackFailed: return .playbackFailed(.decodeFailed(reason: "oops"))
        case .systemInterrupted: return .systemInterrupted
        case .systemResumed: return .systemResumed(shouldResume: true)
        case .stallBegan: return .stallBegan
        case .stallEnded: return .stallEnded
        }
    }

    /// 合法迁移表。未列出的 (状态, 事件) 组合必须被拒绝。
    private static let legalTable = """
    idle|load preparing
    preparing|load preparing
    preparing|loadFailed failed
    preparing|playbackFailed failed
    preparing|next preparing
    preparing|previous preparing
    preparing|stop idle
    preparing|sourceChanged preparing
    ready|load preparing
    ready|play playing
    ready|seek seeking
    ready|next preparing
    ready|previous preparing
    ready|stop idle
    ready|loadFailed failed
    ready|playbackFailed failed
    ready|sourceChanged preparing
    playing|load preparing
    playing|pause paused
    playing|seek seeking
    playing|next preparing
    playing|previous preparing
    playing|stop idle
    playing|playbackFinished ended
    playing|playbackFailed failed
    playing|loadFailed failed
    playing|systemInterrupted paused
    playing|stallBegan buffering
    playing|sourceChanged preparing
    paused|play playing
    paused|resume playing
    paused|pause paused
    paused|seek seeking
    paused|next preparing
    paused|previous preparing
    paused|stop idle
    paused|load preparing
    paused|playbackFailed failed
    paused|loadFailed failed
    paused|sourceChanged preparing
    buffering|pause paused
    buffering|stallEnded playing
    buffering|playbackFinished ended
    buffering|next preparing
    buffering|previous preparing
    buffering|stop idle
    buffering|load preparing
    buffering|playbackFailed failed
    buffering|loadFailed failed
    buffering|systemInterrupted paused
    buffering|sourceChanged preparing
    seeking|next preparing
    seeking|previous preparing
    seeking|stop idle
    seeking|load preparing
    seeking|playbackFailed failed
    seeking|loadFailed failed
    seeking|sourceChanged preparing
    seeking|playbackFinished ended
    ended|play playing
    ended|seek seeking
    ended|next preparing
    ended|previous preparing
    ended|stop idle
    ended|load preparing
    ended|playbackFailed failed
    ended|loadFailed failed
    ended|sourceChanged preparing
    failed|retry preparing
    failed|next preparing
    failed|previous preparing
    failed|stop idle
    failed|load preparing
    failed|playbackFailed failed
    failed|loadFailed failed
    failed|sourceChanged preparing
    """

    private func parsedLegalTable() -> [String: String] {
        var table: [String: String] = [:]
        for line in Self.legalTable.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            table[String(parts[0])] = String(parts[1])
        }
        return table
    }

    // MARK: - 矩阵

    func testTransitionMatrix() {
        let table = parsedLegalTable()
        var checked = 0
        var legalChecked = 0

        for seed in Seed.allCases {
            for key in EventKey.allCases {
                // resourceReady 与 seekFinished 的目标取决于上下文，单独测。
                if key == .resourceReady || key == .seekFinished { continue }

                let id = "\(seed.rawValue)|\(key.rawValue)"
                let expected = table[id]

                var machine = makeMachine(seed)
                let before = machine.state
                let outcome = machine.handle(event(key), now: now)
                checked += 1

                if let expected {
                    legalChecked += 1
                    XCTAssertTrue(outcome.accepted, "合法迁移被拒绝：\(id)")
                    XCTAssertEqual(label(outcome.state), expected, "目标状态不符：\(id)")
                } else {
                    XCTAssertFalse(outcome.accepted, "非法迁移被接受：\(id)")
                    XCTAssertEqual(outcome.state, before, "非法迁移改变了状态：\(id)")
                    XCTAssertTrue(outcome.effects.isEmpty, "非法迁移产生了 effect：\(id)")
                }
            }
        }

        XCTAssertEqual(checked, 9 * 17, "矩阵覆盖的组合数不对")
        XCTAssertEqual(legalChecked, table.count, "合法表存在未被覆盖的条目")
    }

    private func label(_ state: PlaybackState) -> String {
        switch state {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .playing: return "playing"
        case .paused: return "paused"
        case .buffering: return "buffering"
        case .seeking: return "seeking"
        case .ended: return "ended"
        case .failed: return "failed"
        }
    }

    // MARK: - 装载与首帧

    func testLoadEmitsOrderedEffects() {
        var machine = PlaybackStateMachine(now: now)
        let outcome = machine.handle(.load(track, autoplay: true), now: now)

        XCTAssertEqual(outcome.effects, [
            .cancelLoading,
            .releaseAudio,
            .publish(.preparing(machine.context)),
            .beginLoading(trackID: track.id, startAt: 0, delay: .zero),
        ])
    }

    func testResourceReadyAutoplayEntersPlaying() {
        var machine = PlaybackStateMachine(now: now)
        _ = machine.handle(.load(track, autoplay: true), now: now)
        let outcome = machine.handle(.resourceReady(duration: 180), now: now)

        XCTAssertEqual(label(outcome.state), "playing")
        XCTAssertEqual(outcome.effects.last, .playAudio)
        XCTAssertEqual(machine.context.duration, 180)
    }

    func testResourceReadyWithoutAutoplayStopsAtReady() {
        var machine = PlaybackStateMachine(now: now)
        _ = machine.handle(.load(track, autoplay: false), now: now)
        let outcome = machine.handle(.resourceReady(duration: 180), now: now)

        XCTAssertEqual(label(outcome.state), "ready")
        XCTAssertFalse(outcome.effects.contains(.playAudio))
    }

    // MARK: - Seek 往返

    func testSeekFromPlayingReturnsToPlaying() {
        var machine = makeMachine(.playing)
        _ = machine.handle(.seek(60), now: now)
        XCTAssertEqual(label(machine.state), "seeking")

        let outcome = machine.handle(.seekFinished(60), now: now)
        XCTAssertEqual(label(outcome.state), "playing")
    }

    func testSeekFromPausedReturnsToPaused() {
        var machine = makeMachine(.paused)
        _ = machine.handle(.seek(60), now: now)

        let outcome = machine.handle(.seekFinished(60), now: now)
        XCTAssertEqual(label(outcome.state), "paused")
        XCTAssertEqual(outcome.state.pauseReason, .user)
    }

    // MARK: - 系统中断

    func testInterruptionPausesAndAutoResumes() {
        var machine = makeMachine(.playing)
        _ = machine.handle(.systemInterrupted, now: now)
        XCTAssertEqual(machine.state.pauseReason, .interruption)

        let outcome = machine.handle(.systemResumed(shouldResume: true), now: now)
        XCTAssertEqual(label(outcome.state), "playing")
    }

    func testUserPauseIsNotAutoResumed() {
        var machine = makeMachine(.paused)
        let outcome = machine.handle(.systemResumed(shouldResume: true), now: now)
        XCTAssertFalse(outcome.accepted)
        XCTAssertEqual(label(outcome.state), "paused")
    }

    // MARK: - 失败与重试

    func testRetryEscalatesThenGivesUp() {
        var machine = makeMachine(.failed)

        let first = machine.handle(.retry, now: now)
        XCTAssertEqual(label(first.state), "preparing")
        XCTAssertEqual(machine.context.retryCount, 1)
        XCTAssertEqual(first.effects.last, .beginLoading(trackID: track.id, startAt: 0, delay: .milliseconds(400)))

        _ = machine.handle(.loadFailed(.decodeFailed(reason: "2")), now: now)
        _ = machine.handle(.retry, now: now)
        XCTAssertEqual(machine.context.retryCount, 2)

        _ = machine.handle(.loadFailed(.decodeFailed(reason: "3")), now: now)
        let third = machine.handle(.retry, now: now)
        XCTAssertFalse(third.accepted)
        XCTAssertEqual(label(third.state), "failed")
        XCTAssertTrue(third.effects.contains(.requestNeighbor(.next)))
    }

    func testCancellationNeverEntersFailed() {
        var machine = makeMachine(.preparing)
        let outcome = machine.handle(.loadFailed(.cancelled), now: now)

        XCTAssertFalse(outcome.accepted)
        XCTAssertEqual(label(outcome.state), "preparing")
        XCTAssertNil(outcome.state.error)
    }

    func testUnsupportedFormatDegradesToNext() {
        var machine = makeMachine(.playing)
        _ = machine.handle(.playbackFailed(.unsupportedFormat(.flac)), now: now)
        let outcome = machine.handle(.retry, now: now)

        XCTAssertEqual(label(outcome.state), "preparing")
        XCTAssertTrue(outcome.effects.contains(.requestNeighbor(.next)))
    }

    // MARK: - 进度锚点

    func testPositionDerivedFromAnchor() {
        let clock = ContinuousClock()
        let start = clock.now
        let anchor = PositionAnchor.anchored(at: 12, now: start, rate: 1)
        XCTAssertEqual(anchor.position(at: start.advanced(by: .seconds(90))), 102, accuracy: 0.001)

        let paused = anchor.rebased(at: start.advanced(by: .seconds(30)), rate: 0)
        XCTAssertEqual(paused.position(at: start.advanced(by: .seconds(300))), 42, accuracy: 0.001)
    }

    func testPauseEventFreezesPosition() {
        var machine = makeMachine(.playing)
        let pauseAt = machine.context.clampedPosition(at: now)
        _ = machine.handle(.pause(.user), now: now)
        XCTAssertEqual(machine.context.clampedPosition(at: now), pauseAt, accuracy: 0.5)
    }
}
