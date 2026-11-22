import AVFoundation
import Foundation
import XCTest
@testable import SpatialLyricsPlayer

/// 轮询等待异步条件成立（会话事件、驱动器都跑在各自的 Task 里）。
@MainActor
func waitUntil(_ description: String,
               timeout: TimeInterval = 3,
               file: StaticString = #filePath,
               line: UInt = #line,
               _ condition: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    let ok = await condition()
    XCTAssertTrue(ok, "等待超时：\(description)", file: file, line: line)
}

/// 可以被测试"按住不放"的闸门：`makeSession` 在闸门打开前不返回。
actor SessionGate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(open: Bool) { isOpen = open }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// 记录自己被怎么对待的会话：音量、是否播放过、是否已作废。
final class RecordingSession: PlaybackSession, @unchecked Sendable {
    let id = UUID()
    let duration: TimeInterval
    let capabilities: SessionCapabilities = .full
    let events: AsyncStream<SessionEvent>
    let trackExternalID: String

    private let lock = NSLock()
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private var _volume: Float = 1
    private var _volumeWhenPlayStarted: Float?
    private var _isInvalidated = false
    private var _isPlaying = false
    private var _prepareError: PlaybackError?
    private var _didMarkGaplessNext = false

    init(trackExternalID: String, duration: TimeInterval, prepareError: PlaybackError? = nil) {
        self.trackExternalID = trackExternalID
        self.duration = duration
        self._prepareError = prepareError
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = continuation
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var volume: Float { locked { _volume } }
    /// `play()` 第一次被调用那一刻的音量——"第一声有多响"。
    var volumeWhenPlayStarted: Float? { locked { _volumeWhenPlayStarted } }
    var isInvalidated: Bool { locked { _isInvalidated } }
    var isPlaying: Bool { locked { _isPlaying } }
    var didMarkGaplessNext: Bool { locked { _didMarkGaplessNext } }

    func prepare() async throws {
        if let error = locked({ _prepareError }) { throw error }
    }

    func play() async throws {
        locked {
            if _volumeWhenPlayStarted == nil { _volumeWhenPlayStarted = _volume }
            _isPlaying = true
        }
    }

    func pause() async { locked { _isPlaying = false } }
    func seek(to position: TimeInterval) async throws {}
    func setRate(_ rate: Double) async {}
    func setVolume(_ volume: Float) async { locked { _volume = volume } }

    func invalidate() async {
        locked {
            _isInvalidated = true
            _isPlaying = false
        }
        continuation.finish()
    }

    /// 模拟自然播完。
    func finish() { continuation.yield(.ended) }

    /// 模拟流式播放过程中的卡顿/恢复。
    func emitStall(_ stalled: Bool) { continuation.yield(.stalled(stalled)) }

    func markGaplessNext() async { locked { _didMarkGaplessNext = true } }
}

/// 建会话的时机由测试控制的源。可以冒充任意 `SourceID`（包括 B 站）。
final class GatedSource: PlaybackSourceProvider, @unchecked Sendable {
    let descriptor: SourceDescriptor
    private let lock = NSLock()
    private var gates: [String: SessionGate] = [:]
    private var created: [RecordingSession] = []
    private var pending = 0
    private var prepareErrors: [PlaybackError] = []
    private var resolved: [String: Track] = [:]

    init(id: SourceID = SourceID("gated")) {
        descriptor = SourceDescriptor(id: id, displayName: "闸门源", requiresNetwork: false,
                                      supportsSearch: false, supportsLyrics: false)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// 这首歌的 `makeSession` 先按住，直到 `release`。
    func hold(_ externalID: String) { locked { gates[externalID] = SessionGate(open: false) } }

    func release(_ externalID: String) async {
        let gate = locked { gates[externalID] }
        await gate?.open()
    }

    /// 接下来几次 `prepare()` 依次抛这些错（用完之后恢复正常）。
    func failNextPrepares(with errors: [PlaybackError]) { locked { prepareErrors = errors } }

    /// 让 `resolve` 给这首歌补上新的元信息。
    func setResolved(_ track: Track) { locked { resolved[track.externalID] = track } }

    var pendingCount: Int { locked { pending } }
    var sessions: [RecordingSession] { locked { created } }
    func sessions(for externalID: String) -> [RecordingSession] {
        locked { created.filter { $0.trackExternalID == externalID } }
    }

    func track(_ externalID: String, title: String? = nil, duration: TimeInterval = 180) -> Track {
        Track(sourceID: descriptor.id, externalID: externalID, title: title ?? externalID,
              artist: "", album: nil, duration: duration)
    }

    func search(_ request: SearchRequest) async throws -> [Track] { [] }

    func makeSession(for track: Track) async throws -> any PlaybackSession {
        let gate = locked { () -> SessionGate? in
            pending += 1
            return gates[track.externalID]
        }
        await gate?.wait()
        return locked {
            pending -= 1
            let error = prepareErrors.isEmpty ? nil : prepareErrors.removeFirst()
            let session = RecordingSession(trackExternalID: track.externalID,
                                           duration: track.duration, prepareError: error)
            created.append(session)
            return session
        }
    }

    func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession { session }
    func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
    func lyrics(for track: Track) async throws -> LyricsDocument? { nil }
    func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
    func resolve(_ track: Track) async -> Track? { locked { resolved[track.externalID] } }
}

/// 一套"引擎 + 闸门源"的装配。
@MainActor
struct GatedEngine {
    let clock = TestPlaybackClock()
    let source: GatedSource
    let coordinator: PlaybackCoordinator
    let engine: PlaybackEngine

    init(sourceID: SourceID = SourceID("gated")) {
        source = GatedSource(id: sourceID)
        let registry = SourceRegistry()
        registry.register(source)
        coordinator = PlaybackCoordinator(registry: registry)
        engine = PlaybackEngine(clock: clock, coordinator: coordinator)
    }
}

/// 测试用的音频样本。
///
/// 之前凡是要真正建 `BilibiliPlayerSession` 的测试，都去**使用者真实的缓存目录**里
/// 找一个 `.m4a` 当样本，找不到就跳过——在干净机器上这些测试从不运行。
/// 这里现场生成一段低幅噪声的 AAC（只用于装载/解码，从不出声）。
enum TestAudioFixture {
    struct GenerationFailed: Error {}

    static func makeM4A(in directory: URL, name: String = "fixture.m4a", seconds: Double = 8) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let sampleRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let frames = AVAudioFrameCount(sampleRate * seconds)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
                  let channels = buffer.floatChannelData else { throw GenerationFailed() }
            buffer.frameLength = frames
            var seed: UInt32 = 12_345
            for channel in 0..<Int(file.processingFormat.channelCount) {
                for index in 0..<Int(frames) {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    // 噪声而不是纯静音：静音会被编码器压到几 KB，过不了缓存的最小体积门槛。
                    channels[channel][index] = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.02
                }
            }
            try file.write(from: buffer)
        }
        return url
    }
}
