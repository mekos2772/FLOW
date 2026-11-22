import XCTest
@testable import SpatialLyricsPlayer

/// 睡眠定时器的剩余时间文案。
///
/// 这里原本自己拼 `mm:ss`，而下拉里**有 90 分钟这一档**：
/// 选中后剩余时间会显示成 `90:00`，正确的是 `1:30:00`。
/// 与 `DurationText.clock` 合并后，这类边界只在一个地方处理。
@MainActor
final class CountdownTextTests: XCTestCase {

    func testShortCountdown() {
        XCTAssertEqual(SettingsView.countdownText(.seconds(59)), "0:59")
        XCTAssertEqual(SettingsView.countdownText(.seconds(15 * 60)), "15:00")
    }

    /// 90 分钟档位：必须显示成 1:30:00。
    func testNinetyMinutesShowsHours() {
        XCTAssertEqual(SettingsView.countdownText(.seconds(90 * 60)), "1:30:00",
                       "睡眠定时器提供 90 分钟选项，不能显示成 90:00")
    }

    func testZeroAndNegativeAreClamped() {
        XCTAssertEqual(SettingsView.countdownText(.seconds(0)), "0:00")
        XCTAssertEqual(SettingsView.countdownText(.seconds(-30)), "0:00")
    }
}
