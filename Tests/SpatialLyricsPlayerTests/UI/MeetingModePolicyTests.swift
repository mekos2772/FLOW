import XCTest
@testable import SpatialLyricsPlayer

final class MeetingModePolicyTests: XCTestCase {

    func testDisabledPolicyNeverMasks() {
        let policy = MeetingModePolicy(isEnabled: false, bundleIdentifiers: ["us.zoom.xos"])
        XCTAssertFalse(policy.shouldMask(frontmostBundleID: "us.zoom.xos"),
                       "功能关闭时即使会议应用在前台也不遮")
    }

    func testMasksOnlyListedApp() {
        let policy = MeetingModePolicy(isEnabled: true, bundleIdentifiers: ["us.zoom.xos"])
        XCTAssertTrue(policy.shouldMask(frontmostBundleID: "us.zoom.xos"))
        XCTAssertFalse(policy.shouldMask(frontmostBundleID: "com.apple.Safari"),
                       "不在名单里的应用不能触发遮罩")
    }

    func testUnknownFrontmostDoesNotMask() {
        let policy = MeetingModePolicy(isEnabled: true, bundleIdentifiers: ["us.zoom.xos"])
        XCTAssertFalse(policy.shouldMask(frontmostBundleID: nil), "拿不到前台应用时保守不遮")
        XCTAssertFalse(policy.shouldMask(frontmostBundleID: ""), "空 bundle id 同样不算命中")
    }
}

@MainActor
final class PrivacyStateMeetingTests: XCTestCase {

    private func makeState() -> PrivacyState {
        PrivacyState(settings: InMemorySettingsStore())
    }

    func testMeetingAppFlipsMaskingWithoutTouchingUserSwitch() {
        let state = makeState()
        state.setMeetingPolicy(MeetingModePolicy(isEnabled: true, bundleIdentifiers: ["us.zoom.xos"]))

        state.updateFrontmost(bundleID: "us.zoom.xos")
        XCTAssertTrue(state.isMasking, "会议应用在前台时必须遮")
        XCTAssertFalse(state.isEnabled, "自动遮罩不能篡改用户手动开关的状态")

        state.updateFrontmost(bundleID: "com.apple.Safari")
        XCTAssertFalse(state.isMasking, "离开会议应用后自动解除")
    }

    func testManualPrivacyStaysOnRegardlessOfFrontmost() {
        let state = makeState()
        state.setEnabled(true)
        state.updateFrontmost(bundleID: "com.apple.Safari")
        XCTAssertTrue(state.isMasking)
        XCTAssertEqual(state.sanitize("周杰伦 - 晴天"), "正在播放")
    }

    func testSanitizePassesThroughWhenNothingMasks() {
        let state = makeState()
        state.updateFrontmost(bundleID: "com.apple.Safari")
        XCTAssertEqual(state.sanitize("周杰伦 - 晴天"), "周杰伦 - 晴天")
    }
}
