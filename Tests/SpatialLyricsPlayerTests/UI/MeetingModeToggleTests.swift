import XCTest
@testable import SpatialLyricsPlayer

/// 会议模式：从"代码存在但无法启用"变成"能打开、能关掉"。
///
/// 规格 13.3 要求会议应用进前台时遮住歌名与歌词。策略和遮罩都写了，
/// 但没有内置清单、界面也没有地方填，`meetingAppsRaw` 永远是空串——
/// 这个功能**从未生效过**。
@MainActor
final class MeetingModeToggleTests: XCTestCase {

    private func makeState() -> (PrivacyState, InMemorySettingsStore) {
        let settings = InMemorySettingsStore()
        return (PrivacyState(settings: settings), settings)
    }

    func testDisabledByDefault() {
        let (state, _) = makeState()
        XCTAssertFalse(state.isMeetingModeEnabled, "隐私功能不能默认替用户打开")
        XCTAssertFalse(state.meetingPolicy.isEnabled)
    }

    func testEnablingUsesBuiltInList() async {
        let (state, settings) = makeState()
        state.setMeetingModeEnabled(true)
        // setMeetingApps 内部用 Task 写设置，等一拍
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(state.isMeetingModeEnabled)
        XCTAssertTrue(state.meetingPolicy.shouldMask(frontmostBundleID: "us.zoom.xos"),
                      "打开后应当能识别 Zoom")
        XCTAssertEqual(settings.meetingAppsRaw, state.meetingAppsRaw,
                       "开关要落盘，重启后仍然有效")
    }

    func testDisablingClearsList() async {
        let (state, _) = makeState()
        state.setMeetingModeEnabled(true)
        state.setMeetingModeEnabled(false)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(state.isMeetingModeEnabled)
        XCTAssertFalse(state.meetingPolicy.shouldMask(frontmostBundleID: "us.zoom.xos"))
    }

    /// 非会议应用不能被误遮。
    func testNonMeetingAppDoesNotMask() {
        let (state, _) = makeState()
        state.setMeetingModeEnabled(true)
        XCTAssertFalse(state.meetingPolicy.shouldMask(frontmostBundleID: "com.apple.Safari"))
    }
}
