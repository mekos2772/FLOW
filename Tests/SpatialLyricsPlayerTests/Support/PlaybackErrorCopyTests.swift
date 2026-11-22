import XCTest
@testable import SpatialLyricsPlayer

/// 播放错误的用户文案不能混进技术串。
///
/// `decodeFailed(reason:)` 的 reason 来自 AVFoundation，典型长这样：
/// `The operation couldn't be completed. (AVFoundationErrorDomain error -11800.)`
/// 拼进界面就显得很粗糙，而且对用户毫无信息量。
final class PlaybackErrorCopyTests: XCTestCase {

    private let technical = "The operation couldn't be completed. (AVFoundationErrorDomain error -11800.)"

    func testDecodeFailureDetailIsClean() {
        let detail = PlaybackError.decodeFailed(reason: technical).detail
        XCTAssertFalse(detail.contains("AVFoundationErrorDomain"),
                       "用户文案里不能出现框架域名：\(detail)")
        XCTAssertFalse(detail.contains("couldn't be completed"),
                       "用户文案里不能出现系统通用串：\(detail)")
        XCTAssertTrue(detail.contains("换一首"), "要给出可执行的下一步：\(detail)")
    }

    func testUnknownDetailIsClean() {
        let detail = PlaybackError.unknown(reason: technical).detail
        XCTAssertFalse(detail.contains("AVFoundation"))
        XCTAssertTrue(detail.contains("重试"))
    }

    /// 原因本身仍要保留在错误里（日志与诊断需要）。
    func testReasonIsStillCarried() {
        XCTAssertEqual(PlaybackError.decodeFailed(reason: "x"), .decodeFailed(reason: "x"))
    }
}
