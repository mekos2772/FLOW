import XCTest
@testable import SpatialLyricsPlayer

/// 繁→简归一。
///
/// 起因：B 站字幕与部分 LRC 是繁体，界面是简体，同一屏里"英雄主義"和"英雄主义"并存。
final class TextNormalizerTests: XCTestCase {

    func testTraditionalIsConverted() {
        XCTAssertEqual(TextNormalizer.simplified("英雄主義"), "英雄主义")
        XCTAssertEqual(TextNormalizer.simplified("願戴榮光墜入天淵"), "愿戴荣光坠入天渊")
    }

    func testSimplifiedIsUnchanged() {
        XCTAssertEqual(TextNormalizer.simplified("在虚无中永存"), "在虚无中永存")
    }

    func testLatinAndDigitsPassThrough() {
        XCTAssertEqual(TextNormalizer.simplified("Hello 2024"), "Hello 2024")
        XCTAssertEqual(TextNormalizer.simplified(""), "")
    }

    func testLyricLinesKeepCountAndBlanks() {
        let lines = ["第一句", "", "第二句"]
        XCTAssertEqual(TextNormalizer.simplified(lines: lines).count, 3)
        XCTAssertEqual(TextNormalizer.simplified(lines: lines)[1], "")
    }

    func testParserNormalizesLyricText() {
        let result = LRCParser.parse("""
        [ti:英雄主義]
        [ar:某樂隊]
        [00:01.00]願戴榮光墜入天淵
        """)
        XCTAssertEqual(result?.metadata.title, "英雄主义")
        XCTAssertEqual(result?.metadata.artist, "某乐队")
        XCTAssertEqual(result?.lines.first?.text, "愿戴荣光坠入天渊")
    }
}
