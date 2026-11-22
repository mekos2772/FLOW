import XCTest
@testable import SpatialLyricsPlayer

/// 队列不该被"点一下别的歌"或"补全一下标题"悄悄改掉。
///
/// 旧实现里 `load()` 与元信息补全都会 `queue.replace(...)`：用户拖好的顺序被还原、
/// 删掉的条目回来了、刚排的"下一首播放"被清空——而界面上没有任何提示。
@MainActor
final class QueueIntegrityTests: XCTestCase {

    func testPlayingAnotherQueueItemKeepsUserOrderAndManualQueue() async {
        let harness = EngineHarness()
        let t = harness.tracks
        harness.engine.setQueue(Array(t[0..<5]), current: t[0])
        await harness.engine.load(t[0], autoplay: true)

        harness.engine.moveQueueItem(from: 4, to: 1)            // 0 4 1 2 3
        XCTAssertTrue(harness.engine.removeQueueItem(at: 4))     // 0 4 1 2
        harness.engine.enqueueNext(t[7])

        // 用户在队列里点了另一首。
        await harness.engine.load(t[1], autoplay: true)

        let queue = harness.engine.queueSnapshot
        XCTAssertEqual(queue.items, [t[0].id, t[4].id, t[1].id, t[2].id],
                       "拖好的顺序和删掉的条目不能因为切歌被还原")
        XCTAssertEqual(queue.nextUp, [t[7].id], "手动排的「下一首播放」不能被清空")
        XCTAssertEqual(queue.currentID, t[1].id)
    }

    func testPlayingATrackOutsideTheQueueInsertsItAfterCurrent() async {
        let harness = EngineHarness()
        let t = harness.tracks
        harness.engine.setQueue(Array(t[0..<3]), current: t[0])
        await harness.engine.load(t[0], autoplay: true)

        await harness.engine.load(t[9], autoplay: true)

        XCTAssertEqual(harness.engine.queueSnapshot.items, [t[0].id, t[9].id, t[1].id, t[2].id],
                       "队列外的歌是插播：放完之后要能接着原来的顺序往下走")
    }

    /// 在长列表里把第 4 首设成"下一首播放"，播完它必须回到第 2 首，而不是跳到第 5 首。
    func testNextUpTrackTakenFromTheListDoesNotSkipTheRest() async {
        let harness = EngineHarness()
        let t = harness.tracks
        harness.engine.setQueue(Array(t[0..<5]), current: t[0])
        await harness.engine.load(t[0], autoplay: true)

        harness.engine.enqueueNext(t[3])
        await harness.engine.skip(.next)
        XCTAssertEqual(harness.engine.currentTrack?.identity, t[3].identity)

        await harness.engine.skip(.next)
        XCTAssertEqual(harness.engine.currentTrack?.identity, t[1].identity,
                       "插播的那首放完，要接着原本该播的下一首")
        await harness.engine.skip(.next)
        XCTAssertEqual(harness.engine.currentTrack?.identity, t[2].identity)
        await harness.engine.skip(.next)
        XCTAssertEqual(harness.engine.currentTrack?.identity, t[4].identity,
                       "已经提前播过的那首不该再出现一次")
    }

    func testEnqueueNextTwiceDoesNotPlayTheSongTwice() {
        var queue = PlaybackQueue(items: [UUID(), UUID()], currentID: nil)
        let extra = UUID()
        queue.enqueueNext(extra)
        queue.enqueueLater(extra)
        queue.enqueueNext(extra)
        XCTAssertEqual(queue.nextUp, [extra])
        XCTAssertTrue(queue.later.isEmpty, "同一首不能同时排在「下一首」和「稍后」里")
    }

    func testPeekingDoesNotAdvance() {
        let ids = [UUID(), UUID(), UUID()]
        let queue = PlaybackQueue(items: ids, currentID: ids[0])
        XCTAssertTrue(queue.hasNext)
        XCTAssertEqual(queue.peekNext, ids[1])
        XCTAssertEqual(queue.currentID, ids[0], "探路不能推进队列")

        let last = PlaybackQueue(items: ids, currentID: ids[2])
        XCTAssertFalse(last.hasNext, "顺序播放到最后一首就没有下一首了")
        var looping = last
        looping.repeatMode = .all
        XCTAssertTrue(looping.hasNext)
    }

