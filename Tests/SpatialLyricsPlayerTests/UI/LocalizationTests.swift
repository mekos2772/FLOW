import XCTest
@testable import SpatialLyricsPlayer

/// 验证 App 包真的带了中英两套资源，并且英文表里有正确译文。
/// 只检查文件存在是不够的——这里直接读 en.lproj 里的键值。
final class LocalizationTests: XCTestCase {

    func testBundleShipsChineseAndEnglish() {
        let localizations = Set(Bundle.main.localizations)
        XCTAssertTrue(localizations.contains("en"), "缺少英文资源")
        XCTAssertTrue(localizations.contains("zh-Hans"), "缺少简体中文资源")
    }

    func testEnglishCatalogContainsCoreTranslations() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"),
            "找不到 en.lproj/Localizable.strings"
        )
        let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])

        XCTAssertEqual(table["正在播放"], "Now Playing")
        XCTAssertEqual(table["队列"], "Queue")
        XCTAssertEqual(table["收藏"], "Favorites")
        XCTAssertEqual(table["歌词板"], "Board")
        XCTAssertGreaterThan(table.count, 60, "英文词条过少，说明目录没生效")

        // 新增的用户可见字符串必须同步进表，否则英文用户在设置页会看到中文。
        XCTAssertEqual(table["恢复默认布局"], "Reset layout")
        XCTAssertEqual(table["清除记住的位置与形态，并回到默认形态。"],
                       "Forgets the saved position and shape, then returns to the default shape.")
    }

    func testChineseCatalogKeepsSourceStrings() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "zh-Hans")
        )
        let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        XCTAssertEqual(table["正在播放"], "正在播放")
    }
}
