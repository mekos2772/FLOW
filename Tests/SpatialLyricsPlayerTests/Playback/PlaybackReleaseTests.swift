import Foundation
import XCTest
@testable import SpatialLyricsPlayer

@MainActor
final class PlaybackReleaseTests: XCTestCase {
    func testSkipWaitingForTeardownCannotOverrideNewSelection() async {
        let gate = SessionGate(open: false)
        let rig = Rig(invalidationGate: gate)
        await rig.engine.load(rig.a, autoplay: true)
        let skip = Task { await rig.engine.skip(.next) }
        await waitUntil("旧会话正在释放") { rig.first.invalidating }
        await rig.engine.load(rig.c, autoplay: true)
        await gate.open()
        await skip.value
        XCTAssertEqual(rig.engine.currentTrack?.id, rig.c.id)
        XCTAssertTrue(rig.engine.state.isPlaying)
        XCTAssertEqual(rig.coordinator.session?.id, rig.third.id)
    }

    func testStopWhileSkipIsWaitingCannotRestartPlayback() async {
        let gate = SessionGate(open: false)
        let rig = Rig(invalidationGate: gate)
        await rig.engine.load(rig.a, autoplay: true)
        let skip = Task { await rig.engine.skip(.next) }
        await waitUntil("旧会话正在释放") { rig.first.invalidating }
        await rig.engine.stop()
        await gate.open()
        await skip.value
        XCTAssertTrue(rig.engine.state.isIdle)
        XCTAssertNil(rig.coordinator.session)
    }

    func testLateFailureDuringTeardownDoesNotFailNewLoad() async {
        let gate = SessionGate(open: false)
        let rig = Rig(invalidationGate: gate)
        await rig.engine.load(rig.a, autoplay: true)
        let next = Task { await rig.engine.load(rig.b, autoplay: true) }
        await waitUntil("旧会话正在释放") { rig.first.invalidating }
        rig.first.emit(.failed(.sourceUnavailable))
        // 给事件订阅机会消费旧失败；此时还没开始创建 B 的会话。
        for _ in 0..<20 { await Task.yield() }
        await gate.open()
        await next.value
        XCTAssertEqual(rig.engine.currentTrack?.id, rig.b.id)
        XCTAssertTrue(rig.engine.state.isPlaying)
    }

    func testCancelledLoadLeavesPreparingAndCanBePlayedAgain() async {
        let rig = GatedEngine()
        let a = rig.source.track("a")
        rig.source.hold("a")
        let load = Task { await rig.engine.load(a, autoplay: true) }
        await waitUntil("取流挂起") { rig.source.pendingCount == 1 }
        load.cancel()
        await rig.source.release("a")
        await load.value
        XCTAssertTrue(rig.engine.state.isIdle)
        XCTAssertNil(rig.coordinator.session)
        await rig.engine.load(a, autoplay: true)
        XCTAssertTrue(rig.engine.state.isPlaying)
    }

    func testSourceCancellationErrorDoesNotLeavePreparing() async {
        let rig = GatedEngine()
        rig.source.failNextPrepares(with: [.cancelled])
        await rig.engine.load(rig.source.track("a"), autoplay: true)
        XCTAssertTrue(rig.engine.state.isIdle)
        XCTAssertNil(rig.coordinator.session)
    }

    func testNaturalAdvanceDoesNotCancelNextPrepare() async {
        let rig = Rig()
        await rig.engine.load(rig.a, autoplay: true)
        rig.first.emit(.ended)
        await waitUntil("下一首真实检查取消后仍可播放") {
            rig.engine.currentTrack?.id == rig.b.id && rig.engine.state.isPlaying
        }
        XCTAssertEqual(rig.coordinator.session?.id, rig.second.id)
    }

