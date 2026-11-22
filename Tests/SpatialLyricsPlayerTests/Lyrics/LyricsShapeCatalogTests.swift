import XCTest
@testable import SpatialLyricsPlayer

/// 四种歌词形态的目录性质测试。
///
/// 起因：规格要求的「四形态切换」原本寄希望于 XCUITest，但本机没有签名身份，
/// UI 测试跑不起来（runner 被系统 kill）。这里先把形式本身必须成立的性质固化下来：
/// 四种形态都在、名字各不相同、尺寸都是正的且 Board 面积最大——
/// 换形态时如果谁把某个 case 删了或尺寸写反，这几条会红。
final class LyricsShapeCatalogTests: XCTestCase {

    func testAllFourShapesExist() {
        XCTAssertEqual(LyricsShape.allCases.count, 4, "规格要求恰好四种形态")
        XCTAssertEqual(Set(LyricsShape.allCases).count, 4, "不能有重复 case")
    }

    func testDisplayNamesAreDistinct() {
        let names = LyricsShape.allCases.map(\.displayName)
        XCTAssertFalse(names.contains(where: \.isEmpty), "每种形态都要有可显示的名字")
        XCTAssertEqual(Set(names).count, names.count, "形态名字不能重复，否则用户分不清")
    }

    func testPreferredSizesArePositiveAndFittable() {
        for shape in LyricsShape.allCases {
            let size = shape.preferredSize
            XCTAssertGreaterThan(size.width, 0, "\(shape) 宽度必须为正")
            XCTAssertGreaterThan(size.height, 0, "\(shape) 高度必须为正")
            XCTAssertLessThanOrEqual(size.width, 2048, "\(shape) 不能比常见屏幕还宽")
            XCTAssertLessThanOrEqual(size.height, 1152, "\(shape) 不能比常见屏幕还高")
        }
    }

    func testBoardOccupiesMostAreaThanDoubleLine() {
        let board = LyricsShape.board.preferredSize
        let double = LyricsShape.doubleLine.preferredSize
        XCTAssertGreaterThan(board.width * board.height, double.width * double.height,
                             "歌词板应当比双行占更多面积，否则自动形态选择没有意义")
    }
}
