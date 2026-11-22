import XCTest
@testable import SpatialLyricsPlayer

final class LyricTimelineTests: XCTestCase {

    private func timeline(_ starts: [TimeInterval]) -> LyricTimeline {
        LyricTimeline(lines: starts.enumerated().map { LyricLine(start: $0.element, text: "L\($0.offset)") })
    }

    func testIndexAtExactTime() {
        let timeline = timeline([0, 5, 10, 15])
        XCTAssertEqual(timeline.index(at: 0), 0)
        XCTAssertEqual(timeline.index(at: 5), 1)
        XCTAssertEqual(timeline.index(at: 14.999), 2)
        XCTAssertEqual(timeline.index(at: 15), 3)
    }

    func testBeforeFirstLineReturnsNil() {
        let timeline = timeline([10, 20])
        XCTAssertNil(timeline.index(at: 9.9))
        XCTAssertNil(timeline.line(at: 9.9))
    }

    func testNextAndPrevious() {
        let timeline = timeline([0, 5, 10])
        XCTAssertEqual(timeline.nextLine(after: 6)?.text, "L2")
        XCTAssertNil(timeline.nextLine(after: 11))
        XCTAssertEqual(timeline.previousLine(before: 6)?.text, "L0")
        XCTAssertNil(timeline.previousLine(before: 1))
    }

    func testProgressWithinLine() {
        let timeline = timeline([0, 10])
        XCTAssertEqual(timeline.progress(at: 5), 0.5, accuracy: 0.001)
        // 最后一行没有下一行，按 4 秒收尾：10s 开始 → 14s 走满。
        XCTAssertEqual(timeline.progress(at: 12), 0.5, accuracy: 0.001)
        XCTAssertEqual(timeline.progress(at: 15), 1.0, accuracy: 0.001)
    }

    func testBinarySearchMatchesLinearScan() {
        let starts = (0..<500).map { TimeInterval($0 * 3) }
        let timeline = timeline(starts)
        for probe in stride(from: -5.0, through: 1500.0, by: 7.3) {
            let expected = starts.lastIndex(where: { $0 <= probe })
            XCTAssertEqual(timeline.index(at: probe), expected, "probe=\(probe)")
        }
    }

    func testUnsortedInputIsSortedOnInit() {
        let timeline = LyricTimeline(lines: [
            LyricLine(start: 30, text: "C"),
            LyricLine(start: 10, text: "A"),
            LyricLine(start: 20, text: "B"),
        ])
        XCTAssertEqual(timeline.lines.map(\.text), ["A", "B", "C"])
    }
}