    func testRestoredQueueKeepsManualBuffersAndDropsUnknownTracks() {
        let ids = [UUID(), UUID(), UUID()]
        let extra = UUID()
        let gone = UUID()
        var saved = PlaybackQueue(items: ids + [gone], currentID: ids[1], repeatMode: .all, shuffleSeed: 9)
        saved.enqueueNext(extra)
        saved.enqueueLater(gone)

        let restored = PlaybackQueue.restored(from: saved, keeping: Set(ids + [extra]))
        XCTAssertEqual(restored.items, ids)
        XCTAssertEqual(restored.nextUp, [extra], "重启不该丢掉用户排好的「下一首播放」")
        XCTAssertTrue(restored.later.isEmpty, "认不出的曲目要剔掉")
        XCTAssertEqual(restored.currentID, ids[1])
        XCTAssertEqual(restored.repeatMode, .all)
        XCTAssertEqual(restored.shuffleSeed, 9)
    }

    /// 队列的每一次改动都要广播：界面投影、持久化、控制中心都只认这条流。
    func testQueueEditsAreBroadcast() async {
        let harness = EngineHarness()
        let t = harness.tracks
        harness.engine.setQueue(Array(t[0..<4]), current: t[0])

        var received = 0
        let stream = harness.engine.stateUpdates()
        let listener = Task { @MainActor in
            for await _ in stream { received += 1 }
        }
        await waitUntil("订阅建立") { received >= 1 }
        let baseline = received

        harness.engine.enqueueNext(t[6])
        harness.engine.enqueueLater(t[7])
        harness.engine.moveQueueItem(from: 3, to: 1)
        XCTAssertTrue(harness.engine.clearUpNext())

        await waitUntil("四次改动都广播了") { received >= baseline + 4 }
        listener.cancel()
    }

    /// 元信息补全只换标题，不能顺手把队列重建一遍。
    func testMetadataRefreshDoesNotResetTheQueue() async {
        let rig = GatedEngine()
        let a = rig.source.track("a", title: "BV1placeholder")
        let b = rig.source.track("b")
        let c = rig.source.track("c")
        rig.source.setResolved(Track(id: a.id, sourceID: a.sourceID, externalID: "a",
                                     title: "真正的歌名", artist: "歌手", album: nil, duration: 200))
        rig.engine.setQueue([a, b], current: a)
        rig.engine.enqueueNext(c)

        await rig.engine.load(a, autoplay: true)
        await waitUntil("标题补全") { rig.engine.currentTrack?.title == "真正的歌名" }

        XCTAssertEqual(rig.engine.queueSnapshot.nextUp, [c.id], "补全标题不该清空「下一首播放」")
        XCTAssertEqual(rig.engine.queueSnapshot.items, [a.id, b.id])
        XCTAssertEqual(rig.engine.track(for: a.id)?.title, "真正的歌名",
                       "队列里那一份也要换成补全后的")
    }
}

/// 会话交接：音量要跟到新会话上，迟到的装载不能把正在播的那首弄没。
@MainActor
final class SessionHandoffTests: XCTestCase {

    func testNewSessionStartsAtTheUsersVolume() async {
        let rig = GatedEngine()
        let a = rig.source.track("a"), b = rig.source.track("b")
        rig.engine.setQueue([a, b], current: a)
        rig.engine.setVolume(0.3)

        await rig.engine.load(a, autoplay: true)
        XCTAssertEqual(rig.source.sessions(for: "a").last?.volumeWhenPlayStarted ?? -1, 0.3, accuracy: 0.001,
                       "第一首：调好的音量必须在出声之前就生效")

        await rig.engine.load(b, autoplay: true)
        XCTAssertEqual(rig.source.sessions(for: "b").last?.volumeWhenPlayStarted ?? -1, 0.3, accuracy: 0.001,
                       "切歌之后不能回到 100%")
    }

    func testMuteSurvivesATrackChange() async {
        let rig = GatedEngine()
        let a = rig.source.track("a"), b = rig.source.track("b")
        rig.engine.setQueue([a, b], current: a)
        await rig.engine.load(a, autoplay: true)
        rig.engine.toggleMute()

        await rig.engine.skip(.next)

        XCTAssertTrue(rig.engine.isMuted)
        XCTAssertEqual(rig.source.sessions(for: "b").last?.volumeWhenPlayStarted ?? -1, 0, accuracy: 0.001,
                       "静音着切到下一首，不能突然出声")
    }