    func testEndDuringSeekAdvancesAndOldSeekCannotUpdateNewTrack() async {
        let gate = SessionGate(open: false)
        let rig = Rig(seekGate: gate)
        await rig.engine.load(rig.a, autoplay: true)
        let seek = Task { await rig.engine.seek(to: 179) }
        await waitUntil("seek 挂起") { rig.first.seeking }
        rig.first.emit(.ended)
        await waitUntil("seek 期间播完仍自动切歌") {
            rig.engine.currentTrack?.id == rig.b.id && rig.engine.state.isPlaying
        }
        await gate.open()
        await seek.value
        XCTAssertEqual(rig.engine.currentTrack?.id, rig.b.id)
        XCTAssertEqual(rig.engine.currentPosition, 0, accuracy: 0.01)
    }

    func testRepeatOneStillAllowsManualNextAndNextUp() async {
        let rig = GatedEngine()
        let a = rig.source.track("a"), b = rig.source.track("b"), c = rig.source.track("c")
        rig.engine.setQueue([a, b], current: a)
        rig.engine.setRepeatMode(.one)
        await rig.engine.load(a, autoplay: true)
        rig.engine.enqueueNext(c)
        await rig.engine.skip(.next)
        XCTAssertEqual(rig.engine.currentTrack?.identity, c.identity)
        await rig.engine.skip(.next)
        XCTAssertEqual(rig.engine.currentTrack?.identity, b.identity)
        XCTAssertEqual(rig.engine.queueSnapshot.repeatMode, .one)
    }

    /// 「试听 AI 版」的实际机制：重载当前曲目，让协调器重新问一次音色会话工厂。
    func testSourceChangedReloadUsesVoiceSessionForCurrentTrack() async {
        let rig = Rig()
        await rig.engine.load(rig.a, autoplay: true)
        let voiceSession = ControlledSession()
        rig.coordinator.voiceSessionFactory = { _, _ in voiceSession }

        await rig.engine.dispatch(.sourceChanged(rig.a.sourceID))

        XCTAssertTrue(rig.engine.state.isPlaying)
        XCTAssertEqual(rig.coordinator.session?.id, voiceSession.id, "重载后应切到 AI 会话")
        XCTAssertEqual(rig.engine.currentTrack?.identity, rig.a.identity)
    }

    func testRepeatedSearchResultsShareOneQueueIdentity() async {
        let rig = GatedEngine()
        let original = rig.source.track("a")
        let duplicate = rig.source.track("a", title: "新版标题")
        rig.engine.setQueue([original, duplicate])
        await rig.engine.load(duplicate, autoplay: false)
        XCTAssertEqual(rig.engine.queueSnapshot.items, [original.id])
        XCTAssertEqual(rig.engine.currentTrack?.id, original.id)
        XCTAssertEqual(rig.engine.currentTrack?.title, "新版标题")
        rig.engine.enqueueNext(original)
        rig.engine.enqueueNext(duplicate)
        XCTAssertEqual(rig.engine.queueSnapshot.nextUp, [original.id])
    }

    func testMetadataRefreshPreservesIDWhenSourceReturnsNewUUID() async {
        let rig = GatedEngine()
        let a = rig.source.track("a", title: "占位")
        rig.source.setResolved(rig.source.track("a", title: "补全"))
        await rig.engine.load(a, autoplay: false)
        await waitUntil("标题更新") { rig.engine.currentTrack?.title == "补全" }
        await rig.engine.play()
        XCTAssertEqual(rig.engine.currentTrack?.id, a.id)
        XCTAssertEqual(rig.engine.currentTrack?.title, "补全")
        XCTAssertEqual(rig.engine.queueSnapshot.items, [a.id])
    }

    func testReplacingListWithoutCurrentPreservesPlayingTrack() async {
        let rig = GatedEngine()
        let a = rig.source.track("a"), b = rig.source.track("b")
        await rig.engine.load(a, autoplay: true)
        rig.engine.setQueue([b])
        XCTAssertEqual(rig.engine.queueSnapshot.currentID, a.id)
        XCTAssertTrue(rig.engine.queueSnapshot.items.contains(a.id))
        XCTAssertEqual(rig.engine.currentTrack?.identity, a.identity)
        XCTAssertTrue(rig.engine.state.isPlaying)
    }

