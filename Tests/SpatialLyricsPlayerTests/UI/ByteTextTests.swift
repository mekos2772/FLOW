import XCTest
@testable import SpatialLyricsPlayer

/// 字节大小显示。
///
/// 之前两份完全相同的实现分散在设置页与账号页，都在视图里每次渲染新建
/// `ByteCountFormatter`。这里守住行为与"只有一个实现"这两件事。
final class ByteTextTests: XCTestCase {

    func testZeroBytes() {
        XCTAssertFalse(ByteText.size(0).isEmpty)
        XCTAssertTrue(ByteText.size(0).contains("0"), "0 字节也要显示成 0 开头")
    }

    func testKilobytesAndMegabytes() {
        XCTAssertTrue(ByteText.size(1024).uppercased().contains("KB"),
                      "1024 字节应当显示为 KB 量级：\(ByteText.size(1024))")
        XCTAssertTrue(ByteText.size(1024 * 1024).uppercased().contains("MB"),
                      "1MB 应当显示为 MB 量级：\(ByteText.size(1024 * 1024))")
    }

    func testNegativeIsRejected() {
        XCTAssertEqual(ByteText.size(-1), "—", "负数没有意义，不能显示成 -1 bytes")
    }

    func testLargeValueStillFormats() {
        let text = ByteText.size(500 * 1024 * 1024)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.uppercased().contains("MB") || text.uppercased().contains("GB"))
    }
}
