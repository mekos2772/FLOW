import XCTest
@testable import SpatialLyricsPlayer

/// 恢复位置时，尺寸的权威来源是**形态**，不是快照里记录的宽高。
///
/// `PlacementSnapshot.width/height` 是现场记录；面板尺寸由 `shape.preferredSize` 决定，
/// 用户不能自由拉伸。如果有人误用快照宽高去 `setFrame`，不同形态之间就会串形。
@MainActor
final class PlacementSizeAuthorityTests: XCTestCase {

    func testRestoredSizeFollowsShapeNotSnapshot() throws {
        let support = try MorphTestSupport.make()
        let controller = support.controller

        // 造一个"记录尺寸与形态尺寸不一致"的快照：胶囊形态本来不是 999×999。
        let bogus = PlacementSnapshot(
            displayID: String(ScreenGeometryResolver.mainScreenGeometry().id),
            originX: 200, originY: 200,
            width: 999, height: 999,
            shape: .capsule, isLocked: false, isClickThrough: false,
            opacity: 1, showsBackground: true, preferredX: nil, preferredY: nil)

        let frame = controller.restoreForTesting(bogus)
        let expected = LyricsShape.capsule.preferredSize
        XCTAssertEqual(frame.width, expected.width, accuracy: 0.5,
                       "宽度必须来自形态，不能来自快照")
        XCTAssertEqual(frame.height, expected.height, accuracy: 0.5)
    }
}
