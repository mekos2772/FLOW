import XCTest
@testable import SpatialLyricsPlayer

/// 恢复位置归一化。
///
/// `AVPlayer.currentTime().seconds` 在播放器不可用时会返回 `NaN`。
/// 直接把这个值写进存储没有意义，读回来也会让 `position > 0` 之类的判断变得不可预期。
@MainActor
final class SessionPositionSanitizeTests: XCTestCase {

    func testNaNBecomesZero() {
        XCTAssertEqual(PlaybackSessionPersistence.sanitizedPosition(.nan), 0)
    }

    func testInfiniteBecomesZero() {
        XCTAssertEqual(PlaybackSessionPersistence.sanitizedPosition(.infinity), 0)
        XCTAssertEqual(PlaybackSessionPersistence.sanitizedPosition(-.infinity), 0)
    }

    func testNegativeBecomesZero() {
        XCTAssertEqual(PlaybackSessionPersistence.sanitizedPosition(-12.5), 0,
                       "负位置没有意义，恢复时不该去 seek")
    }

    func testValidPositionIsKept() {
        XCTAssertEqual(PlaybackSessionPersistence.sanitizedPosition(42.25), 42.25, accuracy: 0.001)
        XCTAssertEqual(PlaybackSessionPersistence.sanitizedPosition(0), 0)
    }
}
