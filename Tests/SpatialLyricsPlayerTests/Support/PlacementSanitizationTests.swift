import XCTest
@testable import SpatialLyricsPlayer

/// 位置快照的清洗。
///
/// 位置是唯一直接决定窗口几何的持久化数据：
/// NaN 坐标会让 AppKit 的 frame 运算不可预期；尺寸为 0 会让面板缩成看不见的一条，
/// 用户以为 App 坏了。正常路径不会产生这种值，但数据库被外部改过、旧版本写坏过都可能出现。
final class PlacementSanitizationTests: XCTestCase {

    private func snapshot(originX: Double = 100, originY: Double = 200,
                          width: Double = 360, height: Double = 120,
                          opacity: Double = 0.95,
                          preferredX: Double? = 0.5,
                          preferredY: Double? = 0.5) -> PlacementSnapshot {
        PlacementSnapshot(displayID: "1", originX: originX, originY: originY,
                          width: width, height: height, shape: .capsule,
                          isLocked: false, isClickThrough: false, opacity: opacity,
                          showsBackground: true, preferredX: preferredX, preferredY: preferredY)
    }

    func testNormalSnapshotIsUnchanged() {
        let original = snapshot()
        XCTAssertEqual(original.sanitized(), original, "正常值不该被改动")
    }

    /// 真实存在的小尺寸卡片（双行 46pt 高）不能被抬到最小值以上。
    func testRealSmallCardSurvivesSanitization() {
        let small = snapshot(width: 380, height: 46)
        XCTAssertEqual(small.sanitized().height, 46, accuracy: 0.001,
                       "46pt 是真实卡片高度，清洗不能改动它")
    }

    func testNaNOriginFallsBack() {
        let cleaned = snapshot(originX: .nan, originY: .nan).sanitized()
        XCTAssertTrue(cleaned.originX.isFinite)
        XCTAssertTrue(cleaned.originY.isFinite)
    }

    func testZeroSizeIsRaisedToMinimum() {
        let cleaned = snapshot(width: 0, height: 0).sanitized()
        XCTAssertGreaterThanOrEqual(cleaned.width, Double(FloatingLyricMetrics.minCardSize.width),
                                    "宽度为 0 时面板会看不见")
        XCTAssertGreaterThanOrEqual(cleaned.height, Double(FloatingLyricMetrics.minCardSize.height))
    }

    func testOpacityIsClamped() {
        XCTAssertEqual(snapshot(opacity: 5).sanitized().opacity, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot(opacity: 0).sanitized().opacity, 0.3, accuracy: 0.001)
        XCTAssertEqual(snapshot(opacity: .nan).sanitized().opacity, 1, accuracy: 0.001)
    }

    func testPreferredCoordinatesAreClampedOrDropped() {
        XCTAssertEqual(snapshot(preferredX: 1.7).sanitized().preferredX, 1)
        XCTAssertNil(snapshot(preferredX: .nan).sanitized().preferredX,
                     "非有限的偏好坐标应当丢弃，而不是变成 NaN 传下去")
    }
}
