import XCTest
@testable import SpatialLyricsPlayer

/// 小组件按钮 → 播放命令的映射。
///
/// 不调用 `perform()`：它会写进使用者的真实偏好。
/// 这里只验证映射本身——这类"复制粘贴忘改名"是最容易出的错，
/// 而错了的后果是"点下一首结果暂停了"。
final class WidgetIntentCommandTests: XCTestCase {

    func testToggleIntentSendsToggle() {
        XCTAssertEqual(TogglePlaybackIntent().command, .toggle)
    }

    func testNextIntentSendsNext() {
        XCTAssertEqual(NextTrackIntent().command, .next)
    }

    /// 两个按钮不能下发同一条命令。
    func testIntentsDoNotShareACommand() {
        XCTAssertNotEqual(TogglePlaybackIntent().command, NextTrackIntent().command)
    }

    /// 命令必须能被 `PlaybackCommand(rawValue:)` 还原——主 App 侧就是这么解析的。
    func testCommandsRoundTripThroughRawValue() {
        for command in [TogglePlaybackIntent().command, NextTrackIntent().command] {
            XCTAssertEqual(PlaybackCommand(rawValue: command.rawValue), command)
        }
    }
}
