import XCTest
@testable import SpatialLyricsPlayer

/// 外部歌词：候选排序、LRC 转换、缓存。
///
/// 排序是这里最容易出错的部分——B 站标题带 `- Live`、`【4K】`、`Cover`，
/// 歌词库里的标题是纯歌名，完全相等会漏掉大部分能用的候选。
@MainActor
final class BiliExternalLyricsRankTests: XCTestCase {

    private func candidate(_ id: Int, _ name: String, _ artist: String,
                           duration: Double = 229, synced: String? = "[00:01.00] x") -> LRCLIBSource.Candidate {
        LRCLIBSource.Candidate(id: id, trackName: name, artistName: artist,
                               albumName: "", duration: duration, syncedLyrics: synced)
    }

    func testPrefersSyncedOverPlain() {
        let ranked = LRCLIBSource.rank(
            [candidate(1, "夜曲", "周杰伦", synced: nil),
             candidate(2, "夜曲", "周杰伦")],
            title: "夜曲", artist: "周杰伦", duration: 231)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.id, 2, "只有纯文本的候选不该胜出")
    }

    func testExactTitleAndArtistWins() {
        let ranked = LRCLIBSource.rank(
            [candidate(1, "夜曲 (Live)", "某翻唱", duration: 240),
             candidate(2, "夜曲", "周杰伦", duration: 229)],
            title: "夜曲", artist: "周杰伦", duration: 231)
        XCTAssertEqual(ranked.first?.id, 2)
    }

    func testDurationBreaksTie() {
        let ranked = LRCLIBSource.rank(
            [candidate(1, "夜曲", "周杰伦", duration: 400),
             candidate(2, "夜曲", "周杰伦", duration: 230)],
            title: "夜曲", artist: "周杰伦", duration: 231)
        XCTAssertEqual(ranked.first?.id, 2, "时长更接近的排在前面")
    }

    func testEmptyWhenNothingSynced() {
        let ranked = LRCLIBSource.rank(
            [candidate(1, "夜曲", "周杰伦", synced: nil)],
            title: "夜曲", artist: "周杰伦", duration: 231)
        XCTAssertTrue(ranked.isEmpty)
    }

    func testLimitRespected() {
        let many = (0..<20).map { candidate($0, "歌", "人") }
        XCTAssertEqual(LRCLIBSource.rank(many, title: "歌", artist: "人", duration: nil, limit: 3).count, 3)
    }

    // MARK: - 标题信号门槛

    /// 只有时长沾边、标题完全无关的候选必须被挡掉。
    ///
    /// 之前只过滤 `hasSynced`：一首 4 分钟的曲子会把一堆"也刚好 4 分钟"的同步歌词
    /// 当成自己的歌词——"配上了但全错"比"没有歌词"更糟。
    func testUnrelatedTitleIsRejectedEvenIfSynced() {
        let ranked = LRCLIBSource.rank(
            [candidate(9, "完全不同的歌", "别的歌手", duration: 231)],
            title: "夜曲", artist: "周杰伦", duration: 231)
        XCTAssertTrue(ranked.isEmpty, "标题无关的候选不该被当成这首歌的歌词")
    }

    /// 标题相同、歌手不同（翻唱/UP 主名）仍要收：B 站标题里的歌手位常常不是原唱。
    func testSameTitleDifferentArtistStillAccepted() {
        let ranked = LRCLIBSource.rank(
            [candidate(3, "不潮不用花钱", "林俊杰", duration: 185)],
            title: "不潮不用花钱", artist: "黄霄雲", duration: 182)
        XCTAssertEqual(ranked.first?.id, 3)
    }

    /// 时长差了半分钟以上的不自动采用：那是另一个版本（现场 / 加长 / Remix），
    /// 它的时间轴套不上这条音频——"配上了但全程错位"比"没有歌词"更糟。
    func testIncompatibleDurationIsNotAutoMatched() {
        let studio = candidate(3, "不潮不用花钱", "林俊杰", duration: 229)
        XCTAssertTrue(LRCLIBSource.rank([studio], title: "不潮不用花钱", artist: "黄霄雲",
                                        duration: 182).isEmpty)
        // 手动「换一版」的清单里仍然要有它：挑哪一版由用户决定。
        XCTAssertEqual(LRCLIBSource.rank([studio], title: "不潮不用花钱", artist: "黄霄雲",
                                         duration: 182, requiresCompatibleDuration: false).first?.id, 3)
    }

    /// 只给歌名查询时同名歌很多：排序必须看歌手，不能按库里的 id 先后随便拿一个。
    func testKnownArtistDecidesBetweenSameTitledSongs() {
        let ranked = LRCLIBSource.rank(
            [candidate(5, "Stay", "Zedd", duration: 225), candidate(9, "Stay", "Rihanna", duration: 225)],
            title: "Stay", artist: "Rihanna", duration: 225)
        XCTAssertEqual(ranked.first?.id, 9)
    }
}