    /// 先点的歌后下载完：它不能把后点的、正在响的那首作废掉。
    func testSlowEarlierLoadDoesNotKillTheNewerSession() async {
        let rig = GatedEngine()
        let a = rig.source.track("a"), b = rig.source.track("b")
        rig.engine.setQueue([a, b], current: a)
        rig.source.hold("a")

        let first = Task { await rig.engine.load(a, autoplay: true) }
        await waitUntil("A 开始取流") { rig.source.pendingCount == 1 }

        await rig.engine.load(b, autoplay: true)
        XCTAssertTrue(rig.engine.state.isPlaying)
        let playing = rig.source.sessions(for: "b").last

        await rig.source.release("a")
        await first.value

        XCTAssertEqual(rig.engine.currentTrack?.identity, b.identity)
        XCTAssertTrue(rig.engine.state.isPlaying)
        XCTAssertEqual(playing?.isInvalidated, false, "正在播的会话被迟到的装载作废了：界面在播，实际没声")
        XCTAssertEqual(playing?.isPlaying, true)
        XCTAssertEqual(rig.coordinator.session?.id, playing?.id)
        XCTAssertEqual(rig.source.sessions(for: "a").last?.isInvalidated, true, "迟到的那份要被清理掉")
    }

    func testStopWhileLoadingLeavesNoLiveSession() async {
        let rig = GatedEngine()
        let a = rig.source.track("a")
        rig.engine.setQueue([a], current: a)
        rig.source.hold("a")

        let first = Task { await rig.engine.load(a, autoplay: true) }
        await waitUntil("A 开始取流") { rig.source.pendingCount == 1 }
        await rig.engine.stop()
        await rig.source.release("a")
        await first.value

        XCTAssertTrue(rig.engine.state.isIdle)
        XCTAssertNil(rig.coordinator.session, "已经停了，迟到的会话不能再装上去")
        XCTAssertEqual(rig.source.sessions(for: "a").last?.isInvalidated, true)
        XCTAssertNotEqual(rig.source.sessions(for: "a").last?.isPlaying, true)
    }

    /// 失败的那一刻进度要冻住：没有声音，进度条不能自己往前走。
    func testFailureFreezesThePosition() {
        let clock = TestPlaybackClock()
        var machine = PlaybackStateMachine(now: clock.now)
        let track = Track.mock(externalID: "x", duration: 200)
        _ = machine.handle(.load(track, autoplay: true), now: clock.now)
        _ = machine.handle(.resourceReady(duration: 200), now: clock.now)
        clock.advance(by: .seconds(10))
        _ = machine.handle(.playbackFailed(.sourceUnavailable), now: clock.now)

        let atFailure = machine.state.context?.clampedPosition(at: clock.now) ?? -1
        clock.advance(by: .seconds(30))
        let later = machine.state.context?.clampedPosition(at: clock.now) ?? -1

        XCTAssertEqual(atFailure, 10, accuracy: 0.01)
        XCTAssertEqual(later, 10, accuracy: 0.01, "失败状态下进度还在走")
    }

    /// 播放键在任何状态下都要有意义：失败 = 再试一次，空闲但有队列 = 从队首开始。
    func testTogglePlaybackIsMeaningfulInEveryState() async {
        let rig = GatedEngine()
        let a = rig.source.track("a"), b = rig.source.track("b")
        rig.engine.setQueue([a, b], current: nil)

        XCTAssertTrue(rig.engine.hasPlayableContent)
        await rig.engine.togglePlayback()
        XCTAssertEqual(rig.engine.currentTrack?.identity, a.identity, "空闲但队列有东西：从队首开始")
        XCTAssertTrue(rig.engine.state.isPlaying)

        await rig.engine.togglePlayback()
        XCTAssertEqual(rig.engine.state.pauseReason, .user)
        await rig.engine.togglePlayback()
        XCTAssertTrue(rig.engine.state.isPlaying)

        rig.source.failNextPrepares(with: [.sourceUnavailable])
        await rig.engine.load(b, autoplay: true)
        XCTAssertNotNil(rig.engine.state.error)
        await rig.engine.togglePlayback()
        XCTAssertTrue(rig.engine.state.isPlaying, "失败之后按播放 = 重试，而不是一个没反应的按钮")
        XCTAssertEqual(rig.engine.currentTrack?.identity, b.identity)
    }
}

/// 自动恢复：失败之后要真的能恢复，而且不会无限重试。
@MainActor
final class RecoveryDriverTests: XCTestCase {

    private static let remoteID = SourceID(rawValue: "remote")