    func testRestoringQueueCollapsesRepeatedStableIdentity() {
        let rig = GatedEngine()
        let a = rig.source.track("a"), copy = rig.source.track("a")
        let saved = PlaybackQueue(items: [a.id, copy.id], currentID: copy.id)
        rig.engine.restoreQueue(saved, tracks: [a, copy])
        XCTAssertEqual(rig.engine.queueSnapshot.items, [a.id])
        XCTAssertEqual(rig.engine.queueSnapshot.currentID, a.id)
    }

    @MainActor
    private struct Rig {
        let a: Track, b: Track, c: Track
        let first: ControlledSession, second: ControlledSession, third: ControlledSession
        let coordinator: PlaybackCoordinator
        let engine: PlaybackEngine
        init(invalidationGate: SessionGate? = nil, seekGate: SessionGate? = nil) {
            let sourceID = SourceID("release-races")
            a = Track(sourceID: sourceID, externalID: "a", title: "A", artist: "", duration: 180)
            b = Track(sourceID: sourceID, externalID: "b", title: "B", artist: "", duration: 180)
            c = Track(sourceID: sourceID, externalID: "c", title: "C", artist: "", duration: 180)
            first = ControlledSession(invalidationGate: invalidationGate, seekGate: seekGate)
            second = ControlledSession()
            third = ControlledSession()
            let registry = SourceRegistry()
            registry.register(ControlledSource(id: sourceID, sessions: ["a": first, "b": second, "c": third]))
            coordinator = PlaybackCoordinator(registry: registry)
            engine = PlaybackEngine(clock: TestPlaybackClock(), coordinator: coordinator)
            engine.setQueue([a, b, c])
        }
    }

    private struct ControlledSource: PlaybackSourceProvider {
        let descriptor: SourceDescriptor
        let sessions: [String: ControlledSession]
        init(id: SourceID, sessions: [String: ControlledSession]) {
            descriptor = SourceDescriptor(id: id, displayName: "Release", requiresNetwork: false)
            self.sessions = sessions
        }
        func search(_ request: SearchRequest) async throws -> [Track] { [] }
        func makeSession(for track: Track) async throws -> any PlaybackSession {
            guard let session = sessions[track.externalID] else { throw PlaybackError.sourceUnavailable }
            return session
        }
        func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession { session }
        func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
        func lyrics(for track: Track) async throws -> LyricsDocument? { nil }
        func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
    }

    private final class ControlledSession: PlaybackSession, @unchecked Sendable {
        let id = UUID()
        let duration: TimeInterval = 180
        let capabilities: SessionCapabilities = .full
        let events: AsyncStream<SessionEvent>
        private let sink: AsyncStream<SessionEvent>.Continuation
        private let invalidationGate: SessionGate?
        private let seekGate: SessionGate?
        private let lock = NSLock()
        private var isInvalidating = false
        private var isSeeking = false
        var invalidating: Bool { lock.withLock { isInvalidating } }
        var seeking: Bool { lock.withLock { isSeeking } }
        init(invalidationGate: SessionGate? = nil, seekGate: SessionGate? = nil) {
            (events, sink) = AsyncStream.makeStream()
            self.invalidationGate = invalidationGate
            self.seekGate = seekGate
        }
        func prepare() async throws { try Task.checkCancellation() }
        func play() async throws { try Task.checkCancellation() }
        func pause() async {}
        func seek(to position: TimeInterval) async throws {
            lock.withLock { isSeeking = true }
            await seekGate?.wait()
        }
        func setRate(_ rate: Double) async {}
        func setVolume(_ volume: Float) async {}
        func invalidate() async {
            lock.withLock { isInvalidating = true }
            await invalidationGate?.wait()
            sink.finish()
        }
        func emit(_ event: SessionEvent) { sink.yield(event) }
    }
}
