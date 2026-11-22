import XCTest
@testable import SpatialLyricsPlayer

/// 歌词偏移量的显示。
///
/// 两处界面原本各写了一遍同样的格式化（设置页、队列抽屉）。
/// 统一到 `DurationText.offset` 之后，这里把语义钉住：
/// 正负号必须显式、0 不带符号、非有限值不能显示成 `nan ms`。
final class OffsetTextTests: XCTestCase {

    func testZeroHasNoSign() {
        XCTAssertEqual(DurationText.offset(0), "0 ms")
    }

    func testPositiveHasPlusSign() {
        XCTAssertEqual(DurationText.offset(0.25), "+250 ms")
    }

    func testNegativeHasMinusSign() {
        XCTAssertEqual(DurationText.offset(-0.12), "-120 ms")
    }

    func testNonFiniteFallsBackToZero() {
        XCTAssertEqual(DurationText.offset(.nan), "0 ms")
        XCTAssertEqual(DurationText.offset(.infinity), "0 ms")
    }

    func testRoundingIsToNearestMillisecond() {
        XCTAssertEqual(DurationText.offset(0.0004), "0 ms")
        XCTAssertEqual(DurationText.offset(0.0006), "+1 ms")
    }

    /// 时钟格式与偏移格式都在同一个类型里，防止有人再建第三份实现。
    func testClockStillHandlesHoursAndInvalidValues() {
        XCTAssertEqual(DurationText.clock(3600), "1:00:00")
        XCTAssertEqual(DurationText.clock(-1), "--:--")
        XCTAssertEqual(DurationText.clock(.nan), "--:--")
    }
}