@MainActor
final class LyricDocumentCacheTests: XCTestCase {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testStoreAndLoad() {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LyricDocumentCache(directory: directory)
        cache.store(identity: "BV1xx#p2", title: "夜曲", lrc: "[00:01.00] 测试")
        XCTAssertEqual(cache.load(identity: "BV1xx#p2", title: "夜曲"), "[00:01.00] 测试")
        XCTAssertNil(cache.load(identity: "BVother", title: "夜曲"))
    }

    func testIdentityWithSlashDoesNotEscapeDirectory() {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LyricDocumentCache(directory: directory)
        cache.store(identity: "a/b#p1", title: "x/y", lrc: "line")
        XCTAssertEqual(cache.count(), 1, "路径里的分隔符不能把文件写飞")
        XCTAssertEqual(cache.load(identity: "a/b#p1", title: "x/y"), "line")
    }

    func testClear() {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LyricDocumentCache(directory: directory)
        cache.store(identity: "a", title: "b", lrc: "x")
        cache.clear()
        XCTAssertEqual(cache.count(), 0)
    }
}

/// 真实歌词源验证（默认跳过）。
@MainActor
final class LRCLIBLiveTests: XCTestCase {

    func testFetchRealLyricsViaExternalAggregator() async throws {
        try LiveTestGate.skipUnlessLive("需要 /tmp/bili-live-test 且联网")
        let track = Track(sourceID: SourceID(rawValue: "remote"), externalID: "live-nocturne",
                          title: "夜曲", artist: "周杰伦", duration: 229)
        let aggregator = ExternalLyricsAggregator()
        let document = try await aggregator.resolve(for: track, allowNetwork: true)
        let lines = try XCTUnwrap(document?.lines)
        XCTAssertGreaterThan(lines.count, 10, "真实歌词应该有十几行以上")
        XCTAssertGreaterThan(lines.first?.start ?? 0, 0, "第一行不该是 0 秒")
    }
}

@MainActor
final class LyricTitleMatchingRegressionTests: XCTestCase {
    private let decoratedTitle = "【𝐇𝐢-𝐑𝐞𝐬·无损音质】《珊瑚海》-周杰伦/Lara梁心颐-“蔚蓝的珊瑚海，错过瞬间苍白”"

