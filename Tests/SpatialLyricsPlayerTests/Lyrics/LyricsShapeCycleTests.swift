import XCTest
@testable import SpatialLyricsPlayer

/// 形态循环切换的纯逻辑部分（`cycleShape()` 用的就是 `LyricsShape.next`）。
///
/// 窗口层的切换链路（`setShape` 改 frame、按顶部中点锚定、clamp 回安全区）
/// 需要完整的依赖图才能构造 `FloatingPanelController`，本轮没做，记录在 README。
/// 这里先保证循环本身不会卡住或跳过某个形态——那是用户按快捷键时最容易察觉的错。
final class LyricsShapeCycleTests: XCTestCase {

    func testCycleVisitsEveryShapeAndReturnsToStart() {
        var seen: [LyricsShape] = []
        var current = LyricsShape.allCases[0]
        for _ in LyricsShape.allCases {
            seen.append(current)
            current = current.next
        }
        XCTAssertEqual(Set(seen).count, LyricsShape.allCases.count, "一圈之内每个形态都应出现一次")
        XCTAssertEqual(current, LyricsShape.allCases[0], "循环一圈后必须回到起点，不能漂移")
    }

    func testNextIsNeverSelf() {
        for shape in LyricsShape.allCases {
            XCTAssertNotEqual(shape.next, shape, "\(shape) 的下一个不能是自己，否则按快捷键像没反应")
        }
    }

    func testCycleIsStableUnderRepeatedCalls() {
        var a = LyricsShape.capsule
        var b = LyricsShape.capsule
        for _ in 0..<10 { a = a.next; b = b.next }
        XCTAssertEqual(a, b, "同样的次数必须得到同样的形态")
    }
}
