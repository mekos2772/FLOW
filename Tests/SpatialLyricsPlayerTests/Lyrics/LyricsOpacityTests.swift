import XCTest
@testable import SpatialLyricsPlayer

/// 不透明度钳制规则。这三个用例来自实测发现的坑：
/// 设置写在 0.35 时窗口曾恒为 1.0，原因是渲染层根本没消费这个值。
final class LyricsOpacityTests: XCTestCase {

    func testClampsBelowMinimum() {
        XCTAssertEqual(LyricsOpacity.clamp(0.1), 0.3, accuracy: 0.0001, "过低的透明度会让歌词看不清")
    }

    func testPassesThroughValidValue() {
        XCTAssertEqual(LyricsOpacity.clamp(0.95), 0.95, accuracy: 0.0001)
        XCTAssertEqual(LyricsOpacity.clamp(0.35), 0.35, accuracy: 0.0001, "实测用过的取值必须原样保留")
    }

    func testClampsAboveMaximum() {
        XCTAssertEqual(LyricsOpacity.clamp(1.5), 1.0, accuracy: 0.0001)
    }

    func testNonFiniteFallsBackToOpaque() {
        XCTAssertEqual(LyricsOpacity.clamp(.nan), 1.0, accuracy: 0.0001, "坏配置不能让窗口变成透明或不可见")
        XCTAssertEqual(LyricsOpacity.clamp(.infinity), 1.0, accuracy: 0.0001)
    }
}
