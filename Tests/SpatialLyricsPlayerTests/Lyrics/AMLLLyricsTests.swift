import XCTest
@testable import SpatialLyricsPlayer

// AMLL 逐词歌词源的全部契约：TTML 解析、索引匹配、真实索引抽样。
//
// 三个文件合并而来（AMLLTTMLParserTests / AMLLLyricsIndexTests / AMLLRealIndexTests）：
// 它们是同一条链路的三段，分散时很难看出"哪一段没覆盖"。

final class AMLLLyricsContractTests: XCTestCase {

/// AMLL 逐词 TTML 解析。

    /// 结构与 `amll-dev/amll-ttml-db` 的真实文件一致（截取前两行）。
    private let sample = """
    <tt xmlns="http://www.w3.org/ns/ttml"><head><metadata/></head><body dur="03:14.127">
    <div begin="00:00.820" end="03:14.127">
    <p begin="00:00.820" end="00:03.546"><span begin="00:00.820" end="00:00.914">Couldn</span><span begin="00:00.914" end="00:00.929">'</span><span begin="00:00.929" end="00:00.945">t</span><span begin="00:01.002" end="00:01.237">beat</span></p>
    <p begin="00:03.600" end="00:05.000"><span begin="00:03.600" end="00:04.000">第二句</span></p>
    </div></body></tt>
    """

    func testParsesLinesAndWordSegments() throws {
        let lines = AMLLTTMLParser.parse(sample)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "Couldn'tbeat")
        XCTAssertEqual(lines[0].segments.count, 4, "每个 span 是一段")
        XCTAssertEqual(try XCTUnwrap(lines[0].segments.first).start, 0.820, accuracy: 0.001)
        XCTAssertTrue(lines[0].hasWordTiming)
        XCTAssertEqual(lines[1].text, "第二句")
    }

    func testLineEndFallsBackToNextLine() throws {
        let lines = AMLLTTMLParser.parse(sample)
        XCTAssertEqual(try XCTUnwrap(lines[0].end), 3.546, accuracy: 0.001)
    }

    func testTimeCodeFormats() {
        XCTAssertEqual(AMLLTTMLParser.seconds("00:00.820") ?? -1, 0.820, accuracy: 0.001)
        XCTAssertEqual(AMLLTTMLParser.seconds("01:02.500") ?? -1, 62.5, accuracy: 0.001)
        XCTAssertEqual(AMLLTTMLParser.seconds("01:00:00.000") ?? -1, 3600, accuracy: 0.001)
        XCTAssertNil(AMLLTTMLParser.seconds(nil))
        XCTAssertNil(AMLLTTMLParser.seconds("abc"))
    }

    func testEmptyOrMalformedReturnsEmpty() {
        XCTAssertTrue(AMLLTTMLParser.parse("").isEmpty)
        XCTAssertTrue(AMLLTTMLParser.parse("<tt><body></body></tt>").isEmpty)
    }

    func testTTMLTraditionalIsConverted() {
        let xml = "<tt><body><div><p begin=\"00:01.000\"><span begin=\"00:01.000\">英雄主義</span></p></div></body></tt>"
        XCTAssertEqual(AMLLTTMLParser.parse(xml).first?.text, "英雄主义")
    }

    /// 译文不能混进正文。
    ///
    /// 实测 TTML 里译文是 `<span ttm:role="x-translation">`，第一版把它和原文摊在一起，
    /// 一行变成 `Couldn'tbeathersmile…她露出笑容吸引所有媒体的目光`。
    func testTranslationSpansAreExcluded() {
        let xml = """
        <tt><body><div><p begin="00:00.820" end="00:03.546"><span begin="00:00.820">beat</span><span begin="00:01.000">her</span><span ttm:role="x-translation" xml:lang="zh-CN">打动她</span></p></div></body></tt>
        """
        let lines = AMLLTTMLParser.parse(xml)
        XCTAssertEqual(lines.first?.text, "beather", "只保留正文，译文要拿掉")
        XCTAssertEqual(lines.first?.segments.count, 2)
    }

    func testBackgroundVocalSpansAreExcluded() {
        let xml = """
        <tt><body><div><p begin="00:01.000"><span begin="00:01.000">主唱</span><span ttm:role="x-bg"><span begin="00:01.500">和声</span></span></p></div></body></tt>
        """
        XCTAssertEqual(AMLLTTMLParser.parse(xml).first?.text, "主唱")
    }