    override func setUp() {
        super.setUp()
        FakeBiliTransport.reset()
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-lyric-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func track() -> Track {
        Track(sourceID: SourceID("js-bilibili-fetch"), externalID: "coral-regression",
              title: decoratedTitle, artist: "视频投稿者", duration: 256)
    }

    func testBookTitleWinsOverFollowingArtistAndPromotionalText() {
        for raw in [decoratedTitle, "在专业录音棚听《珊瑚海》 - 周杰伦", "【4K顶级修复】《珊瑚海》—周杰伦 梁心颐 无损音质"] {
            XCTAssertEqual(LyricQueryNormalizer.parseTitle(raw).title, "珊瑚海", raw)
            let candidates = LyricQueryNormalizer.titleCandidates(raw)
            XCTAssertFalse(candidates.isEmpty)
            XCTAssertTrue(candidates.allSatisfy { $0.title == "珊瑚海" }, "书名号外的歌手不能成为备选歌名：\(candidates)")
        }
    }

    func testHyphenInsideExplicitSongTitleIsPreserved() {
        XCTAssertEqual(LyricQueryNormalizer.parseTitle("《Anti-Hero》-Taylor Swift【Official Audio】").title, "Anti-Hero")
        XCTAssertEqual(LyricQueryNormalizer.titleCandidates("《Anti-Hero》-Taylor Swift").first?.title, "Anti-Hero")
    }

    func testAutomaticSearchRejectsSwappedArtistAndSongMetadata() async throws {
        FakeBiliTransport.routes = [("lrclib.net", [[
            "id": 39138171, "trackName": "周杰伦", "artistName": "反方向的钟",
            "duration": 258.0, "syncedLyrics": "[00:01.00]另一首歌"
        ]])]
        let aggregator = ExternalLyricsAggregator(wordLevelLyrics: nil, lrclib: LRCLIBSource(session: FakeBiliTransport.makeSession()))
        let found = try await aggregator.searchRelaxed(title: decoratedTitle, artist: "视频投稿者", duration: 256)
        XCTAssertTrue(found.isEmpty, "时长接近也不能把歌手名当成歌名采用")
        XCTAssertFalse(FakeBiliTransport.requested.isEmpty)
        for request in FakeBiliTransport.requested {
            let components = URLComponents(string: request)
            XCTAssertEqual(components?.queryItems?.first { $0.name == "track_name" }?.value, "珊瑚海")
        }
    }

    func testRelaxedQueryKeepsTheOriginalSongTitleAsMatchTarget() async throws {
        FakeBiliTransport.routes = [("lrclib.net", [[
            "id": 2, "trackName": "Long", "artistName": "Other", "duration": 256.0,
            "syncedLyrics": "[00:01.00]another song"
        ]])]
        let aggregator = ExternalLyricsAggregator(wordLevelLyrics: nil, lrclib: LRCLIBSource(session: FakeBiliTransport.makeSession()))
        let found = try await aggregator.searchRelaxed(title: "Long Song With Many Words", artist: nil, duration: 256)
        XCTAssertTrue(found.isEmpty, "搜索缩短后的关键词不能取代完整歌名作为匹配标准")
    }

    func testOfflineFallbackDoesNotReuseLyricsCachedUnderAnUnrelatedTitle() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LyricDocumentCache(directory: directory)
        let current = track()
        let key = TrackIdentity.storageKey(current.identity)
        cache.store(identity: key, title: "周杰伦", lrc: "[00:01.00]另一首歌")
        let aggregator = ExternalLyricsAggregator(cache: cache, wordLevelLyrics: nil)
        let stale = await aggregator.cachedOfflineLyrics(for: current)
        XCTAssertNil(stale, "不能绕过歌名检查重新取回已失配的旧缓存")
        cache.store(identity: key, title: "珊瑚海", lrc: "[00:01.00]正确的歌词")
        let correct = await aggregator.cachedOfflineLyrics(for: current)
        XCTAssertEqual(correct?.lines.first?.text, "正确的歌词")
    }

    func testAutomaticMatchIsCachedWithTheCanonicalSongTitle() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        FakeBiliTransport.routes = [("lrclib.net", [[
            "id": 1, "trackName": "珊瑚海", "artistName": "周杰伦", "duration": 256.0,
            "syncedLyrics": "[00:01.00]正确的歌词"
        ]])]
        let cache = LyricDocumentCache(directory: directory)
        let current = track()
        let aggregator = ExternalLyricsAggregator(cache: cache, wordLevelLyrics: nil, lrclib: LRCLIBSource(session: FakeBiliTransport.makeSession()))
        let document = try await aggregator.resolve(for: current, allowNetwork: true)
        XCTAssertEqual(document?.lines.first?.text, "正确的歌词")
        XCTAssertNotNil(cache.load(identity: TrackIdentity.storageKey(current.identity), title: "珊瑚海"))
        XCTAssertNil(cache.load(identity: TrackIdentity.storageKey(current.identity), title: "周杰伦"))
    }

    func testLiveDecoratedSongTitleFindsCoralSeaInsteadOfTheReverseClock() async throws {
        try LiveTestGate.skipUnlessLive("真实 LRCLIB 歌名检索，需设置 SLP_LIVE_TEST=1")
        let aggregator = ExternalLyricsAggregator(wordLevelLyrics: nil)
        let found = try await aggregator.searchRelaxed(title: decoratedTitle, artist: nil, duration: 256)
        let candidate = try XCTUnwrap(found.first)
        XCTAssertEqual(LyricQueryNormalizer.normalize(candidate.trackName), "珊瑚海")
        XCTAssertFalse(candidate.syncedLyrics?.contains("ㄅㄆㄇㄈ") ?? true)
        print("Live lyric match: \(candidate.trackName) / \(candidate.artistName), id=\(candidate.id)")
    }
}
