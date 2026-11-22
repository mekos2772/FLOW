import AVFoundation
import Foundation
import XCTest
@testable import SpatialLyricsPlayer

/// 边下边播（`ProgressiveAudioStream` + `StreamingResourceLoaderDelegate`）与无缝切歌（Gapless 预热）端到端测试。
final class StreamingAndGaplessTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        RangeMockProtocol.reset()
        FakeBiliTransport.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slp-streaming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        RangeMockProtocol.reset()
        FakeBiliTransport.reset()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - ByteRangeSet

    func testByteRangeSetMergesIntervalsAndQueriesMissingRanges() {
        var set = ByteRangeSet()
        set.insert(0..<100)
        set.insert(200..<300)
        set.insert(100..<200)
        XCTAssertEqual(set.ranges, [0..<300])
        XCTAssertEqual(set.availableLength(from: 50), 250)
        XCTAssertEqual(set.availableLength(from: 300), 0)

        set.insert(450..<500)
        XCTAssertEqual(set.nextMissingRange(from: 0, maxLength: 1000, totalLength: 600), 300..<450)
        XCTAssertFalse(set.isComplete(totalLength: 600))

        set.insert(300..<450)
        set.insert(500..<600)
        XCTAssertTrue(set.isComplete(totalLength: 600))
        XCTAssertNil(set.nextMissingRange(from: 0, maxLength: 100, totalLength: 600))
    }

    // MARK: - Progressive Range Streaming

    func testProgressiveStreamReturnsAfterFirstChunkAndCommitsFinalM4A() async throws {
        let totalSize = 96 * 1024
        let payload = Data((0..<totalSize).map { UInt8($0 & 0xFF) })
        let audioURL = URL(string: "https://range.test/stream-song.m4s")!
        RangeMockProtocol.payloads[audioURL.absoluteString] = payload
        RangeMockProtocol.nonInitialDelayNs = 80_000_000 // 后续分片延时 80ms，确保首片返回时尚未下完

        let cache = MediaAudioCache(
            directory: tempDir.appendingPathComponent("cache"),
            session: RangeMockProtocol.makeSession(),
            initialStreamChunkBytes: 16 * 1024,
            streamChunkBytes: 24 * 1024
        )
        let streamSpec = AudioStreamDescriptor(
            cacheKey: "remote::stream01",
            fileExtension: "m4s",
            qualityTier: .high,
            qualityID: 30280,
            codec: "AAC",
            bandwidth: 192_000,
            sampleRate: 48_000,
            isLossless: false,
            url: audioURL
        )

        let media = try await cache.openMedia(descriptor: streamSpec)
        guard case let .stream(progressive) = media else {
            return XCTFail("HTTP 206 分片响应应立刻进入边下边播状态")
        }

        XCTAssertFalse(progressive.isCompleted, "拿到首片就应立即返回，不阻塞等整首下完")
        XCTAssertEqual(progressive.totalLength, Int64(totalSize))
        XCTAssertEqual(progressive.readAvailable(offset: 0, maxLength: 128), payload.subdata(in: 0..<128))

        // 验证随机寻址：还没顺序下到尾部时可直接优先拉取靠近 EOF 的分片。
        progressive.ensureRangeRequested(offset: Int64(totalSize - 4096), length: 4096)
        await waitUntil("尾部分片先于全量完成到达") {
            progressive.readAvailable(offset: Int64(totalSize - 1024), maxLength: 1024).count == 1024
        }
        XCTAssertEqual(
            progressive.readAvailable(offset: Int64(totalSize - 1024), maxLength: 1024),
            payload.subdata(in: (totalSize - 1024)..<totalSize)
        )

        let completedURL = await progressive.waitForLocalFile()
        XCTAssertNotNil(completedURL)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(completedURL)), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: progressive.partURL.path), "完成后应清理 .part 临时文件")

        // 第二次打开应直接命中本地缓存，零 HTTP 请求。
        let beforeRequests = RangeMockProtocol.requests.count
        let second = try await cache.openMedia(descriptor: streamSpec)
        guard case .local = second else {
            return XCTFail("已完成落盘的流二次打开应直接返回本地文件")
        }
        XCTAssertEqual(RangeMockProtocol.requests.count, beforeRequests)
    }

    func testAbandoningMidStreamCleansUpPartFileWithoutCorruptingCache() async throws {
        let payload = Data(repeating: 0x5A, count: 96 * 1024)
        let audioURL = URL(string: "https://range.test/abort-song.m4s")!
        RangeMockProtocol.payloads[audioURL.absoluteString] = payload
        RangeMockProtocol.nonInitialDelayNs = 300_000_000

        let cache = MediaAudioCache(
            directory: tempDir.appendingPathComponent("cache-abort"),
            session: RangeMockProtocol.makeSession(),
            initialStreamChunkBytes: 16 * 1024,
            streamChunkBytes: 24 * 1024
        )
        let streamSpec = AudioStreamDescriptor(
            cacheKey: "remote::abort01",
            fileExtension: "m4s",
            qualityTier: .standard,
            qualityID: 30216,
            codec: "AAC",
            bandwidth: 64_000,
            sampleRate: 44_100,
            isLossless: false,
            url: audioURL
        )

        let media = try await cache.openMedia(descriptor: streamSpec)
        guard case let .stream(progressive) = media else {
            return XCTFail("期望进入流式模式")
        }
        let partPath = progressive.partURL.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: partPath))

        progressive.releaseConsumer()
        XCTAssertFalse(FileManager.default.fileExists(atPath: partPath), "唯一消费者释放后应立即清掉未完成的 .part 文件")
        let cached = await cache.cachedAudio(cacheKey: "remote::abort01", matching: nil)
        XCTAssertNil(cached, "未下完的流绝不能被认作完整本地缓存")
    }

    @MainActor
    func testStreamingResourceLoaderPreparesRealM4AOver206RangeResponses() async throws {
        let m4aURL = try TestAudioFixture.makeM4A(in: tempDir.appendingPathComponent("origin"), name: "range.m4a", seconds: 8)
        let m4aData = try Data(contentsOf: m4aURL)
        XCTAssertGreaterThan(m4aData.count, MediaAudioCache.minimumUsefulBytes)

        let remoteURL = URL(string: "https://range.test/real-m4a.m4s")!
        RangeMockProtocol.payloads[remoteURL.absoluteString] = m4aData
        RangeMockProtocol.nonInitialDelayNs = 15_000_000

        let cache = MediaAudioCache(
            directory: tempDir.appendingPathComponent("cache-m4a"),
            session: RangeMockProtocol.makeSession(),
            initialStreamChunkBytes: 16 * 1024,
            streamChunkBytes: 32 * 1024
        )
        let streamSpec = AudioStreamDescriptor(
            cacheKey: "remote::realm4a",
            fileExtension: "m4s",
            qualityTier: .high,
            qualityID: 30280,
            codec: "AAC",
            bandwidth: 192_000,
            sampleRate: 48_000,
            isLossless: false,
            url: remoteURL
        )

        let media = try await cache.openMedia(descriptor: streamSpec)
        guard case let .stream(progressive) = media else {
            return XCTFail("大过首片的 M4A 应进入流式 ResourceLoader 模式")
        }

        let session = try HTTPStreamPlayerSession(
            stream: streamSpec,
            media: .stream(progressive),
            title: "stream-m4a",
            cacheKey: streamSpec.cacheKey,
            streamingAssetBuilder: StreamingResourceLoaderBridge.makeAsset
        )
        try await session.prepare()
        XCTAssertGreaterThan(session.duration, 1, "AVURLAsset + StreamingResourceLoaderDelegate 必须能解出完整时长")
        await session.invalidate()
    }

    // MARK: - Gapless Prewarm & Promotion

    @MainActor
    func testGaplessPrewarmPromotesNextTrackAndSkipsDuplicateSessionCreation() async throws {
        let source = GaplessSpySource()
        let registry = SourceRegistry()
        registry.register(source)
        let coordinator = PlaybackCoordinator(registry: registry)
        let engine = PlaybackEngine(clock: TestPlaybackClock(), coordinator: coordinator)

        let t1 = source.track("BV1g01")
        let t2 = source.track("BV1g02")
        let t3 = source.track("BV1g03")
        engine.setQueue([t1, t2, t3], current: t1)

        await engine.load(t1, autoplay: true)
        XCTAssertTrue(engine.state.isPlaying)
        XCTAssertEqual(source.makeSessionCount, 1)

        // 进入 playing 后后台自动预热第 2 首，且不提前触达 noteSessionPromoted。
        await waitUntil("第 2 首完成预热待命") { coordinator.prewarmedTrackID == t2.id }
        XCTAssertEqual(source.makePrewarmCount, 1)
        XCTAssertEqual(source.promotedIDs, [])

        // 第 1 首自然播完 -> 自动无缝切至已预热的第 2 首。
        let firstSession = try XCTUnwrap(source.session(for: "BV1g01"))
        firstSession.finish()

        await waitUntil("无缝切换至第 2 首并在播") {
            engine.currentTrack?.id == t2.id && engine.state.isPlaying
        }
        XCTAssertEqual(coordinator.standbyHitCount, 1)
        XCTAssertTrue(coordinator.lastLoadWasGaplessHit)
        XCTAssertEqual(source.promotedIDs, ["BV1g02"])
        XCTAssertEqual(source.makeSessionCount, 1, "第 2 首走的是预热晋升，不该重复调 makeSession")
        XCTAssertTrue(try XCTUnwrap(source.session(for: "BV1g02")).didMarkGaplessNext)

        // 紧接着第 3 首也开始预热；切到单曲循环时必须撤下多余预热。
        await waitUntil("第 3 首完成预热") { coordinator.prewarmedTrackID == t3.id }
        engine.setRepeatMode(.one)
        XCTAssertNil(coordinator.prewarmedTrackID, "单曲循环时不应保留下一首待命会话")
    }

    @MainActor
    func testRemoteSourcePrewarmDefersStreamPickedUntilPromotion() async throws {
        let m4a = try Data(contentsOf: TestAudioFixture.makeM4A(in: tempDir.appendingPathComponent("remote-src")))
        let remoteURL = URL(string: "https://range.test/prewarm-high.m4a")!
        RangeMockProtocol.payloads[remoteURL.absoluteString] = m4a

        let picked = StreamBox()
        let cache = MediaAudioCache(directory: tempDir.appendingPathComponent("remote-cache"),
                                    session: RangeMockProtocol.makeSession())

        struct PrewarmRemoteSource: PlaybackSourceProvider {
            let descriptor = SourceDescriptor(id: SourceID(rawValue: "remote-prewarm"), displayName: "Remote", requiresNetwork: true)
            let url: URL
            let cache: MediaAudioCache
            let picked: StreamBox
            var supportsGaplessPrewarm: Bool { true }

            func search(_ request: SearchRequest) async throws -> [Track] { [] }
            func makeSession(for track: Track) async throws -> any PlaybackSession {
                try await createSession(for: track, reportPicked: true)
            }
            func makePrewarmSession(for track: Track) async throws -> any PlaybackSession {
                try await createSession(for: track, reportPicked: false)
            }
            func noteSessionPromoted(_ session: any PlaybackSession) {
                if let http = session as? HTTPStreamPlayerSession {
                    picked.set(http.stream)
                }
            }
            private func createSession(for track: Track, reportPicked: Bool) async throws -> any PlaybackSession {
                let desc = AudioStreamDescriptor(
                    cacheKey: TrackIdentity.storageKey(track.identity),
                    fileExtension: "m4a",
                    qualityTier: .high,
                    qualityID: 30280,
                    codec: "AAC",
                    bandwidth: 192_000,
                    sampleRate: 48_000,
                    isLossless: false,
                    url: url
                )
                if reportPicked { picked.set(desc) }
                let media = try await cache.openMedia(descriptor: desc)
                return try await MainActor.run {
                    try HTTPStreamPlayerSession(
                        stream: desc,
                        media: media,
                        title: track.title,
                        cacheKey: desc.cacheKey,
                        streamingAssetBuilder: StreamingResourceLoaderBridge.makeAsset
                    )
                }
            }
            func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession { session }
            func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
            func lyrics(for track: Track) async throws -> LyricsDocument? { nil }
            func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
        }

        let source = PrewarmRemoteSource(url: remoteURL, cache: cache, picked: picked)
        let registry = SourceRegistry()
        registry.register(source)
        let coordinator = PlaybackCoordinator(registry: registry)
        let nextTrack = Track(sourceID: source.descriptor.id, externalID: "prewarm1",
                              title: "下一首", artist: "", album: nil, duration: 8)

        coordinator.prewarm(track: nextTrack)
        await waitUntil("远端源预热就绪") { coordinator.prewarmedTrackID == nextTrack.id }
        XCTAssertNil(picked.value, "后台预热阶段绝不能提前改写'当前实际音质'")

        let duration = try await coordinator.beginLoading(track: nextTrack, startAt: 0, preferGaplessTransition: true)
        XCTAssertGreaterThan(duration, 1)
        XCTAssertEqual(coordinator.standbyHitCount, 1)
        XCTAssertEqual(picked.value?.qualityID, 30280, "晋升为当前播放会话时应立刻补报实际音质")
        await coordinator.teardown()
    }
}