    func testRecoversByReloadingTheTrack() async {
        let rig = GatedEngine(sourceID: Self.remoteID)
        let a = rig.source.track("recover01")
        rig.engine.setQueue([a], current: a)
        let driver = PlaybackRecoveryDriver(playback: rig.engine,
                                            network: NetworkConnectivityMonitor(),
                                            clock: rig.clock)
        driver.start()
        defer { driver.stop() }

        rig.source.failNextPrepares(with: [.sourceUnavailable])
        await rig.engine.load(a, autoplay: true)

        await waitUntil("失败后自动恢复到播放") { rig.engine.state.isPlaying }
        XCTAssertEqual(rig.engine.currentTrack?.identity, a.identity)
        XCTAssertEqual(rig.source.sessions(for: "recover01").count, 2, "一次失败 + 一次成功的重装")
    }

    func testGivesUpInsteadOfRetryingForever() async {
        let rig = GatedEngine(sourceID: Self.remoteID)
        let a = rig.source.track("giveup001")
        rig.engine.setQueue([a], current: a)
        let driver = PlaybackRecoveryDriver(playback: rig.engine,
                                            network: NetworkConnectivityMonitor(),
                                            clock: rig.clock)
        driver.start()
        defer { driver.stop() }

        rig.source.failNextPrepares(with: Array(repeating: .sourceUnavailable, count: 50))
        await rig.engine.load(a, autoplay: true)

        await waitUntil("重试次数用尽") { driver.lastAction == "放弃重试" }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(rig.engine.state.error)
        XCTAssertEqual(rig.source.sessions(for: "giveup001").count, 4, "首次 + 三次重试，之后停手")
    }

    func testDoesNotRetryErrorsThatRetryingCannotFix() async {
        let rig = GatedEngine(sourceID: Self.remoteID)
        let a = rig.source.track("stopped01")
        rig.engine.setQueue([a], current: a)
        let driver = PlaybackRecoveryDriver(playback: rig.engine,
                                            network: NetworkConnectivityMonitor(),
                                            clock: rig.clock)
        driver.start()
        defer { driver.stop() }

        rig.source.failNextPrepares(with: [.rightsRestricted])
        await rig.engine.load(a, autoplay: true)
        await waitUntil("没权限：直接放弃") { driver.lastAction == "放弃重试" }
        XCTAssertEqual(rig.source.sessions(for: "stopped01").count, 1, "重试也没用的错误不该重试")
    }

    func testPolicyTreatsConnectivityAndTheOffSwitchDifferently() {
        XCTAssertEqual(PlaybackRecoveryPolicy.decide(attempt: 0, isOnline: true, error: .networkUnavailable),
                       .waitForNetwork)
        XCTAssertEqual(PlaybackRecoveryPolicy.decide(attempt: 0, isOnline: false, error: .networkDisabled), .giveUp,
                       "联网开关是用户自己关的：等多久都不会好")
        let monitor = NetworkConnectivityMonitor()
        monitor.noteFailure(.networkUnavailable)
        XCTAssertFalse(monitor.isOnline, "断网必须能被认出来")
        monitor.noteSuccess()
        XCTAssertTrue(monitor.isOnline)
    }
}

/// 联网开关关掉时，装载必须报"联网已关闭"而不是"暂时播不了"——
/// 前者引导用户去设置打开，后者只会被拿去 refetch 重试（必然再败）。
@MainActor
final class NetworkDisabledLoadTests: XCTestCase {

    func testUnregisteredSourceReportsNetworkDisabledWhenSwitchIsOff() async {
        let registry = SourceRegistry()
        let coordinator = PlaybackCoordinator(registry: registry)
        coordinator.isNetworkEnabled = { false }
        let track = Track(sourceID: SourceID(rawValue: "remote"), externalID: "id-1", title: "歌", artist: "手", duration: 180)

        do {
            _ = try await coordinator.beginLoading(track: track, startAt: 0)
            XCTFail("关网时装载不该成功")
        } catch let error as PlaybackError {
            XCTAssertEqual(error, .networkDisabled, "关网导致的源缺失要报 networkDisabled")
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testUnregisteredSourceReportsSourceUnavailableWhenSwitchIsOn() async {
        let registry = SourceRegistry()
        let coordinator = PlaybackCoordinator(registry: registry)
        coordinator.isNetworkEnabled = { true }
        let track = Track(sourceID: SourceID(rawValue: "remote"), externalID: "id-1", title: "歌", artist: "手", duration: 180)

        do {
            _ = try await coordinator.beginLoading(track: track, startAt: 0)
            XCTFail("源没注册时装载不该成功")
        } catch let error as PlaybackError {
            XCTAssertEqual(error, .sourceUnavailable, "源真的不存在才报 sourceUnavailable")
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }
}
