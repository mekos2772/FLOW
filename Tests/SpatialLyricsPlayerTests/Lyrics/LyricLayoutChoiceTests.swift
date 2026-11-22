import XCTest
@testable import SpatialLyricsPlayer

/// 歌词版式的可选项与显示名。
///
/// 只有 16 行代码，但它是设置界面的数据源：少一档或名字串了，
/// 用户会直接看到（或者更糟：看到一个选不动的空项）。
final class LyricLayoutChoiceTests: XCTestCase {

    func testBothLayoutsAreSelectable() {
        XCTAssertEqual(LyricLayout.allCases.count, 2)
        XCTAssertTrue(LyricLayout.allCases.contains(.appleMusic))
        XCTAssertTrue(LyricLayout.allCases.contains(.editorial))
    }

    func testDisplayNamesAreDistinctAndNonEmpty() {
        let names = LyricLayout.allCases.map(\.displayName)
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(names).count, names.count, "两档版式不能重名，否则设置里分不清")
    }

    func testRawValuesAreStable() {
        // 原始值会进设置持久化，改了等于让老用户的偏好失效。
        XCTAssertEqual(LyricLayout.appleMusic.rawValue, "appleMusic")
        XCTAssertEqual(LyricLayout.editorial.rawValue, "editorial")
    }
}
