import XCTest
@testable import SpatialLyricsPlayer

final class AudioRoutePolicyTests: XCTestCase {

    private let policy = AudioRoutePolicy(pauseOnHeadphoneUnplug: true)

    func testPausesWhenHeadphonesDisappear() {
        XCTAssertTrue(policy.shouldPause(previous: .headphones, current: .builtInSpeaker),
                      "拔耳机切到内置扬声器必须暂停")
        XCTAssertTrue(policy.shouldPause(previous: .headphones, current: .other))
    }

    func testFirstObservationDoesNotPause() {
        XCTAssertFalse(policy.shouldPause(previous: nil, current: .builtInSpeaker),
                       "首次读取设备没有'之前'可比，不能误判成拔耳机")
    }

    func testSpeakerToHeadphonesDoesNotPause() {
        XCTAssertFalse(policy.shouldPause(previous: .builtInSpeaker, current: .headphones),
                       "插上耳机不该暂停")
    }

    func testHeadphoneToHeadphoneDoesNotPause() {
        XCTAssertFalse(policy.shouldPause(previous: .headphones, current: .headphones),
                       "有线切蓝牙仍是耳机，不暂停")
    }

    func testDisabledPolicyNeverPauses() {
        let off = AudioRoutePolicy(pauseOnHeadphoneUnplug: false)
        XCTAssertFalse(off.shouldPause(previous: .headphones, current: .builtInSpeaker))
    }
}
