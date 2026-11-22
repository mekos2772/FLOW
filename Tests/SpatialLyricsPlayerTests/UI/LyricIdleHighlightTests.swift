import XCTest
@testable import SpatialLyricsPlayer

/// 未播放 / 前奏 / 加载失败时，歌词区必须有一个"当前行"。
///
/// 否则所有行都套用远处行人样式（30% 不透明度 + 模糊），
/// 整块歌词灰掉、没有重点——实测用户会问"这歌词怎么是这样的"。
final class LyricIdleHighlightTests: XCTestCase {

    private func code(_ relative: String) throws -> String {
        let text = try String(contentsOf: RepositoryRoot.locate().appendingPathComponent(relative),
                              encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testScrollLyricsFallBackToFirstLineWhenIdle() throws {
        let text = try code("UI/Expanded/LyricScrollView.swift")
        XCTAssertTrue(text.contains("model.lyric.index ?? 0") || text.contains("lines.isEmpty ? nil : 0"),
                      "没有当前行时必须回落到第 0 行，否则整块歌词都是暗的")
    }

    /// 布局层：第 0 行被标记为 current。
    func testFirstLineGetsCurrentStyle() {
        let layout = LyricScrollLayout.make(lineCount: 3, currentIndex: 0,
                                            baseLineHeight: 36, currentLineHeight: 56,
                                            visibleHeight: 400)
        XCTAssertTrue(layout.styles[0].isCurrent)
        XCTAssertEqual(layout.styles[0].opacity, 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(layout.styles[1].opacity, 0, "相邻行仍应可见")
    }
}