// MARK: - Test Doubles

private final class StreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: AudioStreamDescriptor?
    var value: AudioStreamDescriptor? { lock.withLock { _value } }
    func set(_ stream: AudioStreamDescriptor) { lock.withLock { _value = stream } }
}

private final class RangeMockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var payloads: [String: Data] = [:]
    nonisolated(unsafe) static var requests: [String] = []
    nonisolated(unsafe) static var nonInitialDelayNs: UInt64 = 0

    static func reset() {
        payloads = [:]
        requests = []
        nonInitialDelayNs = 0
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RangeMockProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let data = Self.payloads[url.absoluteString] else {
            let err = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: err, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        Self.requests.append("\(url.absoluteString)|\(rangeHeader ?? "full")")

        if let rangeHeader, rangeHeader.hasPrefix("bytes="),
           let span = rangeHeader.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1) as [Substring]?,
           span.count == 2,
           let start = Int(span[0]),
           let rawEnd = Int(span[1]),
           start >= 0, start < data.count {
            let end = min(rawEnd, data.count - 1)
            let delay = start > 0 ? Self.nonInitialDelayNs : 0
            let respond = { [weak self] in
                guard let self else { return }
                let slice = data.subdata(in: start..<(end + 1))
                let headers = [
                    "Content-Range": "bytes \(start)-\(end)/\(data.count)",
                    "Accept-Ranges": "bytes",
                ]
                let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: slice)
                self.client?.urlProtocolDidFinishLoading(self)
            }
            if delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(delay)), execute: respond)
            } else {
                respond()
            }
            return
        }

        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class GaplessSpySource: PlaybackSourceProvider, @unchecked Sendable {
    let descriptor = SourceDescriptor(
        id: SourceID("gapless-spy"),
        displayName: "Gapless Spy",
        requiresNetwork: false,
        supportsSearch: false,
        supportsLyrics: false
    )
    let supportsGaplessPrewarm = true

    private let lock = NSLock()
    private var _makeSessionCount = 0
    private var _makePrewarmCount = 0
    private var _promotedIDs: [String] = []
    private var _sessions: [String: RecordingSession] = [:]

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var makeSessionCount: Int { locked { _makeSessionCount } }
    var makePrewarmCount: Int { locked { _makePrewarmCount } }
    var promotedIDs: [String] { locked { _promotedIDs } }
    func session(for externalID: String) -> RecordingSession? { locked { _sessions[externalID] } }

    func track(_ externalID: String) -> Track {
        Track(sourceID: descriptor.id, externalID: externalID, title: externalID, artist: "A", duration: 120)
    }

    func search(_ request: SearchRequest) async throws -> [Track] { [] }

    func makeSession(for track: Track) async throws -> any PlaybackSession {
        locked {
            _makeSessionCount += 1
            let s = RecordingSession(trackExternalID: track.externalID, duration: track.duration)
            _sessions[track.externalID] = s
            return s
        }
    }

    func makePrewarmSession(for track: Track) async throws -> any PlaybackSession {
        locked {
            _makePrewarmCount += 1
            let s = RecordingSession(trackExternalID: track.externalID, duration: track.duration)
            _sessions[track.externalID] = s
            return s
        }
    }

    func noteSessionPromoted(_ session: any PlaybackSession) {
        guard let rec = session as? RecordingSession else { return }
        locked { _promotedIDs.append(rec.trackExternalID) }
    }

    func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession { session }
    func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
    func lyrics(for track: Track) async throws -> LyricsDocument? { nil }
    func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
}
