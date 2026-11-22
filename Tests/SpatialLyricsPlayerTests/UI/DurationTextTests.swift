import XCTest
@testable import SpatialLyricsPlayer

/// 时长显示。
///
/// 两份重复实现都漏了"一小时以上"：3600 秒会显示 `60:00`。
/// B 站的直播回放、播客、DJ set 动辄一两个小时，这不是罕见情况。
final class DurationTextTests: XCTestCase {

    func testUnderOneHour() {
        XCTAssertEqual(DurationText.clock(0), "0:00")
        XCTAssertEqual(DurationText.clock(9), "0:09")
        XCTAssertEqual(DurationText.clock(59), "0:59")
        XCTAssertEqual(DurationText.clock(60), "1:00")
        XCTAssertEqual(DurationText.clock(252), "4:12")
        XCTAssertEqual(DurationText.clock(3599), "59:59")
    }

    func testOneHourAndBeyond() {
        XCTAssertEqual(DurationText.clock(3600), "1:00:00", "整一小时必须带小时位")
        XCTAssertEqual(DurationText.clock(3661), "1:01:01")
        XCTAssertEqual(DurationText.clock(7200), "2:00:00")
        XCTAssertEqual(DurationText.clock(3661.4), "1:01:01", "四舍五入到秒")
    }

    func testInvalidValues() {
        XCTAssertEqual(DurationText.clock(-1), "--:--")
        XCTAssertEqual(DurationText.clock(.nan), "--:--")
        XCTAssertEqual(DurationText.clock(.infinity), "--:--")
    }

    /// 两个调用点必须给出同一个结果（之前一份把 0 显示成 `0:00`，另一份 `--:--`）。
    func testBothCallSitesAgree() {
        for seconds in [0.0, 59, 252, 3600, 7200] {
            XCTAssertEqual(ExpandedPlayerView.format(seconds), DurationText.clock(seconds))
        }
    }
}