/// AMLL 索引：JSONL 解析 + 按歌名/歌手挑一条。

    private func jsonl(_ rows: [(String, [String], String)]) -> Data {
        let lines = rows.map { name, artists, file -> String in
            let meta: [[Any]] = [["musicName", [name]], ["artists", artists]]
            let object: [String: Any] = ["metadata": meta, "rawLyricFile": file]
            let data = try! JSONSerialization.data(withJSONObject: object)
            return String(data: data, encoding: .utf8)!
        }
        return lines.joined(separator: "\n").data(using: .utf8)!
    }

    func testParsesIndex() {
        let index = AMLLLyricsIndex.parse(jsonl([("Idol", ["YOASOBI"], "a.ttml")]))
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entries[0].musicName, "Idol")
        XCTAssertEqual(index.entries[0].file, "a.ttml")
    }

    func testBadLineIsSkipped() {
        var data = jsonl([("夜曲", ["周杰伦"], "b.ttml")])
        data.append("\nnot json".data(using: .utf8)!)
        XCTAssertEqual(AMLLLyricsIndex.parse(data).entries.count, 1, "坏行不该毁掉整个索引")
    }

    func testExactTitleWins() {
        let index = AMLLLyricsIndex.parse(jsonl([
            ("夜曲", ["周杰伦"], "exact.ttml"),
            ("夜曲 2024 重制版", ["周杰伦"], "other.ttml"),
        ]))
        XCTAssertEqual(index.bestMatch(title: "夜曲", artist: "周杰伦")?.file, "exact.ttml")
    }

    func testGenericShortTitleDoesNotMatchLongerSong() {
        let index = AMLLLyricsIndex.parse(jsonl([("英雄联盟S16主题曲", ["某人"], "x.ttml")]))
        XCTAssertNil(index.bestMatch(title: "英雄", artist: nil),
                     "包含关系但长度差太远，不该认成同一首")
    }

    func testArtistBonusBreaksTie() {
        let index = AMLLLyricsIndex.parse(jsonl([
            ("Idol", ["Someone Else"], "a.ttml"),
            ("Idol", ["YOASOBI"], "b.ttml"),
        ]))
        XCTAssertEqual(index.bestMatch(title: "Idol", artist: "YOASOBI")?.file, "b.ttml")
    }

    func testTraditionalTitleStillMatches() {
        let index = AMLLLyricsIndex.parse(jsonl([("英雄主義", ["某人"], "t.ttml")]))
        XCTAssertNotNil(index.bestMatch(title: "英雄主义", artist: nil),
                        "繁体索引与简体标题应当能对上")
    }

/// 拿**真实**的 AMLL 索引验证匹配器。
///
/// 索引文件不在仓库里（1.7MB，且会更新）。测试前用：
/// `curl -sL https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/metadata/raw-lyrics-index.jsonl -o /tmp/amll.jsonl`
/// 没有文件时这条测试自动跳过——不把网络依赖塞进测试套件。

    private func loadIndex() throws -> AMLLLyricsIndex? {
        let url = URL(fileURLWithPath: "/tmp/amll.jsonl")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return AMLLLyricsIndex.parse(data)
    }

    func testRealIndexFindsKnownSong() throws {
        guard let index = try loadIndex() else {
            throw XCTSkip("没有 /tmp/amll.jsonl，跳过")
        }
        XCTAssertGreaterThan(index.entries.count, 1000, "索引应当有上千条")

        let hit = index.bestMatch(title: "Idol", artist: "YOASOBI")
        XCTAssertNotNil(hit, "真实索引里必须有 Idol / YOASOBI")
        XCTAssertTrue(hit?.file.hasSuffix(".ttml") == true)
    }

    func testRealIndexDoesNotMatchNonsense() throws {
        guard let index = try loadIndex() else {
            throw XCTSkip("没有 /tmp/amll.jsonl，跳过")
        }
        XCTAssertNil(index.bestMatch(title: "一首根本不存在的歌名xyz", artist: nil))
    }

    @MainActor
    func testProviderCachesTTMLToDiskAndServesOfflineWithoutNetwork() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-amll-ttml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let indexLine = #"{"metadata":[["musicName",["晴天"]],["artists",["周杰伦"]]],"rawLyricFile":"晴天 test.ttml"}"#
        try Data(indexLine.utf8).write(to: cacheDir.appendingPathComponent("amll-index.jsonl"))

        FakeBiliTransport.reset()
        FakeBiliTransport.routes = [
            ("amll-ttml-db/main/raw-lyrics/", Data(sample.utf8))
        ]
        let provider = AMLLLyricsProvider(session: FakeBiliTransport.makeSession(),
                                          allowsNetwork: true,
                                          cacheDirectory: cacheDir)

        let first = await provider.lyrics(title: "晴天", artist: "周杰伦", artistIsReliable: true, duration: 10)
        XCTAssertEqual(first?.count, 2)
        XCTAssertEqual(FakeBiliTransport.requested.count, 1, "首次应拉取一次 TTML 文件")

        // 清空路由并关闭联网后，二次读取必须直接命中本地 .ttml 缓存且不发网络请求。
        FakeBiliTransport.reset()
        let offlineProvider = AMLLLyricsProvider(session: FakeBiliTransport.makeSession(),
                                                 allowsNetwork: true,
                                                 cacheDirectory: cacheDir)
        let second = await offlineProvider.lyrics(title: "晴天", artist: "周杰伦",
                                                  artistIsReliable: true, duration: 10, allowNetwork: false)
        XCTAssertEqual(second?.count, 2)
        XCTAssertEqual(second?.first?.text, "Couldn'tbeat")
        XCTAssertTrue(FakeBiliTransport.requested.isEmpty, "二次播放与离线模式下不应重拉 GitHub Raw")
    }
}
