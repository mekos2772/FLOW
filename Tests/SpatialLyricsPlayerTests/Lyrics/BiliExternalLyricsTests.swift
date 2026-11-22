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
