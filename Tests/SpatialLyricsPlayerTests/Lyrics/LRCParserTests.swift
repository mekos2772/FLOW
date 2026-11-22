import XCTest
@testable import SpatialLyricsPlayer

// LRC 解析的全部契约：普通 LRC、增强版逐字标签、行尾时间推导。

final class LRCParserTests: XCTestCase {

    func testBasicParse() throws {
        let text = """
        [00:12.34]第一行
        [00:15.00]第二行
        """
        let result = try XCTUnwrap(LRCParser.parse(text))
        XCTAssertEqual(result.synchronization, .synced)
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0].start, 12.34, accuracy: 0.001)
        XCTAssertEqual(result.lines[0].text, "第一行")
        XCTAssertEqual(result.lines[1].start, 15.0, accuracy: 0.001)
    }

    func testBOMAndCRLFAreHandled() throws {
        let text = "\u{FEFF}[00:01.00]A\r\n[00:02.00]B\r[00:03.00]C\n"
        let result = try XCTUnwrap(LRCParser.parse(text))
        XCTAssertEqual(result.lines.map(\.text), ["A", "B", "C"])
    }

    func testMultipleTimestampsOnOneLine() throws {
        let result = try XCTUnwrap(LRCParser.parse("[00:10.00][00:20.00]副歌"))
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines.map(\.text), ["副歌", "副歌"])
        XCTAssertEqual(result.lines[1].start, 20, accuracy: 0.001)
    }

    func testMetadataTags() throws {
        let text = """
        [ti:测试歌曲]
        [ar:测试歌手]
        [al:测试专辑]
        [by:作者]
        [offset:500]
        [00:10.00]正文
        """
        let result = try XCTUnwrap(LRCParser.parse(text))
        XCTAssertEqual(result.metadata.title, "测试歌曲")
        XCTAssertEqual(result.metadata.artist, "测试歌手")
        XCTAssertEqual(result.metadata.album, "测试专辑")
        XCTAssertEqual(result.metadata.author, "作者")
        XCTAssertEqual(result.metadata.offsetMilliseconds, 500)
        // offset 正数表示歌词提前 0.5s → 时间戳整体左移。
        XCTAssertEqual(result.lines[0].start, 9.5, accuracy: 0.001)
    }

    func testDuplicateTimestampKeepsFirstNonEmptyText() throws {
        let result = try XCTUnwrap(LRCParser.parse("[00:05.00]\n[00:05.00]真正的内容"))
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0].text, "真正的内容")
    }

    func testInvalidTimestampsAreDropped() throws {
        let result = try XCTUnwrap(LRCParser.parse("[99:99.00]坏的\n[00:05.00]好的"))
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0].text, "好的")
        XCTAssertGreaterThanOrEqual(result.droppedTagCount, 1)
    }

    func testPlainTextBecomesUnsynced() throws {
        let result = try XCTUnwrap(LRCParser.parse("第一句\n第二句\n第三句"))
        XCTAssertEqual(result.synchronization, .unsynced)
        XCTAssertEqual(result.lines.map(\.text), ["第一句", "第二句", "第三句"])
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(LRCParser.parse(""))
        XCTAssertNil(LRCParser.parse("\n\n\n"))
        XCTAssertNil(LRCParser.parse("[ti:只有元信息]"))
    }

    func testLinesAreSortedByTime() throws {
        let text = "[00:30.00]C\n[00:10.00]A\n[00:20.00]B"
        let result = try XCTUnwrap(LRCParser.parse(text))
        XCTAssertEqual(result.lines.map(\.text), ["A", "B", "C"])
    }

    func testVariousFractionDigits() throws {
        let result = try XCTUnwrap(LRCParser.parse("[00:01]A\n[00:02.5]B\n[00:03.25]C\n[00:04.125]D"))
        XCTAssertEqual(result.lines[0].start, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.lines[1].start, 2.5, accuracy: 0.0001)
        XCTAssertEqual(result.lines[2].start, 3.25, accuracy: 0.0001)
        XCTAssertEqual(result.lines[3].start, 4.125, accuracy: 0.0001)
    }

    func testInstrumentalGapLineIsPreserved() throws {
        let result = try XCTUnwrap(LRCParser.parse("[00:01.00]唱\n[00:05.00]\n[00:09.00]再唱"))
        XCTAssertEqual(result.lines.count, 3)
        XCTAssertTrue(result.lines[1].isEmpty)
    }

    // MARK: - 逐字时间轴（原 WordLevelLyricsTests）
    //
    // 增强版 LRC 用 `<mm:ss.xx>` 给行内每个词打点。解析到这里，
    // "整行高亮"与"逐字点亮"就只差视图那一层了。


/// 逐字时间轴（增强版 LRC / AMLL 那套"字一个个亮起来"）。

    func testParsesWordTagsAndKeepsPlainText() {
        let lrc = "[00:10.00]<00:10.00>第一<00:10.50>句<00:11.00>歌词"
        let result = LRCParser.parse(lrc)
        let line = try! XCTUnwrap(result?.lines.first)
        XCTAssertEqual(line.text, "第一句歌词", "正文要把词标签剥掉")
        XCTAssertTrue(line.hasWordTiming)
        XCTAssertEqual(line.segments.map(\.start), [10.0, 10.5, 11.0])
        XCTAssertEqual(line.segments.map(\.text), ["第一", "句", "歌词"])
    }

    func testPlainLRCStillHasNoWordTiming() {
        let result = LRCParser.parse("[00:10.00]没有任何词标签的一行")
        let line = try! XCTUnwrap(result?.lines.first)
        XCTAssertFalse(line.hasWordTiming, "普通 LRC 不该被当成逐字歌词")
        XCTAssertNil(line.filledFraction(at: 11))
    }

    func testFilledFractionGrowsMonotonically() throws {
        let line = LyricLine(start: 10, end: 13, text: "一二三四",
                             segments: [
                                LyricSegment(start: 10, text: "一"),
                                LyricSegment(start: 11, text: "二"),
                                LyricSegment(start: 12, text: "三"),
                                LyricSegment(start: 13, text: "四"),
                             ])
        let samples = [10.0, 10.5, 11.0, 12.0, 13.0].map { line.filledFraction(at: $0) ?? -1 }
        XCTAssertEqual(samples, samples.sorted(), "填充比例必须单调不减")
        XCTAssertEqual(samples.first ?? -1, 0, accuracy: 0.001, "行首还没唱")
        XCTAssertEqual(samples[1], 0.125, accuracy: 0.01, "第一段唱了一半：1/4 字 × 0.5")
        XCTAssertEqual(samples.last ?? -1, 1, "行尾应全部点亮")
    }

    func testLineEndComesFromNextLine() throws {
        let result = LRCParser.parse("""
        [00:10.00]第一行
        [00:14.00]第二行
        """)
        let lines = try XCTUnwrap(result?.lines)
        XCTAssertEqual(lines[0].end, 14.0, "行尾取下一行的开始，供逐字填充封顶")
        XCTAssertNil(lines[1].end)
    }
}
